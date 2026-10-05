import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_publisher.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_viewer.dart';
import 'package:sempreiot_central_app/features/central/application/device_led_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_controller.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_state.dart';
import 'package:sempreiot_central_app/features/central/application/firmware_library_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_controller.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/supervision_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/led/led_language.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/device_update_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/devices_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/mirror_watchers_button.dart';
import 'package:sempreiot_central_app/features/access/application/central_access_provider.dart';
import 'package:sempreiot_central_app/features/access/application/user_access_provider.dart';
import 'package:sempreiot_central_app/features/access/domain/entities/access_level.dart';
import 'package:sempreiot_central_app/features/access/domain/entities/saved_central.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_release.dart';

import 'fake_mqtt_repo.dart';

/// The tablet's screens on a user's phone, fed by the central mirror: the
/// same picture, nothing to command — and nothing of the phone's own serial
/// port, registry or update machinery started to draw it.
void main() {
  const id = 'us-east-1:central';
  const boardMac = 'BB:00:00:00:00:00';
  const rootMac = 'AA:00:00:00:00:01';
  const sirenMac = 'AA:00:00:00:00:02';

  TopologyNode node(String mac, SafrNodeRole role, int layer, String? name,
          {String? parent, bool alarm = false, bool online = true}) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: parent,
        rssi: -60,
        batteryPct: null,
        online: online,
        lastSeenAt: DateTime.now().toUtc(),
        alarmLatched: alarm,
        name: name,
        productCode: 1,
        fwVersion: '0.2.0',
      );

  final units = [
    node(boardMac, SafrNodeRole.root, 0, null),
    node(rootMac, SafrNodeRole.root, 1, 'Acionador Recepção', parent: boardMac),
    node(sirenMac, SafrNodeRole.node, 2, 'Sirene Corredor',
        parent: rootMac, alarm: true),
  ];

  DeviceUpdateRun run() => DeviceUpdateRun(
        runId: 'r1',
        all: false,
        phases: const [SafrProductFamily.node],
        target: '0.2.1',
        queues: const {
          SafrProductFamily.node: [sirenMac, rootMac],
        },
        units: const {
          sirenMac: DeviceUpdateUnit(
            key: sirenMac,
            family: SafrProductFamily.node,
            state: SafrOtaUnitState.downloading,
            percent: 43,
            attempts: 1,
            versionBefore: '0.2.0',
            version: '0.2.0',
          ),
          rootMac: DeviceUpdateUnit(
            key: rootMac,
            family: SafrProductFamily.node,
            versionBefore: '0.2.0',
            version: '0.2.0',
          ),
        },
        stage: DeviceUpdateStage.rolling,
        startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );

  late FakeMqttRepo repo;
  late ProviderContainer container;
  late CentralMirrorViewer viewer;

  Future<void> pump(WidgetTester tester, Size size, Widget screen,
      {AccessLevel? level}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    repo = FakeMqttRepo();
    final bus = SafrTrafficBus();
    viewer = CentralMirrorViewer(
      centralId: id,
      repo: repo,
      traffic: bus,
      // As centralMirrorProvider wires it.
      onIdentify: (mac, seconds) =>
          container.read(deviceLedProvider).identify(mac, seconds),
    );
    container = ProviderContainer(overrides: [
      centralMirrorProvider.overrideWith((ref) => viewer),
      safrTrafficProvider.overrideWithValue(bus),
      // This user's access to the viewed central (Administrador may update).
      if (level != null)
        savedCentralsProvider.overrideWith((ref) => _Saved(ref, [
              SavedCentral(
                subId: 'sub-central',
                identityId: id,
                name: 'Bloco A Central',
                status: 'ACCEPTED',
                level: level,
                addedAt: DateTime(2026),
              ),
            ])),
    ]);
    container.read(viewedCentralProvider.notifier).state = id;
    viewer.onConnected();
    viewer.setCentralOnline(true);
    repo.deliver(
      mirrorStateTopic(id),
      encodeMirrorState(
          seq: 1, at: DateTime.now(), link: 'connected', nodes: units),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: screen),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The screen leaves; the map's and the mirror's timers stop.
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 2));
  }

  void expectNothingOfThePhoneStarted() {
    expect(container.exists(serialProvider), isFalse);
    expect(container.exists(supervisionProvider), isFalse);
    expect(container.exists(deviceUpdateProvider), isFalse);
    expect(container.exists(otaPushProvider), isFalse);
    expect(container.exists(otaRolloutProvider), isFalse);
    expect(container.exists(firmwareLibraryProvider), isFalse);
  }

  const sizes = {
    'phone upright': Size(390, 844),
    'phone on its side': Size(844, 390),
    'tablet': Size(1280, 800),
  };

  for (final s in sizes.entries) {
    testWidgets('Rede: the map, 3D, no clear and no commands — ${s.key}',
        (tester) async {
      await pump(tester, s.value,
          const Scaffold(body: TopologyScreen(embedded: true)));
      expect(tester.takeException(), isNull);
      expect(find.text('Sirene Corredor'), findsOneWidget);
      expect(find.byTooltip('Ver em 3D (protótipo)'), findsOneWidget);
      expect(find.byTooltip('Ressincronizar com a placa'), findsNothing);

      await tester.tap(find.text('Sirene Corredor'));
      // The menu opens: a frame to lay it out, then its animation.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Dispositivo'), findsOneWidget);
      // In alarm on the tablet — and still nothing to reset from here.
      for (final action in ['Testar', 'Rearmar', 'Som']) {
        expect(find.textContaining(action), findsNothing, reason: action);
      }

      // The one command of a phone: asked to the central, and the LED on
      // screen blinks blue once the central says the root confirmed.
      await tester.tap(find.text('Identificar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
          decodeMirrorIdentify(repo.published.last.payload)!.mac, sirenMac);
      final siren = container
          .read(topologyProvider)
          .firstWhere((n) => n.mac == sirenMac);
      expect(container.read(deviceLedProvider).look(siren).color,
          isNot(LedColor.blue));

      repo.deliver(
        mirrorFramesTopic(id),
        encodeMirrorFrames(
          seq: 1,
          t0: DateTime.now(),
          ticks: const [],
          events: const [
            (kind: MirrorEventKind.identify, mac: sirenMac, arg: 10, text: null),
          ],
        ),
      );
      // The "enviando…" bar leaves, the outcome comes in.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.textContaining('confirmado pelo root'), findsOneWidget);
      // IDENTIFY blinks: blue on, then off — sampled over two seconds.
      final seen = <LedColor?>{};
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        seen.add(container.read(deviceLedProvider).look(siren).color);
      }
      expect(seen, contains(LedColor.blue));
      expectNothingOfThePhoneStarted();
      await leave(tester);
    });

    testWidgets('Dispositivos: every unit of the viewed central — ${s.key}',
        (tester) async {
      await pump(tester, s.value, const Scaffold(body: DevicesScreen()));
      expect(tester.takeException(), isNull);
      expect(find.text('Sirene Corredor'), findsOneWidget);
      expect(find.text('Acionador Recepção'), findsOneWidget);
      expectNothingOfThePhoneStarted();
      await leave(tester);
    });

    testWidgets('Dispositivos: a unit without communication says OFFLINE — '
        '${s.key}', (tester) async {
      await pump(tester, s.value, const Scaffold(body: DevicesScreen()));
      expect(find.text('OFFLINE'), findsNothing);
      repo.deliver(
        mirrorStateTopic(id),
        encodeMirrorState(seq: 2, at: DateTime.now(), link: 'connected', nodes: [
          units[0],
          units[1],
          node(sirenMac, SafrNodeRole.node, 2, 'Sirene Corredor',
              parent: rootMac, online: false),
        ]),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.text('OFFLINE'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('Atualizar dispositivos: the tablet\'s run, view only — '
        '${s.key}', (tester) async {
      await pump(tester, s.value, const DeviceUpdateScreen());
      expect(tester.takeException(), isNull);
      expect(find.text('Nenhuma atualização em andamento'), findsOneWidget);
      expect(find.byKey(const ValueKey('firmware-library')), findsNothing);
      expect(find.byKey(const ValueKey('update-all')), findsNothing);
      // Opening the screen asks the central for its history.
      expect(
          repo.published.any((m) => isMirrorOtaHistoryRequest(m.payload)),
          isTrue);

      repo.deliver(
          mirrorOtaTopic(id), encodeMirrorOta(seq: 1, run: run(), push: null));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('0 de 2 nós atualizados'), findsOneWidget);
      expect(find.byKey(const ValueKey('ota-unit-ring')), findsOneWidget);
      for (final action in ['Pausar', 'Cancelar', 'Retomar', 'Concluir']) {
        expect(find.text(action), findsNothing, reason: action);
      }
      expectNothingOfThePhoneStarted();
      await leave(tester);
    });
  }

  /// What the central says is published, and what its badge counts.
  void offer(String version, {DeviceUpdateRun? running}) => repo.deliver(
        mirrorOtaTopic(id),
        encodeMirrorOta(
          seq: 2,
          run: running,
          push: null,
          releases: [
            FirmwareRelease(
              version: version,
              bucket: '',
              region: '',
              publishedBy: const FirmwarePublisher(who: 'tallesaugusto'),
              images: const {
                SafrProductFamily.board:
                    FirmwareReleaseImage(key: '', size: 900000, sha256: '', project: ''),
                SafrProductFamily.node:
                    FirmwareReleaseImage(key: '', size: 900000, sha256: '', project: ''),
              },
            ),
          ],
          updates: UpdatesAvailable(
            units: {
              SafrProductFamily.node: [sirenMac, rootMac]
            },
            versions: {SafrProductFamily.node: version},
          ),
        ),
      );

  for (final s in const {
    'phone upright': Size(390, 844),
    'phone on its side': Size(844, 390),
  }.entries) {
    testWidgets('an Administrador updates from the phone — ${s.key}',
        (tester) async {
      await pump(tester, s.value, const DeviceUpdateScreen(),
          level: AccessLevel.level4);
      offer('0.3.4');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.text('2 dispositivos com atualização para v0.3.4'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('update-source')), findsNothing,
          reason: 'a phone has only Internet');
      expect(find.byKey(const ValueKey('firmware-library')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('update-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('A VERSÃO MAIS NOVA PUBLICADA DE CADA'), findsOneWidget);
      expect(find.text('Procurar no tablet'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('update-confirm')));
      await tester.tap(find.byKey(const ValueKey('update-confirm')));
      await tester.pump();

      final asked = repo.published.last;
      expect(asked.topic, mirrorUserCommandTopic(id, repo.identityId!),
          reason: 'its own command topic: AWS proves who asks');
      final command = decodeMirrorRemoteOta(asked.payload)!;
      expect(command.all, isTrue);
      // The central answers: started. The sheet closes.
      repo.deliver(
          mirrorFramesTopic(id),
          encodeMirrorFrames(seq: 7, t0: DateTime.now(), ticks: const [], events: [
            (
              kind: MirrorEventKind.otaAnswer,
              mac: command.id,
              arg: MirrorOtaAnswer.started,
              text: null
            ),
          ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('A VERSÃO MAIS NOVA PUBLICADA DE CADA'), findsNothing);
      expectNothingOfThePhoneStarted();
      await leave(tester);
    });
  }

  testWidgets('an Administrador can cancel the run from the phone',
      (tester) async {
    await pump(tester, const Size(390, 844), const DeviceUpdateScreen(),
        level: AccessLevel.level4);
    offer('0.3.4', running: run());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Pausar'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('remote-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('remote-cancel-confirm')));
    await tester.pump();
    expect(decodeMirrorRemoteOta(repo.published.last.payload)!.cancel, isTrue);
    await leave(tester);
  });

  testWidgets('below Administrador: what is available, nothing to press',
      (tester) async {
    await pump(tester, const Size(390, 844), const DeviceUpdateScreen(),
        level: AccessLevel.level2);
    offer('0.3.4', running: run());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('remote-cancel')), findsNothing);
    offer('0.3.4');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('2 dispositivos com atualização para v0.3.4'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('update-all')), findsNothing);
    await leave(tester);
  });

  testWidgets('the eye on the tablet: crossed out, then who is watching',
      (tester) async {
    final container = ProviderContainer(overrides: [
      centralAccessRelationsProvider.overrideWith(
          (ref) => CentralAccessRelationsNotifier(ref)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Center(child: MirrorWatchersButton())),
      ),
    ));
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    expect(find.byTooltip('Ninguém assistindo'), findsOneWidget);

    container.read(mirrorWatchersProvider.notifier).state = [
      MirrorWatcher(
        key: 'sub-ana',
        sub: 'sub-ana',
        name: 'ana@x.com',
        since: DateTime.now().toUtc(),
      ),
      MirrorWatcher(
        key: 'sub-bia',
        sub: 'sub-bia',
        name: 'bia@x.com',
        since: DateTime.now().toUtc(),
      ),
    ];
    await tester.pump();
    expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byType(MirrorWatchersButton));
    await tester.pumpAndSettle();
    expect(find.text('2 usuários assistindo'), findsOneWidget);
    expect(find.text('ana@x.com'), findsOneWidget);
    expect(find.text('sub-bia'), findsOneWidget);
  });
}

/// The user's saved centrals, without the backend.
class _Saved extends SavedCentralsNotifier {
  _Saved(super.ref, List<SavedCentral> centrals) {
    state = centrals;
  }
}
