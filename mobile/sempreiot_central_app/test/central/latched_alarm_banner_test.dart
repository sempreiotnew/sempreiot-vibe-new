import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/alarm_latch_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/system_test_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_command_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/latched_alarm_banner.dart';

/// The alarm-hold banner (2026-11-12): Rearmar per device, Rearmar tudo for
/// the devices listed — a RESET to each of them and to nobody else, never a
/// command to every unit (which the map drew as a system test).
void main() {
  const a = '5A:46:52:00:00:01';
  const b = '5A:46:52:00:00:02';
  final t0 = DateTime.utc(2026, 11, 12);

  MeshDevice device(String mac, String name) => MeshDevice(
        mac: mac,
        role: 1,
        layer: 1,
        linkDegraded: 0,
        firstSeenAt: t0,
        lastSeenAt: t0,
        lastBootCtr: 0,
        lastMsgCtr: 0,
        supervisionState: 0,
        name: name,
        linkKind: 0,
        lastDevSeq: 0,
        alarmLatched: 1,
        boardFlags: 0,
      );

  const sizes = {
    'phone portrait': Size(390, 844),
    'phone landscape': Size(844, 390),
    'tablet landscape': Size(1280, 800),
  };

  late List<(String, DeviceCommandKind)> sent;
  late StreamController<String> deliveries;
  late Completer<bool> boardAck;

  Future<ProviderContainer> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    sent = [];
    deliveries = StreamController<String>.broadcast();
    addTearDown(deliveries.close);
    boardAck = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          latchedAlarmsProvider.overrideWith((ref) => Stream.value(
              [device(a, 'Botoeira Sala'), device(b, 'Sirene Hall')])),
          topologyProvider.overrideWithValue(const []),
          deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
                send: (mac, kind) {
                  sent.add((mac, kind));
                  return boardAck.future;
                },
                deliveries: deliveries.stream,
              )),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: LatchedAlarmBanner()),
          ),
        ),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(
        tester.element(find.byType(LatchedAlarmBanner)));
  }

  for (final s in sizes.entries) {
    testWidgets('Rearmar on one device: a RESET to it alone — ${s.key}',
        (tester) async {
      final container = await pump(tester, s.value);
      expect(find.text('Rearmar tudo'), findsOneWidget);
      expect(find.text('Rearmar'), findsNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('alarm-rearm-$a')));
      await tester.pump();
      expect(sent, [(a, DeviceCommandKind.reset)]);
      // Its clock; its own button waits, the other device's does not.
      expect(find.byKey(CommandTicks.keySending), findsOneWidget);
      TextButton button(String mac) =>
          tester.widget(find.byKey(ValueKey('alarm-rearm-$mac')));
      expect(button(a).onPressed, isNull);
      expect(button(b).onPressed, isNotNull);

      boardAck.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyOne), findsOneWidget);
      expect(button(a).onPressed, isNull); // still waits for the unit

      deliveries.add(a);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyTwo), findsOneWidget);
      // Never a command to every unit.
      expect(container.read(deviceCommandProvider)[safrBroadcastMac], isNull);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 6)); // the status leaves
    });

    testWidgets(
        'Rearmar tudo: a RESET to each device listed, none to every '
        'unit — ${s.key}', (tester) async {
      final container = await pump(tester, s.value);
      await tester.tap(find.byKey(LatchedAlarmBanner.keyRearmAll));
      await tester.pump();
      expect(
          sent, [(a, DeviceCommandKind.reset), (b, DeviceCommandKind.reset)]);
      expect(container.read(deviceCommandProvider)[safrBroadcastMac], isNull);
      expect(find.byKey(CommandTicks.keySending), findsNWidgets(2));
      // Nothing left to rearm until they answer.
      final all = tester
          .widget<FilledButton>(find.byKey(LatchedAlarmBanner.keyRearmAll));
      expect(all.onPressed, isNull);
      expect(tester.takeException(), isNull);

      // No answer at all: red, and each can be tried again.
      boardAck.complete(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyFailed), findsNWidgets(2));
      expect(
          tester
              .widget<FilledButton>(find.byKey(LatchedAlarmBanner.keyRearmAll))
              .onPressed,
          isNotNull);
      await tester.pump(const Duration(seconds: 11)); // the status leaves
    });
  }

  test(
      'a command to every unit that is not a test is not the test\'s to cancel',
      () {
    // The board never answers: the command stays on its way.
    final tracker =
        DeviceCommandTracker(send: (_, __) => Completer<bool>().future);
    final tests = SystemTestController(tracker: tracker, nodes: () => const []);
    tracker.run(safrBroadcastMac, DeviceCommandKind.reset);
    expect(tests.cancel(), isFalse);
    expect(tracker.state[safrBroadcastMac]!.broadcastRunning, isTrue);
    tracker.dispose();
    tests.dispose();
  });
}
