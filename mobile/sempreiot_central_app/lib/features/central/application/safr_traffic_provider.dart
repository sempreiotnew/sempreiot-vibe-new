import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One frame movement on the mesh, for the topology animation: uplink ticks
/// travel node → root → central, downlink ticks the reverse.
enum SafrTrafficDirection { uplink, downlink }

class SafrTrafficTick {
  const SafrTrafficTick({
    required this.mac,
    required this.direction,
    required this.severity,
    this.ack = false,
  });

  /// The frame is an ACK — downlink: the tablet's confirmation travelling to
  /// the unit (drawn cyan, like the unit's LED when it arrives).

  /// Origin (uplink) or destination (downlink) device MAC.
  final String mac;
  final SafrTrafficDirection direction;

  /// 0 ok · 1 trouble · 2 alert · 3 alarm — colors the traveling packet.
  final int severity;
  final bool ack;
}

class SafrTrafficBus {
  final _controller = StreamController<SafrTrafficTick>.broadcast();

  Stream<SafrTrafficTick> get stream => _controller.stream;

  void emit(SafrTrafficTick tick) {
    if (!_controller.isClosed) _controller.add(tick);
  }

  void dispose() => _controller.close();
}

final safrTrafficProvider = Provider<SafrTrafficBus>((ref) {
  final bus = SafrTrafficBus();
  ref.onDispose(bus.dispose);
  return bus;
});
