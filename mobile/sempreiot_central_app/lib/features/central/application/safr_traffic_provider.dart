import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';

/// One frame movement on the mesh, for the topology animation: uplink ticks
/// travel node → root → central, downlink ticks the reverse.
enum SafrTrafficDirection { uplink, downlink }

class SafrTrafficTick {
  const SafrTrafficTick({
    required this.mac,
    required this.direction,
    required this.severity,
    this.ack = false,
    this.parentMac,
    this.msgType,
    this.eventCode,
    this.uptimeS,
  });

  /// Uplink: the parent the frame itself names (HEARTBEAT / TOPOLOGY
  /// PARENT_MAC), so the packet follows the link the unit actually used —
  /// the registry may still hold the previous parent when the tick fires.

  /// The frame is an ACK — downlink: the tablet's confirmation travelling to
  /// the unit (drawn cyan, like the unit's LED when it arrives).

  /// Origin (uplink) or destination (downlink) device MAC.
  final String mac;
  final SafrTrafficDirection direction;

  /// 0 ok · 1 trouble · 2 alert · 3 alarm — colors the traveling packet.
  final int severity;
  final bool ack;
  final String? parentMac;

  /// The frame's MSG_TYPE — decides the LED pulse it lit on the unit
  /// (tick 100 ms vs message 500 ms, siot_ui_led.c `is_message`).
  final SafrMsgType? msgType;

  /// EVENT frames only: a leaf lights its LED for MANUAL_TEST alone.
  final SafrEventCode? eventCode;

  /// HEARTBEAT only: the unit's UPTIME_S — tells a reboot apart (the alarm
  /// lives in RAM on the unit, so a reboot ends it).
  final int? uptimeS;
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
