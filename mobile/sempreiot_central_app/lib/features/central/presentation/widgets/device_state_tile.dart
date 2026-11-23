import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_ext.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart' show SafrNodeRole;
import 'device_avatar.dart';
import 'device_menu.dart';
import 'device_traffic_ripple.dart';

/// A unit named outside the map — Principal's "Estado do sistema": the
/// units in alarm, the units that need attention — **drawn as Rede draws
/// it** (2026-11-23): its product's 3D model in the state it is in (its
/// LED, the red rings of an alarm, OFFLINE, ROOT, the frames crossing it),
/// its **name** and its **endereçamento** under it, then what is said of it
/// here ([status]) and what can be done ([action]). A tap opens the unit's
/// card — the one Rede opens.
///
/// The unit is the map's own when this screen has the map (the tablet's
/// registry; on a user's phone the central's mirror). Where the map is not
/// there yet it is [described] — what the central said of the unit in its
/// retained message: the same model, not tappable.
class DeviceStateTile extends ConsumerWidget {
  const DeviceStateTile({
    super.key,
    required this.mac,
    required this.described,
    required this.accent,
    required this.status,
    this.action,
  });

  final String mac;

  /// The unit as it was described, for a screen without the map.
  final TopologyNode described;

  /// The tile's border: the colour of why the unit is listed.
  final Color accent;

  /// Why it is listed, under the endereçamento.
  final Widget status;

  /// Under the status (Rearmar and its ticks).
  final Widget? action;

  static const width = 140.0;
  static const avatar = 56.0;

  static ValueKey<String> keyOf(String mac) => ValueKey('state-device-$mac');

  /// A unit this screen was told of, with no map to read it from.
  static TopologyNode describe({
    required String mac,
    String? name,
    String? address,
    int? productCode,
    bool leaf = false,
    int? batteryPct,
    bool online = true,
    bool alarm = false,
    DateTime? alarmSince,
  }) =>
      TopologyNode(
        mac: mac,
        role: leaf ? SafrNodeRole.leaf : SafrNodeRole.node,
        layer: 2,
        parentMac: null,
        rssi: null,
        batteryPct: batteryPct,
        online: online,
        lastSeenAt: DateTime.now().toUtc(),
        alarmLatched: alarm,
        alarmLatchedAt: alarmSince,
        name: name,
        address: address,
        productCode: productCode,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(topologyProvider
        .select((nodes) => nodes.where((n) => n.mac == mac).firstOrNull));
    final node = live ?? described;
    final isRoot = live != null &&
        live.online &&
        ref.watch(rootElectionProvider.select((e) => e.isRoot(mac)));
    final named = node.name?.isNotEmpty == true;
    final address = node.address?.isNotEmpty == true
        ? node.address!
        : described.address?.isNotEmpty == true
            ? described.address!
            : null;
    final radius = BorderRadius.circular(14);

    return Semantics(
      button: live != null,
      label: [deviceDisplayName(node), if (address != null) address].join(', '),
      child: Material(
        key: keyOf(mac),
        color: context.bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: accent.withValues(alpha: 0.45)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Builder(builder: (tileContext) {
          return InkWell(
            onTap: live == null
                ? null
                : () => showDeviceMenuFor(tileContext, ref, mac),
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: avatar,
                      child: Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // As on the Rede map: a frame of the unit
                            // crossing the system, and in alarm the red
                            // rings, again and again, with its LED's blink.
                            DeviceTrafficRipple(node: node, diameter: avatar),
                            DeviceAlarmRipple(node: node, diameter: avatar),
                            DeviceModelAvatar(
                                node: node, isRoot: isRoot, size: avatar),
                            if (!node.online)
                              const Positioned(
                                right: -24,
                                top: -8,
                                child: DeviceOfflineBadge(),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      deviceDisplayName(node),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: named ? 13.5 : 10,
                        fontWeight: FontWeight.w700,
                        fontFamily: named ? null : 'monospace',
                      ),
                    ),
                    Text(
                      address ?? 'sem endereçamento',
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: context.textSecondary, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(fit: BoxFit.scaleDown, child: status),
                    if (action != null) action!,
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
