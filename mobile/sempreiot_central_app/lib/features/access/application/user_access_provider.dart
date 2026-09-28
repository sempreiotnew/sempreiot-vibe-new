import 'dart:convert';
import 'dart:math';

import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/application/auth_provider.dart';
import '../../iot/application/iot_provider.dart';
import '../data/services/access_api_service.dart';
import '../data/services/lookup_api_service.dart';
import '../domain/entities/access_level.dart';
import '../domain/entities/lookup_result.dart';
import '../domain/entities/saved_central.dart';

// ── Saved centrals (SharedPreferences cache, backend as source of truth) ─────

// Legacy single-key storage — shared across accounts, which leaked one
// user's centrals into the next login on the same device. Removed on load.
const _legacyPrefsKey = 'saved_centrals';

class SavedCentralsNotifier extends StateNotifier<List<SavedCentral>> {
  SavedCentralsNotifier(this._ref) : super([]);

  final Ref _ref;
  ProviderSubscription<AsyncValue<dynamic>>? _sub;
  String? _prefsKey; // per-user; null until load() resolves the signed-in user

  Future<void> load() async {
    final user = await _ref.read(authNotifierProvider.future);
    if (user == null || !mounted) return;
    _prefsKey = 'saved_centrals_${user.userId}';

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyPrefsKey);
    final raw = prefs.getString(_prefsKey!);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        state = list
            .whereType<Map<String, dynamic>>()
            .map(SavedCentral.fromMap)
            .toList();
      } catch (_) {}
    }

    // Sync from backend: updates statuses missed while offline AND rebuilds
    // entries missing locally (fresh install, cleared/foreign localStorage).
    _syncFromBackend();

    // Listen for real-time acceptance/rejection responses via MQTT
    _sub = _ref.listen<AsyncValue<dynamic>>(
      iotMessageStreamProvider('${_ref.read(iotMqttRepositoryProvider).identityId ?? '_'}/#'),
      (_, next) {
        if (next is! AsyncData || next.value == null) return;
        final msg = next.value;
        final topic = msg.topic as String? ?? '';
        if (!topic.endsWith('/access-response')) return;
        try {
          final map = jsonDecode(msg.payload as String) as Map<String, dynamic>;
          final decision = map['decision'] as String? ?? '';
          final centralIdentityId = map['centralIdentityId'] as String? ?? '';
          final level = AccessLevel.fromWire(map['level'] as String?);
          if (centralIdentityId.isEmpty) return;
          _updateStatus(centralIdentityId, decision, level: level);
        } catch (e) {
          debugPrint('[UserAccess] failed to parse access-response: $e');
        }
      },
    );
  }

  Future<void> _syncFromBackend() async {
    try {
      final user = await _ref.read(authNotifierProvider.future);
      if (user == null) return;
      final userSubId = user.userId;
      final requests = await AccessApiService.getRequestsForUser(
        userSubId: userSubId,
        getToken: () async {
          final session = await Amplify.Auth.fetchAuthSession();
          final cognitoSession = session as CognitoAuthSession;
          return cognitoSession.userPoolTokensResult.value.idToken.raw;
        },
      );
      var updated = false;
      final next = state.map((c) {
        final match = requests.where((r) =>
            (r['centralIdentityId'] as String? ?? '') == c.identityId);
        if (match.isEmpty) return c;
        // Take the most recent resolved status (prefer non-PENDING if any resolved)
        final resolved = match.where((r) =>
            (r['status'] as String? ?? '') != 'PENDING');
        final best = resolved.isNotEmpty ? resolved.first : match.first;
        final newStatus = best['status'] as String? ?? c.status;
        final newLevel = AccessLevel.fromWire(best['level'] as String?);
        if (newStatus == c.status && newLevel == c.level) return c;
        updated = true;
        return c.copyWith(
          status: newStatus,
          level: newLevel,
          clearLevel: newLevel == null,
        );
      }).toList();

      // Rebuild entries the backend knows but local storage lost — the
      // prefs are only a cache (web localStorage is per-origin and dev
      // servers change ports; fresh installs start empty). The relation
      // row only has the central's identityId, so name/subId come from a
      // reverse lookup. REJECTED rows are skipped: an absent local card
      // for one means the user dismissed it on purpose.
      final known = next.map((c) => c.identityId).toSet();
      for (final r in requests) {
        final cid = r['centralIdentityId'] as String? ?? '';
        final status = r['status'] as String? ?? '';
        if (cid.isEmpty || known.contains(cid)) continue;
        if (status != 'PENDING' && status != 'ACCEPTED' && status != 'BLOCKED') {
          continue;
        }
        try {
          final info = await LookupApiService.lookupByIdentityId(cid);
          next.add(SavedCentral(
            subId: info.subId,
            identityId: cid,
            name: info.displayName,
            status: status,
            level: AccessLevel.fromWire(r['level'] as String?),
            addedAt: DateTime.tryParse(r['requestedAt'] as String? ?? '') ??
                DateTime.now(),
          ));
          known.add(cid);
          updated = true;
        } catch (e) {
          debugPrint('[UserAccess] could not rebuild central $cid: $e');
        }
      }

      if (updated && mounted) {
        state = next;
        await _persist();
      }
    } catch (e) {
      debugPrint('[UserAccess] backend sync failed: $e');
    }
  }

  void _updateStatus(String centralIdentityId, String decision, {AccessLevel? level}) {
    final updated = state.map((c) {
      if (c.identityId != centralIdentityId) return c;
      switch (decision) {
        case 'LEVEL_CHANGED':
          // Status stays ACCEPTED — only the level moved.
          return c.copyWith(level: level);
        case 'ACCEPTED':
          return c.copyWith(status: 'ACCEPTED', level: level ?? AccessLevel.level1);
        default:
          // REJECTED | BLOCKED — no level while not accepted.
          return c.copyWith(status: decision, clearLevel: true);
      }
    }).toList();
    state = updated;
    _persist();
  }

  Future<void> add(SavedCentral central) async {
    final exists = state.any((c) => c.subId == central.subId);
    if (!exists) {
      state = [...state, central];
    } else {
      // Re-requesting after REJECTED flips the local card back to PENDING
      // immediately — the backend confirms/denies over MQTT shortly after.
      state = [
        for (final c in state)
          if (c.subId == central.subId)
            c.copyWith(status: 'PENDING', clearLevel: true)
          else
            c,
      ];
    }
    await _persist();
  }

  Future<void> remove(String subId) async {
    state = state.where((c) => c.subId != subId).toList();
    await _persist();
  }

  /// Sets this user's local nickname for a central. Purely local — every
  /// user labels centrals however they like; the subId is the identity.
  Future<void> updateName(String identityId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    state = [
      for (final c in state)
        if (c.identityId == identityId) c.copyWith(name: trimmed) else c,
    ];
    await _persist();
  }

  Future<void> _persist() async {
    final key = _prefsKey;
    if (key == null) return; // no signed-in user resolved yet
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(state.map((c) => c.toMap()).toList()),
    );
  }

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }
}

final savedCentralsProvider =
    StateNotifierProvider<SavedCentralsNotifier, List<SavedCentral>>((ref) {
  // Rebuild on login/logout/account switch: watching the user's sub means a
  // different account gets a fresh notifier (and its own prefs key) instead
  // of inheriting the previous user's in-memory list.
  ref.watch(authNotifierProvider.select((s) => s.valueOrNull?.userId));
  final notifier = SavedCentralsNotifier(ref);
  notifier.load();
  return notifier;
});

// ── Lookup provider ───────────────────────────────────────────────────────────

final lookupProvider = FutureProvider.family<LookupResult, String>(
  (ref, subId) => LookupApiService.lookup(subId, type: 'central'),
);

// ── Request access (publish to MQTT) ─────────────────────────────────────────

class RequestAccessNotifier extends StateNotifier<AsyncValue<void>> {
  RequestAccessNotifier(this._ref) : super(const AsyncData(null));

  final Ref _ref;

  Future<void> request({
    required String centralSubId,
    required String centralIdentityId,
    required String centralName,
  }) async {
    state = const AsyncLoading();
    try {
      // Mirrors the backend's dedup/block rule client-side, so a blocked or
      // already-connected user can't even fire off a request that the
      // backend would silently drop anyway — matches "can't send a new
      // request unless the central unblocks you". Checked live against the
      // backend rather than the local savedCentralsProvider cache — a fresh
      // install (or any local/backend drift) would otherwise let a stale
      // "never seen this central" local state slip a blocked request
      // through, which the backend would then silently drop with zero
      // feedback to the user.
      final user = await _ref.read(authNotifierProvider.future);
      if (user != null) {
        final requests = await AccessApiService.getRequestsForUser(
          userSubId: user.userId,
          getToken: () async {
            final session = await Amplify.Auth.fetchAuthSession();
            final cognitoSession = session as CognitoAuthSession;
            return cognitoSession.userPoolTokensResult.value.idToken.raw;
          },
        );
        final match = requests.where(
          (r) => (r['centralIdentityId'] as String? ?? '') == centralIdentityId,
        );
        if (match.isNotEmpty) {
          final status = match.first['status'] as String? ?? '';
          if (status == 'BLOCKED') {
            throw Exception('Você foi bloqueado por esta central.');
          }
          if (status == 'PENDING') {
            throw Exception('Você já tem uma solicitação pendente para esta central.');
          }
          if (status == 'ACCEPTED') {
            throw Exception('Você já tem acesso a esta central.');
          }
        }
      }

      final repo = _ref.read(iotMqttRepositoryProvider);
      final userSubId = repo.userId ?? '';
      final userIdentityId = repo.identityId ?? '';

      if (userSubId.isEmpty || userIdentityId.isEmpty) {
        throw Exception('Not connected to IoT. Try again.');
      }

      final requestId = _newRequestId();
      final payload = jsonEncode({
        'requestId': requestId,
        'userSubId': userSubId,
        'userIdentityId': userIdentityId,
      });

      repo.publish('$centralIdentityId/access', payload);
      debugPrint('[UserAccess] published access request to $centralIdentityId/access');

      await _ref.read(savedCentralsProvider.notifier).add(
            SavedCentral(
              subId: centralSubId,
              identityId: centralIdentityId,
              name: centralName,
              status: 'PENDING',
              addedAt: DateTime.now(),
            ),
          );

      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
      // Both callers (AddCentralSheet, CentralStatusScreen's "request again")
      // wrap this call in their own try/catch expecting a thrown error to
      // show the right message — without rethrowing here, they always hit
      // the success path even when the guard above just refused the request.
      rethrow;
    }
  }

  static String _newRequestId() {
    final rand = Random.secure();
    final bytes = List.generate(16, (_) => rand.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

final requestAccessProvider =
    StateNotifierProvider<RequestAccessNotifier, AsyncValue<void>>(
  (ref) => RequestAccessNotifier(ref),
);
