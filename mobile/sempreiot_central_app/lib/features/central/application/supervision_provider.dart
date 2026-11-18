import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'ota_rollout_controller.dart';
import 'ota_rollout_report.dart';
import 'ota_rollout_state.dart';
import 'root_election_provider.dart';
import 'serial_link_provider.dart';

/// Supervision rule (docs/safr/protocol-safr-v3.md §8): a device that stays silent
/// for 3× its heartbeat interval is missing — raise TROUBLE and mark it
/// offline; any authenticated frame restores it. State is persisted in
/// MeshDevices.supervisionState so troubles aren't re-raised on restart.
///
/// The one exception (protocol §13.4 `DEADLINE_S`): a unit that is being
/// updated — its row of the rollout is offered / downloading / verifying /
/// rebooting / in self-test — is UPDATING, not missing, for up to
/// [otaUpdatingGrace] since its row entered one of those states: it restarts
/// into the new image and is silent while it does. No "dispositivo ausente"
/// trouble is raised for it in that time; after it the rule above applies
/// again.
const _offlinePowered = Duration(seconds: 45); // root/relay: HB every 15 s
const _offlineLeaf = Duration(seconds: 180); // leaf: HB every 60 s

class DeviceSupervision {
  const DeviceSupervision({
    required this.device,
    required this.online,
    this.heard = true,
    this.updating = false,
  });

  final MeshDevice device;

  /// Supervised as present: heard in time, or being updated.
  final bool online;

  /// Heard in time and not reported missing by the board — the rule with
  /// no exception. False with [online] true: silent because it is being
  /// updated.
  final bool heard;

  /// Its row of the rollout is in an active state, within the grace.
  final bool updating;
}

/// Since when the unit with a MAC is being updated (its row of the rollout
/// entered offered … self-test); null = it is not.
typedef UpdatingSince = DateTime? Function(String mac);

class SupervisionNotifier extends StateNotifier<List<DeviceSupervision>> {
  SupervisionNotifier(
    this._db, {
    UpdatingSince? updatingSince,
    Duration updatingGrace = otaUpdatingGrace,
    DateTime Function()? clock,
  })  : _updatingSince = updatingSince,
        _updatingGrace = updatingGrace,
        _clock = clock ?? DateTime.now,
        super(const []) {
    _watch = _db.select(_db.meshDevices).watch().listen((rows) {
      _devices = rows;
      _evaluate();
    });
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _evaluate());
  }

  final AppDatabase _db;
  final UpdatingSince? _updatingSince;
  final Duration _updatingGrace;
  final DateTime Function() _clock;
  List<MeshDevice> _devices = const [];
  StreamSubscription<List<MeshDevice>>? _watch;
  Timer? _timer;
  bool _evaluating = false;

  static Duration offlineThreshold(MeshDevice d) {
    final isLeaf = d.role == SafrNodeRole.leaf.wire ||
        (d.role == SafrNodeRole.unknown.wire && d.layer >= 2);
    return isLeaf ? _offlineLeaf : _offlinePowered;
  }

  /// Runs the rule now, on the registry as it is now (the timer does it
  /// every 5 s, on what the registry last said).
  @visibleForTesting
  Future<void> evaluate() async {
    while (_evaluating) {
      await Future<void>.delayed(Duration.zero);
    }
    _devices = await _db.select(_db.meshDevices).get();
    await _evaluate();
  }

  /// Being updated at [now]: in an active state of the rollout, for less
  /// than the grace since it entered them.
  bool _updating(String mac, DateTime now) {
    final since = _updatingSince?.call(mac);
    if (since == null) return false;
    return now.difference(since.toUtc()) < _updatingGrace;
  }

  Future<void> _evaluate() async {
    if (_evaluating || !mounted) return;
    _evaluating = true;
    try {
      final now = _clock().toUtc();
      final result = <DeviceSupervision>[];

      for (final d in _devices) {
        final heard = now.difference(d.lastSeenAt) < offlineThreshold(d);
        // The board is the authority when it knows more recently than we
        // heard the unit: it drops a dead root's TCP session in ~5 s and
        // pushes a DEVICE_TABLE with that unit MISSING (spec §7.12, §9.2),
        // 40 s before our own silence rule. Any later frame from the unit
        // (lastSeenAt newer than the table) makes it online again.
        final boardSaysMissing = d.boardState == SafrDeviceState.missing.wire &&
            d.tableSyncedAt != null &&
            d.tableSyncedAt!.isAfter(d.lastSeenAt);
        final present = heard && !boardSaysMissing;
        // The exception: a unit that is being updated is not missing.
        final updating = _updating(d.mac, now);
        final online = present || updating;
        result.add(DeviceSupervision(
          device: d,
          online: online,
          heard: present,
          updating: updating,
        ));

        final wasOnline = d.supervisionState == 0;
        if (wasOnline && !online) {
          await _transition(d, offline: true, now: now);
        } else if (!wasOnline && online) {
          await _transition(d, offline: false, now: now);
        }
      }
      if (mounted) state = result;
    } finally {
      _evaluating = false;
    }
  }

  Future<void> _transition(
    MeshDevice d, {
    required bool offline,
    required DateTime now,
  }) async {
    await (_db.update(_db.meshDevices)..where((t) => t.mac.equals(d.mac)))
        .write(MeshDevicesCompanion(supervisionState: Value(offline ? 1 : 0)));

    await _db.into(_db.deviceEvents).insert(DeviceEventsCompanion.insert(
          receivedAt: now,
          deviceMac: d.mac,
          msgType: 0, // synthetic
          eventType: Value(offline
              ? SafrEventType.trouble.wire
              : SafrEventType.okRestore.wire),
          eventCode: Value(offline
              ? SafrEventCode.commFault.wire
              : SafrEventCode.restore.wire),
          severity: offline ? 1 : 0,
          detailJson: jsonEncode({
            'synthetic': true,
            'kind': offline ? 'device_missing' : 'device_restored',
            'last_seen': d.lastSeenAt.toIso8601String(),
          }),
        ));
  }

  @override
  void dispose() {
    _watch?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}

final supervisionProvider =
    StateNotifierProvider<SupervisionNotifier, List<DeviceSupervision>>((ref) {
  return SupervisionNotifier(
    ref.watch(appDatabaseProvider),
    // Read when the rule runs, not watched: the rollout moves often and
    // the rule runs every 5 s and on every change of the registry.
    updatingSince: (mac) => ref.read(otaUpdatingUnitsProvider).since(mac),
    updatingGrace: ref.watch(otaRolloutTimingsProvider).updatingGrace,
  );
});

/// State of the mesh network as a whole, for the REDE INTERNA tile and the
/// published MQTT status: connected while the root node is fresh — and never
/// "connected" while the serial link itself is down.
final meshLinkStateProvider = Provider<String>((ref) {
  if (ref.watch(serialLinkProvider) != SerialLinkStatus.connected) {
    return 'disconnected';
  }
  // The mesh is between roots: reachable, but nobody is the bridge yet.
  if (ref.watch(rootElectionProvider).electing) return 'connecting';
  final devices = ref.watch(supervisionProvider);
  if (devices.isEmpty) return 'disconnected';
  for (final s in devices) {
    final isRoot =
        s.device.role == SafrNodeRole.root.wire || s.device.layer == 0;
    if (isRoot) return s.online ? 'connected' : 'disconnected';
  }
  return 'connecting'; // devices exist but no root identified yet
});
