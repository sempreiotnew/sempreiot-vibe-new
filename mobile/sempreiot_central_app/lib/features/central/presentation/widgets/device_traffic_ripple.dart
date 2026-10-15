import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../application/safr_traffic_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_frame.dart' show SafrMsgType;
import 'device_command_widgets.dart';

/// The colour a frame of [node] ripples in — the same rule the Rede map
/// uses to decide which frames travel as packets (mesh_map `_onTraffic`):
/// a battery detector's every frame (its wake is the news that it is
/// alive), an event, a command going down, an ACK either way. Null for a
/// mains unit's routine traffic (heartbeats, topology), which neither the
/// map nor the card shows. Not the unit's LED: a detector's LED stays dark
/// on a timer wake (protocol §12.8), and the screen's LED dot follows the
/// real one exactly.
Color? trafficRippleColor(SafrTrafficTick tick, TopologyNode node) {
  if (tick.mac != node.mac) return null;
  final uplink = tick.direction == SafrTrafficDirection.uplink;
  final leafRoutine = tick.severity < 1 && node.isLeaf && uplink;
  final ackDown = tick.ack && !uplink;
  final commandDown = tick.msgType == SafrMsgType.command && !uplink;
  final unitAckUp = tick.ack && uplink;
  if (tick.severity < 1 &&
      !leafRoutine &&
      !ackDown &&
      !commandDown &&
      !unitAckUp) {
    return null;
  }
  return switch (tick.severity) {
    3 => AppColors.error,
    1 => AppColors.trouble,
    _ => ackDown ? AppColors.ledCyan : AppColors.ledBlue,
  };
}

/// Rings spreading from a unit's avatar on a Dispositivos card when a frame
/// of it crosses the system — what the Rede map shows as the packet
/// leaving (or landing on) the unit, so a detector's wake is seen on both
/// screens. Draws nothing until a frame comes; every frame plays once.
class DeviceTrafficRipple extends ConsumerStatefulWidget {
  const DeviceTrafficRipple({
    super.key,
    required this.node,
    required this.diameter,
  });

  final TopologyNode node;

  /// The avatar's size; the rings start at its rim.
  final double diameter;

  @override
  ConsumerState<DeviceTrafficRipple> createState() =>
      _DeviceTrafficRippleState();
}

class _DeviceTrafficRippleState extends ConsumerState<DeviceTrafficRipple> {
  StreamSubscription<SafrTrafficTick>? _sub;
  Color? _color;
  int _seq = 0;
  Timer? _clear;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(safrTrafficProvider).stream.listen(_onTick);
  }

  void _onTick(SafrTrafficTick tick) {
    final color = trafficRippleColor(tick, widget.node);
    if (color == null || !mounted) return;
    setState(() {
      _color = color;
      _seq++;
    });
    // Gone once played, so an idle card holds no ripple widget at all.
    _clear?.cancel();
    _clear = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _color = null);
    });
  }

  @override
  void dispose() {
    _clear?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    if (color == null) return const SizedBox.shrink();
    final extent = CommandRipple.extentFor(widget.diameter);
    return Positioned(
      left: (widget.diameter - extent) / 2,
      top: (widget.diameter - extent) / 2,
      child: CommandRipple(
        key: ValueKey('traffic-ripple-${widget.node.mac}-$_seq'),
        color: color,
        diameter: widget.diameter,
      ),
    );
  }
}
