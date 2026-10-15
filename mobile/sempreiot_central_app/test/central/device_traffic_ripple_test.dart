import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/theme/app_colors.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_command_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_traffic_ripple.dart';

/// A unit's frames ripple on its Dispositivos card as they do on the Rede
/// map (2026-10-14): a detector's wake is seen on both screens. Its LED is
/// another matter — it follows the real LED, which a timer wake never lights.
void main() {
  const leafMac = 'CC:00:00:00:00:03', nodeMac = 'AA:00:00:00:00:01';
  TopologyNode unit(String mac, SafrNodeRole role) => TopologyNode(
        mac: mac,
        role: role,
        layer: 2,
        parentMac: null,
        rssi: -60,
        batteryPct: null,
        online: true,
        lastSeenAt: DateTime.now().toUtc(),
        alarmLatched: false,
      );
  final leaf = unit(leafMac, SafrNodeRole.leaf);
  final node = unit(nodeMac, SafrNodeRole.node);

  SafrTrafficTick tick(String mac,
          {int severity = 0,
          SafrTrafficDirection direction = SafrTrafficDirection.uplink,
          SafrMsgType msgType = SafrMsgType.heartbeat,
          bool ack = false}) =>
      SafrTrafficTick(
          mac: mac,
          direction: direction,
          severity: severity,
          msgType: msgType,
          ack: ack);

  test(
      'the same rule as the map: a detector\'s every frame, an event, a '
      'command down, an ACK — never a mains unit\'s heartbeat', () {
    expect(trafficRippleColor(tick(leafMac), leaf), AppColors.ledBlue);
    expect(trafficRippleColor(tick(nodeMac), node), isNull);
    expect(
        trafficRippleColor(tick(nodeMac, severity: 3), node), AppColors.error);
    expect(trafficRippleColor(tick(nodeMac, severity: 1), node),
        AppColors.trouble);
    expect(
        trafficRippleColor(
            tick(nodeMac, direction: SafrTrafficDirection.downlink, ack: true),
            node),
        AppColors.ledCyan);
    expect(
        trafficRippleColor(
            tick(nodeMac,
                direction: SafrTrafficDirection.downlink,
                msgType: SafrMsgType.command),
            node),
        AppColors.ledBlue);
    // Another unit's frame is not this one's.
    expect(trafficRippleColor(tick(leafMac), node), isNull);
  });

  testWidgets('a detector\'s wake plays the rings once on its card',
      (tester) async {
    final bus = SafrTrafficBus();
    addTearDown(bus.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [safrTrafficProvider.overrideWithValue(bus)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: Stack(clipBehavior: Clip.none, children: [
                DeviceTrafficRipple(node: leaf, diameter: 64),
              ]),
            ),
          ),
        ),
      ),
    ));
    expect(find.byType(CommandRipple), findsNothing);
    bus.emit(tick(leafMac));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CommandRipple), findsOneWidget);
    // A mains unit's heartbeat on this card: nothing.
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byType(CommandRipple), findsNothing);
    bus.emit(tick(nodeMac));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CommandRipple), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
