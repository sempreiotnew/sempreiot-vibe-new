import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_v2_payloads.dart';
import 'serial_link_provider.dart';
import 'supervision_provider.dart';

/// One node of the mesh graph shown in the Rede Mesh screen.
class TopologyNode {
  const TopologyNode({
    required this.mac,
    required this.role,
    required this.layer,
    required this.parentMac,
    required this.rssi,
    required this.batteryPct,
    required this.online,
    required this.lastSeenAt,
    required this.alarmLatched,
    this.alarmLatchedAt,
    this.name,
    this.zone,
    this.boardState,
    this.boardFlags = 0,
    this.parentCandidates = const [],
  });

  final String mac;
  final SafrNodeRole role;
  final int layer;
  final String? parentMac;
  final int? rssi;
  final int? batteryPct;
  final bool online;
  final DateTime lastSeenAt;

  /// Alarm held on the panel (SAFR v3 §7.1.4) until the operator RESET.
  final bool alarmLatched;
  final DateTime? alarmLatchedAt;
  final String? name;
  final String? zone;

  /// The board's own view of this MAC (spec §7.12 DEVICE_TABLE), null until
  /// the first table sync.
  final SafrDeviceState? boardState;
  final int boardFlags;

  /// A battery leaf's parents in reach at its last bind (spec §12.7), with
  /// the link RSSI (the weaker direction). Empty for nodes.
  final List<({String mac, int rssi})> parentCandidates;

  bool get retired => boardState == SafrDeviceState.retired;
  bool get expected => boardState == SafrDeviceState.expected;
  bool get pendingRename => boardFlags & SafrDeviceFlags.pendingRename != 0;
  bool get pendingDecommission =>
      boardFlags & SafrDeviceFlags.pendingDecommission != 0;
  bool get heardWhileRetired =>
      boardFlags & SafrDeviceFlags.heardWhileRetired != 0;

  bool get isLeaf => role == SafrNodeRole.leaf;

  /// A leaf is awake for the moments after a frame (a press, a wake) and the
  /// whole time an alarm is latched — it stays up until the RESET (§12.6).
  bool get awake =>
      isLeaf &&
      online &&
      (alarmLatched ||
          DateTime.now().toUtc().difference(lastSeenAt).inSeconds <
              leafAwakeWindow.inSeconds);

  /// Leaves sleep between wakes: online, not awake — the normal state of a
  /// healthy detector (spec §12.2, 60 s cadence).
  bool get sleeping => isLeaf && online && !awake;

  /// Seconds until the leaf's next timer wake (spec §12.2), or null when it is
  /// awake / not a leaf / already late (it then reads as "a qualquer momento").
  int? get nextWakeInSeconds {
    if (!sleeping) return null;
    final since = DateTime.now().toUtc().difference(lastSeenAt).inSeconds;
    final left = leafHeartbeatInterval.inSeconds - since;
    return left > 0 ? left : null;
  }

  /// Walk-test flags (spec §12.7): fewer than two parents in reach, or the
  /// bound link weaker than −85 dBm.
  bool get singleParent => isLeaf && parentCandidates.length < 2;
  bool get weakLink => isLeaf && (rssi ?? 0) < leafWeakLinkDbm;

  /// Unheard for a long time (beyond the offline threshold). The node stays
  /// on the map, dimmed, until the operator clears the registry by hand.
  bool get stale =>
      !online &&
      DateTime.now().toUtc().difference(lastSeenAt) > topologyStaleAfter;
}

/// Silence after which an offline device is drawn dimmed on the map.
const topologyStaleAfter = Duration(minutes: 10);

/// Battery leaf timing (protocol §12.2 / §12.8): fixed 60 s cadence; a frame
/// within the last 3 s means it is still up (walk test, verdict).
const leafHeartbeatInterval = Duration(seconds: 60);
const leafAwakeWindow = Duration(seconds: 3);
const leafWeakLinkDbm = -85;

List<({String mac, int rssi})> _decodeCandidates(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final list = jsonDecode(json);
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map && e['mac'] is String && e['rssi'] is int)
          (mac: e['mac'] as String, rssi: e['rssi'] as int),
    ];
  } catch (_) {
    return const [];
  }
}

/// Graph derived from the trusted device registry + supervision status.
/// Role falls back to a topology heuristic when the device never reported
/// its own role: layer 0 = root, devices with children = relay, rest = leaf.
///
/// Gated by the serial link: with the USB down NOTHING is reachable, so every
/// device is offline — a leaf must never read as "sleeping" behind a dead
/// cable.
///
/// Every registered device stays on the map, however long it has been silent
/// (it is only dimmed once `stale`); the manual "Limpar dispositivos" action
/// is the one way a unit leaves the map.
final topologyProvider = Provider<List<TopologyNode>>((ref) {
  final supervision = ref.watch(supervisionProvider);
  final linkUp = ref.watch(serialLinkProvider) == SerialLinkStatus.connected;

  final parents =
      supervision.map((s) => s.device.parentMac).whereType<String>().toSet();

  return [
    for (final s in supervision)
      TopologyNode(
        mac: s.device.mac,
        role:
            _resolveRole(s.device.role, s.device.layer, s.device.mac, parents),
        layer: s.device.layer,
        parentMac: s.device.parentMac,
        rssi: s.device.lastRssi,
        batteryPct: s.device.batteryPct,
        online: linkUp && s.online,
        lastSeenAt: s.device.lastSeenAt,
        alarmLatched: s.device.alarmLatched == 1,
        alarmLatchedAt: s.device.alarmLatchedAt,
        name: s.device.name,
        zone: s.device.zone,
        boardState: s.device.boardState == null
            ? null
            : SafrDeviceState.fromWire(s.device.boardState!),
        boardFlags: s.device.boardFlags,
        parentCandidates: _decodeCandidates(s.device.parentCandidates),
      ),
  ]..sort((a, b) {
      final byLayer = a.layer.compareTo(b.layer);
      return byLayer != 0 ? byLayer : a.mac.compareTo(b.mac);
    });
});

SafrNodeRole _resolveRole(
  int roleWire,
  int layer,
  String mac,
  Set<String> parents,
) {
  final known = SafrNodeRole.fromWire(roleWire);
  if (known != SafrNodeRole.unknown) return known;
  if (layer == 0) return SafrNodeRole.root;
  if (parents.contains(mac)) return SafrNodeRole.node;
  return SafrNodeRole.leaf;
}
