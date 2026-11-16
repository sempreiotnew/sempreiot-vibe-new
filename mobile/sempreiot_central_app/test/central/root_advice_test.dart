import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/board_signal_provider.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_viewer.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_controller.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_source.dart';
import 'package:sempreiot_central_app/features/central/application/root_advisor_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/system_test_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_command_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/root_advice_banner.dart';

/// "Another unit hears the central better than the root" (2026-11-13):
/// every mains unit says how it hears the board (HEARTBEAT BOARD_RSSI,
/// protocol §7.3), the central finds the better root, a person says yes
/// (COMMAND ROOT_TAKE, §7.6; from a phone: central-mirror.md §4.12).
void main() {
  const board = 'BB:00:00:00:00:00';
  const root = 'AA:00:00:00:00:01';
  const mid = 'AA:00:00:00:00:02';
  const outside = 'AA:00:00:00:00:03';
  const detector = 'CC:00:00:00:00:04';
  final t0 = DateTime.utc(2026, 11, 13, 10);

  TopologyNode node(
    String mac,
    int layer, {
    SafrNodeRole role = SafrNodeRole.node,
    int? boardRssi,
    int? rssi = -60,
    bool online = true,
    bool alarm = false,
    bool suggested = false,
    String? name,
  }) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: null,
        rssi: rssi,
        batteryPct: null,
        online: online,
        lastSeenAt: t0,
        alarmLatched: alarm,
        name: name,
        boardRssi: boardRssi,
        suggestedRoot: suggested,
      );

  /// The building of 2026-11-13: the root at −71, "outside" three hops
  /// down and closest to the board.
  List<TopologyNode> mesh({int outsideRssi = -48, bool alarm = false}) => [
        node(board, 0, role: SafrNodeRole.root),
        node(root, 1, role: SafrNodeRole.root, boardRssi: -71, name: '1 andar'),
        node(mid, 2, boardRssi: -66, name: '2 andar'),
        node(outside, 3, boardRssi: outsideRssi, name: 'outside', alarm: alarm),
        node(detector, 4, role: SafrNodeRole.leaf),
      ];

  group('the heartbeat says it', () {
    Uint8List heartbeat(int length, {int board = 0xD0}) {
      final p = Uint8List(length);
      p[12] = 0xC4; // −60 to the parent
      p[19] = 3;
      if (length > 20) p[20] = 8;
      if (length > 22) p[22] = board;
      return p;
    }

    test('BOARD_RSSI is the 23rd byte; absent or 0x7F = not said', () {
      expect(SafrHeartbeatPayload.parse(heartbeat(23))!.boardRssi, -48);
      expect(SafrHeartbeatPayload.parse(heartbeat(23, board: 0x7F))!.boardRssi,
          isNull);
      expect(SafrHeartbeatPayload.parse(heartbeat(22))!.boardRssi, isNull);
      expect(SafrHeartbeatPayload.parse(heartbeat(20))!.boardRssi, isNull);
    });

    test('kept per unit from the heartbeats; gone when the unit stops', () {
      final n = BoardSignalNotifier();
      SafrTrafficTick hb(int? rssi) => SafrTrafficTick(
            mac: outside,
            direction: SafrTrafficDirection.uplink,
            severity: 0,
            msgType: SafrMsgType.heartbeat,
            boardRssi: rssi,
          );
      n.onTick(hb(-48));
      expect(n.state, {outside: -48});
      // Another frame of the unit says nothing about it.
      n.onTick(const SafrTrafficTick(
        mac: outside,
        direction: SafrTrafficDirection.uplink,
        severity: 0,
        msgType: SafrMsgType.event,
      ));
      expect(n.state, {outside: -48});
      n.onTick(hb(null));
      expect(n.state, isEmpty);
    });
  });

  group('the central finds the better root', () {
    late DateTime now;
    late RootAdvisor advisor;
    void feed(List<TopologyNode> nodes,
            {String? rootMac = root, bool linkUp = true}) =>
        advisor.update(nodes, rootMac: rootMac, linkUp: linkUp);

    setUp(() {
      now = t0;
      // The production rule, whatever the bench runs with.
      advisor =
          RootAdvisor(clock: () => now, holdFor: RootAdvisor.productionHoldFor);
    });

    test('only after ten minutes of hearing the board 10 dB better', () {
      feed(mesh());
      expect(advisor.state, isNull, reason: 'one reading proves nothing');
      now = t0.add(const Duration(minutes: 9, seconds: 59));
      feed(mesh());
      expect(advisor.state, isNull);
      now = t0.add(const Duration(minutes: 10));
      feed(mesh());
      expect(
          advisor.state,
          const RootAdvice(
              mac: outside, rssi: -48, rootMac: root, rootRssi: -71));
      expect(advisor.state!.gainDb, 23);
    });

    test('a break starts the ten minutes again; 9 dB is not enough', () {
      feed(mesh());
      now = t0.add(const Duration(minutes: 6));
      feed(mesh(outsideRssi: -62)); // 9 dB better: not a clear gain
      now = t0.add(const Duration(minutes: 11));
      feed(mesh());
      expect(advisor.state, isNull, reason: 'counted again from minute 11');
      now = t0.add(const Duration(minutes: 21));
      feed(mesh());
      expect(advisor.state?.mac, outside);
    });

    test('never a battery unit, a unit out of reach, or one not reporting', () {
      final nodes = [
        node(board, 0, role: SafrNodeRole.root),
        node(root, 1, role: SafrNodeRole.root, boardRssi: -71),
        node(detector, 2, role: SafrNodeRole.leaf, boardRssi: -30),
        node(mid, 2, boardRssi: -30, online: false),
        node(outside, 3),
      ];
      feed(nodes);
      now = t0.add(const Duration(minutes: 11));
      feed(nodes);
      expect(advisor.state, isNull);
    });

    test('nothing with an alarm held, an election running or no link', () {
      feed(mesh());
      now = t0.add(const Duration(minutes: 11));
      feed(mesh());
      expect(advisor.state, isNotNull);
      feed(mesh(alarm: true));
      expect(advisor.state, isNull);
      feed(mesh());
      expect(advisor.state, isNull, reason: 'the ten minutes start again');
      now = t0.add(const Duration(minutes: 22));
      feed(mesh());
      expect(advisor.state, isNotNull);
      feed(mesh(), rootMac: null);
      expect(advisor.state, isNull);
      now = t0.add(const Duration(minutes: 33));
      feed(mesh());
      feed(mesh(), linkUp: false);
      expect(advisor.state, isNull);
    });

    test('a root on older firmware: its link to the board is the measure', () {
      final nodes = [
        node(board, 0, role: SafrNodeRole.root),
        node(root, 1, role: SafrNodeRole.root, rssi: -71),
        node(outside, 3, boardRssi: -48),
      ];
      feed(nodes);
      now = t0.add(const Duration(minutes: 10));
      feed(nodes);
      expect(advisor.state?.rootRssi, -71);
    });

    test('after a change was tried: quiet for an hour', () {
      feed(mesh());
      now = t0.add(const Duration(minutes: 10));
      feed(mesh());
      advisor.noteAttempt();
      expect(advisor.state, isNull);
      now = t0.add(const Duration(minutes: 40));
      feed(mesh());
      now = t0.add(const Duration(minutes: 69));
      feed(mesh());
      expect(advisor.state, isNull);
      now = t0.add(const Duration(minutes: 71));
      feed(mesh());
      expect(advisor.state?.mac, outside);
    });

    test('"Agora não": that unit is not suggested again for a day', () {
      feed(mesh());
      now = t0.add(const Duration(minutes: 10));
      feed(mesh());
      advisor.dismiss(outside);
      expect(advisor.state, isNull);
      now = t0.add(const Duration(hours: 23));
      feed(mesh());
      expect(advisor.state, isNull);
      now = t0.add(const Duration(hours: 25));
      feed(mesh());
      expect(advisor.state?.mac, outside);
    });
  });

  group('the command', () {
    late StreamController<String> deliveries;
    late StreamController<SafrTrafficTick> traffic;

    setUp(() {
      deliveries = StreamController<String>.broadcast();
      traffic = StreamController<SafrTrafficTick>.broadcast();
    });

    SafrTrafficTick hb() => const SafrTrafficTick(
          mac: outside,
          direction: SafrTrafficDirection.uplink,
          severity: 0,
          msgType: SafrMsgType.heartbeat,
        );

    test('sent → the board → the unit confirms → the map says it is the root',
        () {
      fakeAsync((async) {
        var nodes = mesh();
        final t = DeviceCommandTracker(
          send: (_, __) async => true,
          deliveries: deliveries.stream,
          traffic: traffic.stream,
          nodes: () => nodes,
        );
        t.run(outside, DeviceCommandKind.takeRoot);
        async.flushMicrotasks();
        deliveries.add(outside);
        async.flushMicrotasks();
        final confirmed = t.state[outside]!;
        expect(confirmed.step, DeviceCommandStep.delivered);
        expect(confirmed.inFlight, isTrue);
        expect(
            commandStepText(confirmed), 'Tornar root · confirmado, trocando');

        // Still three hops down: a heartbeat changes nothing.
        traffic.add(hb());
        async.flushMicrotasks();
        expect(t.state[outside]!.step, DeviceCommandStep.delivered);

        nodes = [
          node(board, 0, role: SafrNodeRole.root),
          node(outside, 1, role: SafrNodeRole.root, boardRssi: -48),
          node(root, 2, boardRssi: -71),
        ];
        traffic.add(hb());
        async.flushMicrotasks();
        expect(t.state[outside]!.step, DeviceCommandStep.answered);
        expect(
            commandStepText(t.state[outside]!), 'Tornar root · é o root agora');
        t.dispose();
      });
    });

    test('confirmed and never the root: red, "não assumiu"', () {
      fakeAsync((async) {
        final t = DeviceCommandTracker(
          send: (_, __) async => true,
          deliveries: deliveries.stream,
          traffic: traffic.stream,
          nodes: mesh,
        );
        t.run(outside, DeviceCommandKind.takeRoot);
        async.flushMicrotasks();
        deliveries.add(outside);
        async.flushMicrotasks();
        async.elapse(rootTakeWindow + const Duration(seconds: 1));
        expect(t.state[outside]!.step, DeviceCommandStep.failed);
        expect(t.state[outside]!.note, DeviceCommandTracker.notRootNote);
        t.dispose();
      });
    });

    test('on the wire: a new kind after Reiniciar; root_take round trip', () {
      expect(DeviceCommandKind.values.last, DeviceCommandKind.takeRoot);
      expect(DeviceCommandKind.restart.index, 8);
      expect(SafrCommand.rootTake.wire, 0x08);
      final back = decodeMirrorRemoteTest(
          encodeMirrorRootTake(id: 'k1', mac: outside, name: 'Ana'))!;
      expect((back.mac, back.takeRoot, back.restart), (outside, true, false));
      expect(
          decodeMirrorRemoteTest(
                  encodeMirrorUnitRestart(id: 'r1', mac: outside))!
              .takeRoot,
          isFalse);
    });

    test('the snapshot carries each unit\'s signal and the suggested one', () {
      final state = decodeMirrorState(encodeMirrorState(
        seq: 1,
        at: t0,
        link: 'connected',
        nodes: [
          node(root, 1, role: SafrNodeRole.root, boardRssi: -71),
          asSuggestedRoot(node(outside, 3, boardRssi: -48)),
        ],
      ))!;
      expect([for (final n in state.nodes) n.boardRssi], [-71, -48]);
      expect([for (final n in state.nodes) n.suggestedRoot], [false, true]);
      // The suggestion is part of what the map says: it is published when
      // it changes. The dBm alone is not.
      expect(
          mirrorStateSignature('connected', [node(outside, 3, boardRssi: -48)]),
          mirrorStateSignature(
              'connected', [node(outside, 3, boardRssi: -50)]));
      expect(
          mirrorStateSignature('connected', [node(outside, 3)]),
          isNot(mirrorStateSignature(
              'connected', [asSuggestedRoot(node(outside, 3))])));
    });
  });

  group('the line on Rede', () {
    const sizes = {
      'phone portrait': Size(390, 844),
      'phone landscape': Size(844, 390),
      'tablet landscape': Size(1280, 800),
    };
    const advice =
        RootAdvice(mac: outside, rssi: -48, rootMac: root, rootRssi: -71);

    Future<(ProviderContainer, List<(String, DeviceCommandKind)>)> pump(
      WidgetTester tester,
      Size size, {
      RootAdvice? shown = advice,
      bool phone = false,
      bool admin = true,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sent = <(String, DeviceCommandKind)>[];
      final advisor = RootAdvisor();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          topologyProvider.overrideWithValue(mesh()),
          rootAdviceProvider.overrideWithValue(shown),
          rootAdvisorProvider.overrideWith((ref) => advisor),
          mirrorViewOnlyProvider.overrideWithValue(phone),
          mirrorCanUpdateProvider.overrideWithValue(admin),
          deviceUpdateRunProvider.overrideWithValue(null),
          systemTestsViewProvider.overrideWithValue(const SystemTestsState()),
          deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
                send: (mac, kind) async {
                  sent.add((mac, kind));
                  return true;
                },
              )),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(children: [RootAdviceBanner(nodes: mesh())]),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      return (
        ProviderScope.containerOf(
            tester.element(find.byType(RootAdviceBanner))),
        sent
      );
    }

    for (final s in sizes.entries) {
      testWidgets('which unit, by how much, and two taps — ${s.key}',
          (tester) async {
        final (container, sent) = await pump(tester, s.value);
        expect(find.byKey(RootAdviceBanner.bannerKey), findsOneWidget);
        expect(find.text('outside ouve a central melhor que o root atual'),
            findsOneWidget);
        expect(find.textContaining('-48 dBm, contra -71 dBm de 1 andar'),
            findsOneWidget);
        await tester.tap(find.byKey(RootAdviceBanner.takeKey));
        await tester.pump();
        expect(find.text('Toque de novo para trocar'), findsOneWidget);
        expect(sent, isEmpty, reason: 'the first tap only arms it');
        await tester.tap(find.byKey(RootAdviceBanner.takeKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(sent, [(outside, DeviceCommandKind.takeRoot)]);
        expect(container.read(deviceCommandProvider)[outside]!.kind,
            DeviceCommandKind.takeRoot);
        // The same line now says where the change is.
        expect(find.textContaining('outside — Tornar root'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 30));
      });
    }

    testWidgets('nothing to suggest: nothing on the screen', (tester) async {
      await pump(tester, const Size(390, 844), shown: null);
      expect(find.byKey(RootAdviceBanner.bannerKey), findsNothing);
      expect(find.byKey(RootAdviceBanner.takeKey), findsNothing);
    });

    testWidgets('a phone below Administrador: shown, nothing to press',
        (tester) async {
      final (_, sent) =
          await pump(tester, const Size(390, 844), phone: true, admin: false);
      expect(find.textContaining('Só um Administrador desta central'),
          findsOneWidget);
      expect(find.byKey(RootAdviceBanner.laterKey), findsNothing);
      await tester.tap(find.byKey(RootAdviceBanner.takeKey));
      await tester.pump();
      expect(find.text('Toque de novo para trocar'), findsNothing);
      expect(sent, isEmpty);
    });
  });
}
