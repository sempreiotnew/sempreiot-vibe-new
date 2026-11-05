import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../central/application/central_iot_provider.dart';
import '../../central/data/services/central_credentials_service.dart';
import '../data/services/access_api_service.dart';
import '../domain/entities/access_level.dart';
import '../domain/entities/access_relation.dart';

// ── Central's relationship list (one row per user, live + persisted) ─────────
//
// Single source of truth for every user this central has interacted with —
// pending requests, granted access, rejections, blocks. Loaded from the
// backend on every (re)connect (so a central restart doesn't lose pending
// requests), kept live by listening for new `.../access` MQTT publishes, and
// mirrored into the local `access` DB key so the UI has something to show
// before the network sync completes.

class CentralAccessRelationsNotifier extends StateNotifier<List<AccessRelation>> {
  CentralAccessRelationsNotifier(this._ref) : super(const []);

  final Ref _ref;
  ProviderSubscription<AsyncValue<dynamic>>? _mqttSub;
  ProviderSubscription<AsyncValue<bool>>? _connectionSub;
  Timer? _syncDebounce;

  /// The copy this tablet keeps has been read. Null on a notifier that
  /// never loads (a test's).
  Future<void>? _localRead;

  /// The backend's list has been read since the app started: from then on
  /// the list is kept live, and a user who is not in it is not in it.
  bool _synced = false;
  Future<bool>? _syncing;

  /// How long a request from a phone waits for the backend's list before
  /// it is answered from what is known (the phone gives up after 8 s).
  static const firstSyncWait = Duration(seconds: 5);

  // Must stay synchronous — ref.listen() has to run during the provider's
  // synchronous construction. An `await` before it (as this used to have)
  // pushes the calls past that window, and the listeners silently never
  // get wired up: no live "/access" pings, no reconnect-triggered resync.
  // That's why pending requests stopped showing up entirely.
  void init() {
    _mqttSub = _ref.listen<AsyncValue<dynamic>>(
      centralMqttMessagesProvider,
      (_, next) => _onMqttMessage(next),
    );

    // Re-sync from the backend on every successful (re)connect — this is
    // what keeps a central restart from losing in-flight pending requests.
    _connectionSub = _ref.listen<AsyncValue<bool>>(
      centralIotConnectionProvider,
      (_, next) {
        if (next.valueOrNull == true) _syncFromBackend();
      },
    );

    final local = Completer<void>();
    _localRead = local.future;
    _loadInitial(local);
  }

  Future<void> _loadInitial(Completer<void> localRead) async {
    try {
      final db = _ref.read(appDatabaseProvider);
      final cached = await _loadFromLocal(db);
      if (cached.isNotEmpty && mounted) state = cached;
    } catch (e) {
      debugPrint('[CentralAccess] local copy not read: $e');
    } finally {
      localRead.complete();
    }

    if (mounted &&
        _ref.read(centralIotConnectionProvider).valueOrNull == true) {
      await _syncFromBackend();
    }
  }

  /// The accepted Administrador or Master relation of [userIdentityId] —
  /// who may command this central from a phone (an update, a test).
  ///
  /// The list starts empty and is read only after the provider is first
  /// used: asked before that, it said "not an Administrador" to everyone
  /// (the first "Testar tudo" from a phone after the tablet started was
  /// refused that way). So "no" is never answered from a list that was
  /// not read: this waits for the tablet's own copy and, when the user is
  /// not in it and the backend's list was not read yet, for that one —
  /// [firstSyncWait] at most.
  Future<AccessRelation?> adminOf(String userIdentityId) async {
    await _localRead;
    final known = _adminIn(userIdentityId);
    if (known != null || _synced) return known;
    // Several phones asking at once share one read.
    final sync = _syncing ??=
        _syncFromBackend().whenComplete(() => _syncing = null);
    await sync.timeout(firstSyncWait, onTimeout: () => false);
    return _adminIn(userIdentityId);
  }

  AccessRelation? _adminIn(String userIdentityId) {
    for (final r in state) {
      if (r.userIdentityId == userIdentityId &&
          r.isAccepted &&
          (r.level == AccessLevel.level4 || r.level == AccessLevel.master)) {
        return r;
      }
    }
    return null;
  }

  Future<List<AccessRelation>> _loadFromLocal(AppDatabase db) async {
    final raw = await db.getMeta('access');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(AccessRelation.fromMap)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> _persist(List<AccessRelation> relations) async {
    final db = _ref.read(appDatabaseProvider);
    await db.setMeta(
      'access',
      jsonEncode(relations.map((r) => r.toMap()).toList()),
    );
  }

  /// Manual pull-to-refresh / refresh-button entry point.
  Future<void> refresh() => _syncFromBackend();

  Future<bool> _syncFromBackend() async {
    try {
      final centralIdentityId = _ref.read(centralMqttRepositoryProvider).identityId;
      if (centralIdentityId == null || centralIdentityId.isEmpty) return false;

      _ref.read(centralAccessSyncingProvider.notifier).state = true;
      final db = _ref.read(appDatabaseProvider);
      final service = CentralCredentialsService(db: db);
      final items = await AccessApiService.getAllForCentral(
        centralIdentityId: centralIdentityId,
        getToken: service.getIdToken,
      );
      final relations = items.map(AccessRelation.fromMap).toList();
      if (!mounted) return false;
      state = relations;
      _synced = true;
      await _persist(relations);
      return true;
    } catch (e) {
      debugPrint('[CentralAccess] backend sync failed: $e');
      return false;
    } finally {
      _ref.read(centralAccessSyncingProvider.notifier).state = false;
    }
  }

  // A raw `.../access` publish only means "the user attempted a request" —
  // it does NOT mean the backend actually created a PENDING row (the
  // request lambda silently drops it if the user is BLOCKED, or if a
  // PENDING/ACCEPTED relation already exists). Trusting the raw ping as
  // truth used to show phantom pending cards for exactly those cases,
  // and accepting/rejecting one 409'd because there was no real PENDING
  // row behind it. So: treat the ping only as a signal to re-check the
  // backend, debounced so a burst of pings doesn't spam the API — the
  // short delay also gives the request lambda (triggered independently
  // via the IoT Rule) time to finish writing before we read it back.
  void _onMqttMessage(AsyncValue<dynamic> next) {
    if (next is! AsyncData) return;
    final msg = next.value;
    if (msg == null) return;
    final topic = msg.topic as String? ?? '';

    // Topic pattern: {centralIdentityId}/access
    if (!topic.endsWith('/access')) return;

    debugPrint('[Access] activity on /access — reconciling with backend');
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 900), _syncWithRetry);
  }

  // One retry on top of the debounced sync — a transient failure (network
  // blip, token refresh mid-flight) would otherwise leave the screen showing
  // stale state until the next MQTT ping, reconnect, or manual refresh.
  Future<void> _syncWithRetry() async {
    final ok = await _syncFromBackend();
    if (ok) return;
    await Future.delayed(const Duration(seconds: 2));
    await _syncFromBackend();
  }

  // Every mutation (a new request, an accept/reject/block/level-change this
  // central performs) replaces the one row for that user — never appends a
  // second row for the same (central, user) pair. This is what fixes
  // duplicate cards for the same user showing up on screen.
  void _replaceOne(AccessRelation updated) {
    final next = [
      ...state.where((r) => r.userSubId != updated.userSubId),
      updated,
    ];
    state = next;
    _persist(next);
  }

  Future<void> resolve({
    required AccessRelation relation,
    required String decision, // 'ACCEPTED' | 'REJECTED'
    required String centralId,
    String actor = 'central',
  }) =>
      _runMutation(() async {
        final db = _ref.read(appDatabaseProvider);
        final service = CentralCredentialsService(db: db);
        await AccessApiService.resolve(
          centralIdentityId: relation.centralIdentityId,
          userSubId: relation.userSubId,
          decision: decision,
          centralId: centralId,
          getToken: service.getIdToken,
        );
        final now = DateTime.now();
        await db.addAudit(
          actor,
          decision == 'ACCEPTED' ? 'access_accepted' : 'access_rejected',
          {'userSubId': relation.userSubId},
        );
        _replaceOne(relation.copyWith(
          status: decision,
          level: decision == 'ACCEPTED' ? AccessLevel.level1 : null,
          clearLevel: decision != 'ACCEPTED',
          resolvedAt: now,
          updatedAt: now,
        ));
      });

  Future<void> changeLevel({
    required AccessRelation relation,
    required AccessLevel level,
    required String centralId,
    bool masterRemoval = false,
    String actor = 'central',
  }) =>
      _runMutation(() async {
        final db = _ref.read(appDatabaseProvider);
        final service = CentralCredentialsService(db: db);
        await AccessApiService.changeLevel(
          centralIdentityId: relation.centralIdentityId,
          userSubId: relation.userSubId,
          level: level.wireValue,
          centralId: centralId,
          getToken: service.getIdToken,
          masterRemoval: masterRemoval,
        );
        final isMasterOp = level == AccessLevel.master || masterRemoval;
        await db.addAudit(
          isMasterOp ? 'root' : actor,
          level == AccessLevel.master
              ? 'master_granted'
              : (masterRemoval ? 'master_removed' : 'level_changed'),
          {'userSubId': relation.userSubId, 'level': level.wireValue},
        );
        _replaceOne(relation.copyWith(level: level, updatedAt: DateTime.now()));
      });

  Future<void> block({
    required AccessRelation relation,
    required String centralId,
    String actor = 'central',
  }) =>
      _runMutation(() async {
        final db = _ref.read(appDatabaseProvider);
        final service = CentralCredentialsService(db: db);
        await AccessApiService.block(
          centralIdentityId: relation.centralIdentityId,
          userSubId: relation.userSubId,
          centralId: centralId,
          getToken: service.getIdToken,
        );
        await db.addAudit(actor, 'user_blocked', {'userSubId': relation.userSubId});
        _replaceOne(relation.copyWith(
          status: 'BLOCKED',
          clearLevel: true,
          updatedAt: DateTime.now(),
        ));
      });

  Future<void> unblock({
    required AccessRelation relation,
    String actor = 'central',
  }) =>
      _runMutation(() async {
        final db = _ref.read(appDatabaseProvider);
        final service = CentralCredentialsService(db: db);
        await AccessApiService.unblock(
          centralIdentityId: relation.centralIdentityId,
          userSubId: relation.userSubId,
          getToken: service.getIdToken,
        );
        await db.addAudit(actor, 'user_unblocked', {'userSubId': relation.userSubId});
        _replaceOne(relation.copyWith(
          status: 'REJECTED',
          clearLevel: true,
          updatedAt: DateTime.now(),
        ));
      });

  @override
  void dispose() {
    _mqttSub?.close();
    _connectionSub?.close();
    _syncDebounce?.cancel();
    super.dispose();
  }

  // A 409/404 means our local card was stale (already resolved, blocked, or
  // never actually created server-side) — resync so the UI reflects reality,
  // and surface a message the user can actually act on instead of a raw
  // exception dump.
  Future<void> _runMutation(Future<void> Function() action) async {
    try {
      await action();
    } on AccessApiException catch (e) {
      if (e.statusCode == 409 || e.statusCode == 404) {
        await _syncFromBackend();
        throw Exception('Essa solicitação não está mais disponível — lista atualizada.');
      }
      rethrow;
    }
  }
}

final centralAccessRelationsProvider =
    StateNotifierProvider<CentralAccessRelationsNotifier, List<AccessRelation>>((ref) {
  final notifier = CentralAccessRelationsNotifier(ref);
  notifier.init();
  return notifier;
});

/// True while a backend sync is in flight — lets the UI show a loading
/// state instead of a misleading "no users" while the list is still coming.
final centralAccessSyncingProvider = StateProvider<bool>((_) => false);

final centralPendingRequestsProvider = Provider<List<AccessRelation>>((ref) {
  return ref.watch(centralAccessRelationsProvider).where((r) => r.isPending).toList();
});

final centralGrantedProvider = Provider<List<AccessRelation>>((ref) {
  return ref.watch(centralAccessRelationsProvider).where((r) => r.isAccepted).toList();
});

final centralBlockedProvider = Provider<List<AccessRelation>>((ref) {
  return ref.watch(centralAccessRelationsProvider).where((r) => r.isBlocked).toList();
});

final pendingRequestCountProvider = Provider<int>((ref) {
  return ref.watch(centralPendingRequestsProvider).length;
});

// ── Central ID helper (derives from iot_client_id) ────────────────────────────

final centralIdProvider = FutureProvider<String>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final raw = await db.getMeta('iot');
  if (raw == null || raw.isEmpty) return '';
  final map = jsonDecode(raw) as Map<String, dynamic>;
  final clientId = map['iot_client_id'] as String? ?? '';
  return clientId.split('@').first; // "central-003@sempreiot.com" → "central-003"
});
