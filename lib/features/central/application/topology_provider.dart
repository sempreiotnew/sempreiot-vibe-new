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

  /// Leaves sleep between wakes: online but silent for a while.
  bool get sleeping =>
      role == SafrNodeRole.leaf &&
      online &&
      DateTime.now().toUtc().difference(lastSeenAt).inSeconds > 20;

  /// Unheard for a long time (beyond the offline threshold). The node stays
  /// on the map, dimmed, until the operator clears the registry by hand.
  bool get stale =>
      !online &&
      DateTime.now().toUtc().difference(lastSeenAt) > topologyStaleAfter;
}

/// Silence after which an offline device is drawn dimmed on the map.
const topologyStaleAfter = Duration(minutes: 10);

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
