import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'serial_link_provider.dart';

/// Supervision rule (docs/safr/protocol-safr-v3.md §8): a device that stays silent
/// for 3× its heartbeat interval is missing — raise TROUBLE and mark it
/// offline; any authenticated frame restores it. State is persisted in
/// MeshDevices.supervisionState so troubles aren't re-raised on restart.
const _offlinePowered = Duration(seconds: 45); // root/relay: HB every 15 s
const _offlineLeaf = Duration(seconds: 180); // leaf: HB every 60 s

class DeviceSupervision {
  const DeviceSupervision({required this.device, required this.online});

  final MeshDevice device;
  final bool online;
}

class SupervisionNotifier extends StateNotifier<List<DeviceSupervision>> {
  SupervisionNotifier(this._db) : super(const []) {
    _watch = _db.select(_db.meshDevices).watch().listen((rows) {
      _devices = rows;
      _evaluate();
    });
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _evaluate());
  }

  final AppDatabase _db;
  List<MeshDevice> _devices = const [];
  StreamSubscription<List<MeshDevice>>? _watch;
  Timer? _timer;
  bool _evaluating = false;

  static Duration offlineThreshold(MeshDevice d) {
    final isLeaf = d.role == SafrNodeRole.leaf.wire ||
        (d.role == SafrNodeRole.unknown.wire && d.layer >= 2);
    return isLeaf ? _offlineLeaf : _offlinePowered;
  }

  Future<void> _evaluate() async {
    if (_evaluating || !mounted) return;
    _evaluating = true;
    try {
      final now = DateTime.now().toUtc();
      final result = <DeviceSupervision>[];

      for (final d in _devices) {
        final online = now.difference(d.lastSeenAt) < offlineThreshold(d);
        result.add(DeviceSupervision(device: d, online: online));

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
  return SupervisionNotifier(ref.watch(appDatabaseProvider));
});

/// State of the mesh network as a whole, for the REDE INTERNA tile and the
/// published MQTT status: connected while the root node is fresh — and never
/// "connected" while the serial link itself is down.
final meshLinkStateProvider = Provider<String>((ref) {
  if (ref.watch(serialLinkProvider) != SerialLinkStatus.connected) {
    return 'disconnected';
  }
  final devices = ref.watch(supervisionProvider);
  if (devices.isEmpty) return 'disconnected';
  for (final s in devices) {
    final isRoot =
        s.device.role == SafrNodeRole.root.wire || s.device.layer == 0;
    if (isRoot) return s.online ? 'connected' : 'disconnected';
  }
  return 'connecting'; // devices exist but no root identified yet
});
