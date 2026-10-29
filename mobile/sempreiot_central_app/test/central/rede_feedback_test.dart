import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sempreiot_central_app/core/database/app_database.dart'
    show safrBroadcastMac;

import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_led_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/system_test_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/system_test/system_test_run.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/system_test_sheets.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_command_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/link_down_banner.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/mesh_status_bar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/ota_rede_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/root_election_banner.dart';

/// The Rede screen's feedback (2026-10-08): commands answered on the map
/// itself (no snackbar), the root election as its own banner, units the
/// tablet never heard counted apart instead of vanishing. Every size, both
/// orientations, nothing overflowing.
void main() {
  final now = DateTime.now().toUtc();
  const boardMac = '00:00:00:00:00:B0';
  const rootMac = '5A:46:52:00:00:01';
  const leafMac = '5A:46:52:00:00:02';
  const waitingMac = '5A:46:52:00:00:09';

  TopologyNode node(String mac, int layer, SafrNodeRole role, String? parent,
          {String? name, bool awaiting = false}) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: parent,
        rssi: -60,
        batteryPct: 90,
        online: true,
        lastSeenAt: now,
        alarmLatched: false,
        name: name,
        awaitingSignal: awaiting,
        fwVersion: '0.3.8',
      );

  final mesh = <TopologyNode>[
    node(boardMac, 0, SafrNodeRole.root, null),
    node(rootMac, 1, SafrNodeRole.root, boardMac, name: 'Sirene Hall'),
    node(leafMac, 2, SafrNodeRole.node, rootMac, name: 'Botoeira Sala'),
    node(waitingMac, -1, SafrNodeRole.leaf, null,
        name: 'Detector Cozinha', awaiting: true),
  ];

  const sizes = {
    'phone portrait': Size(390, 844),
    'phone landscape': Size(844, 390),
    'tablet landscape': Size(1280, 800),
  };

  late StreamController<String> deliveries;
  late Completer<bool> boardAck;

  Future<ProviderContainer> pump(WidgetTester tester, Size size,
      {bool linkUp = true}) async {
    // The default notifier opens the real port (and reads "connecting");
    // a detached one has no port at all: the cable is out.
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    deliveries = StreamController<String>.broadcast();
    addTearDown(deliveries.close);
    boardAck = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topologyProvider.overrideWithValue(mesh),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          otaPushViewProvider.overrideWithValue(const OtaPushState()),
          // The board is on the cable: Testar tudo is offered.
          boardLinkUpProvider.overrideWithValue(linkUp),
          serialProvider.overrideWith((ref) => SerialNotifier.detached()),
          deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
                send: (_, __) => boardAck.future,
                deliveries: deliveries.stream,
                traffic: ref.watch(safrTrafficProvider).stream,
                nodes: () => ref.read(topologyProvider),
              )),
          // The test's controller without the database.
          systemTestControllerProvider.overrideWith((ref) {
            final c = SystemTestController(
              tracker: ref.watch(deviceCommandProvider.notifier),
              nodes: () => ref.read(topologyProvider),
            );
            ref.listen<Map<String, DeviceCommandStatus>>(
                deviceCommandProvider, (_, next) => c.onCommands(next));
            return c;
          }),
        ],
        child: const MaterialApp(home: TopologyScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    return ProviderScope.containerOf(
        tester.element(find.byType(TopologyScreen)));
  }

  testWidgets(
      'the strip\'s chip switch hides and shows the firmware pills '
      '(2026-10-15)', (tester) async {
    await pump(tester, const Size(1280, 800));
    // The root, the node and the CENTRAL (the board says 0.3.8).
    expect(find.byType(FirmwareTag), findsNWidgets(3));
    await tester.tap(find.byKey(MeshStatusBar.versionsKey));
    await tester.pump();
    expect(find.byType(FirmwareTag), findsNothing);
    await tester.tap(find.byKey(MeshStatusBar.versionsKey));
    await tester.pump();
    expect(find.byType(FirmwareTag), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  for (final s in sizes.entries) {
    testWidgets(
        'Identificar is answered on the map, not in a snackbar — '
        '${s.key}', (tester) async {
      await pump(tester, s.value);
      await tester.tap(find.text('Sirene Hall'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Abrir dispositivo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // A phone on its side: facts and commands side by side, nothing below
      // the fold.
      if (s.value.height < 460) {
        expect(tester.getRect(find.text('Identificar')).left,
            greaterThan(tester.getRect(find.text('SINAL')).right));
      }
      final view = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(tester.getRect(find.text('Identificar')).bottom,
          lessThan(view.height));

      await tester.tap(find.text('Identificar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The popover is gone so the map can be seen; the ticks say the
      // rest, as a message's: a clock, ✓, ✓✓ — no words on screen.
      expect(find.text('Abrir dispositivo'), findsNothing);
      expect(find.byKey(CommandTicks.keySending), findsOneWidget);
      expect(find.textContaining('Identificar'), findsNothing);

      boardAck.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // On the unit and, as the sender's side, on the Central.
      expect(find.byKey(CommandTicks.keyOne), findsNWidgets(2));

      deliveries.add(rootMac);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyTwo), findsNWidgets(2));
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      // The ticks sit beside the unit, on the right — over no name, no
      // version pill, no neighbour (2026-10-14).
      final texts = [
        for (final e in find.byType(Text).evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      final pills = [
        for (final e in find.byType(FirmwareTag).evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      for (final e in find.byKey(CommandTicks.keyTwo).evaluate()) {
        final tick = tester.getRect(find.byWidget(e.widget));
        for (final r in [...texts, ...pills]) {
          expect(tick.overlaps(r), isFalse,
              reason: 'the ticks at $tick run over $r');
        }
      }
      final name = tester.getRect(find.text('Sirene Hall'));
      expect(
          find.byKey(CommandTicks.keyTwo).evaluate().any((e) =>
              tester.getRect(find.byWidget(e.widget)).left > name.center.dx),
          isTrue,
          reason: 'on the right of the unit');

      // It leaves by itself.
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(CommandTicks.keyTwo), findsNothing);
    });

    testWidgets(
        'the board\'s link down is said on Rede, in words, under the '
        'strip (2026-10-14) — ${s.key}', (tester) async {
      // No port at all (the default serial state): the link is down.
      await pump(tester, s.value, linkUp: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(LinkDownBanner.bannerKey), findsOneWidget);
      expect(find.textContaining('Cabo USB desconectado', findRichText: true),
          findsOneWidget);
      expect(find.text('CENTRAL'), findsOneWidget, reason: 'the map stays');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the popover keeps its size and place while the LED blinks '
        'and a command comes and goes — ${s.key}', (tester) async {
      final container = await pump(tester, s.value);
      await tester.tap(find.text('Sirene Hall'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      Map<String, Rect> where() => {
            for (final t in ['COMANDOS', 'Abrir dispositivo', 'TIPO'])
              t: tester.getRect(find.text(t)),
          };
      final placed = where();

      // The unit blinks (IDENTIFY), a command's status appears, then leaves.
      container.read(deviceLedProvider).identify(rootMac, 10);
      container.read(deviceCommandProvider.notifier).applyRemote(
            DeviceCommandStatus(
              mac: rootMac,
              kind: DeviceCommandKind.identify,
              step: DeviceCommandStep.delivered,
              startedAt: DateTime.now(),
            ),
          );
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        expect(where(), placed, reason: 'after ${(i + 1) * 500} ms');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the TEST button on a unit: ✓ then ✓✓ on the map — ${s.key}',
        (tester) async {
      final container = await pump(tester, s.value);
      final bus = container.read(safrTrafficProvider);
      bus.emit(const SafrTrafficTick(
        mac: leafMac,
        direction: SafrTrafficDirection.uplink,
        severity: 2,
        msgType: SafrMsgType.event,
        eventCode: SafrEventCode.manualTest,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyOne), findsOneWidget);
      bus.emit(const SafrTrafficTick(
        mac: leafMac,
        direction: SafrTrafficDirection.downlink,
        severity: 0,
        ack: true,
        msgType: SafrMsgType.ack,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyTwo), findsOneWidget);
      // The Central shows ticks for what it sends, not for what it gets.
      expect(find.byKey(CommandTicks.keyOne), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Rearmar for all: the Central ✓ when the board takes it, ✓✓ '
        'once every unit confirmed — ${s.key}', (tester) async {
      final container = await pump(tester, s.value);
      container
          .read(deviceCommandProvider.notifier)
          .run(safrBroadcastMac, DeviceCommandKind.reset);
      await tester.pump();
      boardAck.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyOne), findsOneWidget); // the Central
      deliveries.add(rootMac);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // One of two confirmed: the Central still waits.
      expect(find.byKey(CommandTicks.keyOne), findsOneWidget);
      expect(find.byKey(CommandTicks.keyTwo), findsOneWidget); // that unit
      deliveries.add(leafMac);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyOne), findsNothing);
      expect(find.byKey(CommandTicks.keyTwo), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      // It goes away.
      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(CommandTicks.keyTwo), findsNothing);
    });

    testWidgets(
        'the Central\'s tick is the broadcast\'s, even when a unit\'s '
        'own ✓✓ arrives later (the phone\'s order) — ${s.key}', (tester) async {
      final container = await pump(tester, s.value);
      final t = container.read(deviceCommandProvider.notifier);
      final t0 = DateTime.now();
      t.applyRemote(DeviceCommandStatus(
        mac: safrBroadcastMac,
        kind: DeviceCommandKind.test,
        step: DeviceCommandStep.boardAck,
        startedAt: t0,
      ));
      t.applyRemote(DeviceCommandStatus(
        mac: rootMac,
        kind: DeviceCommandKind.test,
        step: DeviceCommandStep.delivered,
        startedAt: t0.add(const Duration(seconds: 2)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyOne), findsOneWidget); // the Central
      expect(find.byKey(CommandTicks.keyTwo), findsOneWidget); // the unit
      final one = tester.getRect(find.byKey(CommandTicks.keyOne));
      final central = tester.getRect(find.text('CENTRAL'));
      expect(one.left, greaterThan(central.right - 20),
          reason: 'beside the disc, on the right, off its lines');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Testar tudo lives in the Central\'s popover and is disabled '
        'while a test runs — ${s.key}', (tester) async {
      final container = await pump(tester, s.value);
      expect(find.byTooltip('Teste do sistema'), findsNothing);
      await tester.tap(find.text('CENTRAL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Testar tudo'), findsOneWidget);
      await tester.tap(find.text('Testar tudo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(deviceCommandProvider)[safrBroadcastMac]?.step,
          DeviceCommandStep.sending);
      boardAck.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(systemTestsViewProvider).running, isNotNull,
          reason: 'the run is kept as a thing of its own');
      // Open it again: while it runs the same place cancels it.
      await tester.tap(find.text('CENTRAL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('central-test-all')), findsNothing);
      expect(find.text('Cancelar teste'), findsOneWidget);
      deliveries.add(rootMac);
      await tester.pump();
      await tester.tap(find.text('Cancelar teste'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Ended as cancelled: the report opens by itself, with each unit.
      expect(find.byKey(SystemTestReportSheet.sheetKey), findsOneWidget);
      expect(find.text('CANCELADO'), findsOneWidget);
      expect(find.byKey(const ValueKey('system-test-unit-$rootMac')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('system-test-unit-$leafMac')),
          findsOneWidget);
      expect(find.text('Cancelado'), findsOneWidget, reason: 'the leaf');
      final tests = container.read(systemTestsViewProvider);
      expect(tests.running, isNull);
      expect(tests.recent.single.verdict, SystemTestVerdict.cancelled);
      expect(tests.recent.single.summary, '1 confirmou · 1 cancelado');
      expect(tester.takeException(), isNull);

      // Close the report; the history lists it.
      await tester.tap(find.byTooltip('Fechar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('CENTRAL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Últimos testes'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(SystemTestHistorySheet.sheetKey), findsOneWidget);
      expect(find.textContaining('Cancelado · 1 confirmou · 1 cancelado'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the Central\'s popover lists every unit with its outcome in '
        'the test — ${s.key}', (tester) async {
      await pump(tester, s.value);
      await tester.tap(find.text('CENTRAL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Before a test: the units, with their state.
      expect(find.byKey(const ValueKey('test-tile-$rootMac')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-tile-$leafMac')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-outcome-$rootMac')), findsNothing);
      await tester.tap(find.text('Testar tudo'));
      await tester.pump();
      boardAck.complete(true);
      deliveries.add(rootMac);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Open again: one confirmed, one still pending.
      await tester.tap(find.text('CENTRAL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Confirmado'), findsOneWidget);
      expect(find.text('Pendente'), findsOneWidget);
      expect(find.text('1 confirmou · 1 pendente'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a unit never heard is counted, not drawn — ${s.key}',
        (tester) async {
      await pump(tester, s.value);
      expect(find.text('Detector Cozinha'), findsNothing);
      expect(find.text('AGUARDANDO'), findsOneWidget);
      expect(find.byTooltip('Sincronizar com a placa'), findsOneWidget);
      expect(find.byTooltip('Ressincronizar com a placa'), findsNothing);
      await tester.tap(find.text('AGUARDANDO'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Aguardando o primeiro sinal'), findsOneWidget);
      expect(find.text('Detector Cozinha'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the election banner — ${s.key}', (tester) async {
      tester.view.physicalSize = s.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final since = DateTime.now().toUtc().subtract(const Duration(seconds: 7));
      Widget banner(RootElectionState e) => MaterialApp(
            home: Scaffold(
              body: Column(children: [
                RootElectionBanner(election: e, nodes: mesh),
              ]),
            ),
          );

      await tester.pumpWidget(banner(RootElectionState(
        electingSince: since,
        candidates: const {leafMac},
        lostRoots: const {rootMac},
      )));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Root perdido — elegendo um novo'), findsOneWidget);
      expect(find.text('Sirene Hall'), findsOneWidget); // the lost root
      expect(find.text('Botoeira Sala'), findsOneWidget); // the candidate
      expect(find.text('7 s'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Past the limit: red, and what to check.
      await tester.pumpWidget(banner(RootElectionState(
        electingSince:
            DateTime.now().toUtc().subtract(const Duration(seconds: 45)),
        lostRoots: const {rootMac},
      )));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Sem root há 45 s'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Settled: who won, for a few seconds, then nothing.
      await tester.pumpWidget(banner(RootElectionState(
        roots: const {leafMac},
        electedMac: leafMac,
        electedAfter: const Duration(seconds: 12),
        electedAt: DateTime.now().toUtc(),
      )));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Novo root'), findsOneWidget);
      expect(find.textContaining('12 s'), findsOneWidget);
      await tester.pump(rootElectedBannerFor);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Novo root'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
