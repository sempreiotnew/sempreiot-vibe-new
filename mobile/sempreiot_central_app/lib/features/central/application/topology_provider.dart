import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'central_mirror_viewer.dart';
import 'device_labels_provider.dart';
import 'ota_rollout_controller.dart';
import 'ota_rollout_report.dart';
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
    this.address,
    this.zoneId,
    this.addressId,
    this.boardState,
    this.boardFlags = 0,
    this.parentCandidates = const [],
    this.productCode,
    this.hwRev,
    this.fwVersion,
    this.updating = false,
    this.heard = true,
    this.awaitingSignal = false,
    this.dlHeard,
    this.linkDegraded = false,
  });

  final String mac;
  final SafrNodeRole role;
  final int layer;
  final String? parentMac;
  final int? rssi;
  final int? batteryPct;
  final bool online;
  final DateTime lastSeenAt;

  /// It is being updated (protocol §13.4): its row of the rollout is
  /// offered / downloading / verifying / rebooting / in self-test, for less
  /// than 300 s. It then reads "Atualizando", never "Sem comunicação", and
  /// stays [online] while it restarts.
  final bool updating;

  /// Heard within its supervision time — the rule without the exception
  /// above. False with [online] true: silent because it is restarting into
  /// its new firmware. Nothing of what it does then crosses the wire, so
  /// its LED on screen is dark.
  final bool heard;

  /// Known only from the board's table (or INSTALLATION): this tablet has
  /// not heard a frame of it yet, so its level and parent are unknown and
  /// it is not drawn in the tree — [layer] is then -1. The Rede strip
  /// counts it as "aguardando o primeiro sinal"; its first frame places it.
  final bool awaitingSignal;

  /// Alarm held on the panel (SAFR v3 §7.1.4) until the operator RESET.
  final bool alarmLatched;
  final DateTime? alarmLatchedAt;
  final String? name;

  /// The unit's zone and endereçamento (protocol §14.1): the names the
  /// board's label tables give the ids; null = none or not reported.
  final String? zone;
  final String? address;
  final int? zoneId;
  final int? addressId;

  /// The board's own view of this MAC (spec §7.12 DEVICE_TABLE), null until
  /// the first table sync.
  final SafrDeviceState? boardState;
  final int boardFlags;

  /// A battery leaf's parents in reach at its last bind (spec §12.7), with
  /// the link RSSI (the weaker direction). Empty for nodes.
  final List<({String mac, int rssi})> parentCandidates;

  /// v3.5 product identity as the unit (or the board's table) reported it;
  /// null = never reported (firmware older than v3.5).
  final int? productCode;
  final int? hwRev;
  final String? fwVersion;

  /// v3.6 DL_HEARD (protocol §7.3): board heartbeats this node heard in the
  /// last 120 s, of [dlHeardExpected]; null = not reported (leaf, older
  /// firmware, or not 120 s on this link yet).
  final int? dlHeard;

  /// The §9.4 trouble "qualidade do enlace degradada" is up for this unit
  /// (supervision_provider.dart: ≤ 6 of 8 heard; restored at 8 of 8).
  final bool linkDegraded;

  static const dlHeardExpected = SafrHeartbeatPayload.dlHeardExpected;

  /// Board heartbeats lost in the last 120 s; null when nothing is reported.
  int? get dlLost => dlHeard == null ? null : dlHeardExpected - dlHeard!;

  /// A powered unit whose link to its parent reads below the bind threshold
  /// (−85 dBm, protocol §9.4 / §12.3): "enlace fraco" — put a node between
  /// it and its parent. The root's hop to the board counts too.
  bool get weakPoweredLink =>
      !isLeaf && layer >= 1 && rssi != null && rssi! < leafWeakLinkDbm;

  /// Something about this unit's link to tell the installer: weak, or losing
  /// the board's heartbeats.
  bool get linkAttention => weakPoweredLink || linkDegraded;

  /// Catalogue entry (or unknown-product placeholder); null = not reported.
  SafrProduct? get product => SafrProduct.fromCode(productCode);

  /// The "Produto" fact: "Sirene · SIOT-SIREN-01", or '' when not reported.
  String get productLabel => product?.display ?? '';

  /// The "Firmware" fact: the version, or '' when not reported.
  String get firmwareLabel => fwVersion ?? '';

  bool get retired => boardState == SafrDeviceState.retired;
  bool get expected => boardState == SafrDeviceState.expected;
  bool get pendingRename => boardFlags & SafrDeviceFlags.pendingRename != 0;
  bool get pendingDecommission =>
      boardFlags & SafrDeviceFlags.pendingDecommission != 0;
  bool get heardWhileRetired =>
      boardFlags & SafrDeviceFlags.heardWhileRetired != 0;

  bool get isLeaf => role == SafrNodeRole.leaf;

  /// Its type — Central / Dispositivo AC / Dispositivo Bateria — from how
  /// it lives on the network (the board at layer 0, a leaf by its role,
  /// everything else mains), never from the product code: a product may run
  /// as the other type (a push-button station on batteries, 2026-10-29).
  SafrProductFamily get family => layer == 0
      ? SafrProductFamily.board
      : isLeaf
          ? SafrProductFamily.leaf
          : SafrProductFamily.node;

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

/// "zona #3" for an id whose name this tablet does not hold yet; null for
/// none (0 / never reported).
String? _labelIdText(String kind, int? id) =>
    id == null || id == 0 ? null : '$kind #$id';

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
/// (it is only dimmed once `stale`); it leaves the map when forgotten, or
/// on a "Sincronizar com a placa" that finds it out of the board's table and
/// silent (board_sync_provider.dart).
///
/// USER mode with a central open: the units come from that central's mirror
/// (central_mirror_viewer.dart), and nothing of this device's registry,
/// serial port or rollout is touched.
final topologyProvider = Provider<List<TopologyNode>>((ref) {
  if (ref.watch(viewedCentralProvider) != null) {
    return ref.watch(mirrorTopologyProvider);
  }
  final supervision = ref.watch(supervisionProvider);
  final linkUp = ref.watch(serialLinkProvider) == SerialLinkStatus.connected;
  // The rollout moves faster than the supervision rule runs: who is being
  // updated is read from it, the grace from the clock.
  final updatingUnits = ref.watch(otaUpdatingUnitsProvider);
  final grace = ref.watch(otaRolloutTimingsProvider).updatingGrace;
  final labels = ref.watch(labelIndexProvider);
  final now = DateTime.now();

  final parents =
      supervision.map((s) => s.device.parentMac).whereType<String>().toSet();

  return [
    for (final s in supervision)
      TopologyNode(
        mac: s.device.mac,
        role: _resolveRole(
            s.device.role,
            s.device.registryState == 'enrolled' ? -1 : s.device.layer,
            s.device.mac,
            parents),
        // Never heard: its level is unknown — and 0 would make it the board.
        layer: s.device.registryState == 'enrolled' ? -1 : s.device.layer,
        awaitingSignal: s.device.registryState == 'enrolled',
        parentMac: s.device.parentMac,
        rssi: s.device.lastRssi,
        batteryPct: s.device.batteryPct,
        online: linkUp && s.online,
        lastSeenAt: s.device.lastSeenAt,
        alarmLatched: s.device.alarmLatched == 1,
        alarmLatchedAt: s.device.alarmLatchedAt,
        name: s.device.name,
        // The name behind the board's id; the id itself while the label
        // table has not reached this tablet yet (never "—" for a unit that
        // has one).
        zone: labels.name(SafrLabelKind.zone, s.device.zoneId) ??
            _labelIdText('zona', s.device.zoneId),
        address: labels.name(SafrLabelKind.address, s.device.addressId) ??
            _labelIdText('endereçamento', s.device.addressId),
        zoneId: s.device.zoneId,
        addressId: s.device.addressId,
        boardState: s.device.boardState == null
            ? null
            : SafrDeviceState.fromWire(s.device.boardState!),
        boardFlags: s.device.boardFlags,
        parentCandidates: _decodeCandidates(s.device.parentCandidates),
        productCode: s.device.productCode,
        hwRev: s.device.hwRev,
        fwVersion: s.device.fwVersion,
        updating: linkUp && updatingUnits.updatingAt(s.device.mac, now, grace),
        heard: linkUp && s.heard,
        dlHeard: s.device.dlHeard,
        linkDegraded: s.device.linkDegraded == 1,
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
