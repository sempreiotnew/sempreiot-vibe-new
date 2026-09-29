import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/alarm_latch_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_board_events_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_image.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/firmware_update_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/network_3d_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/ota_rede_widgets.dart';

import 'fake_firmware.dart';

/// The Rede screens (map and 3D) while a firmware push is in flight and
/// after it: where the firmware is going, who receives it, what every unit
/// runs. The only unit that ever receives anything is the board.
class _Port extends SerialNotifier {
  _Port() : super.detached();

  @override
  Future<bool> portWrite(Uint8List bytes) async => true;

  @override
  Future<bool> portSetBaud(int baud) async => true;
}

class _Controller extends OtaPushController {
  _Controller(super.ref, OtaPushState initial) {
    state = initial;
  }
}

/// The push the screens read; a test moves it.
final _push = StateProvider<OtaPushState>((_) => const OtaPushState());

const _board = '7C:4F:AD:AE:85:90';
const _root = '5A:46:52:00:00:01';
const _siren = '5A:46:52:00:00:02';
const _old = '5A:46:52:00:00:03';
const _leaf = '5A:46:52:00:00:04';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final now = DateTime.now().toUtc();
  TopologyNode node(
    String mac,
    int layer,
    SafrNodeRole role,
    String? parent, {
    int? productCode,
    String? fw,
  }) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: parent,
        rssi: layer == 0 ? null : -60,
        batteryPct: null,
        online: true,
        lastSeenAt: now,
        alarmLatched: false,
        productCode: productCode,
        fwVersion: fw,
      );

  final mesh = <TopologyNode>[
    node(_board, 0, SafrNodeRole.root, null,
        productCode: 0x0100, fw: '0.1.0-dev'),
    node(_root, 1, SafrNodeRole.root, _board,
        productCode: 0x0204, fw: '0.1.0-dev'),
    node(_siren, 2, SafrNodeRole.node, _root,
        productCode: 0x0201, fw: '0.1.0-dev'),
    node(_old, 2, SafrNodeRole.node, _root), // never said what it runs
    node(_leaf, 3, SafrNodeRole.leaf, _siren,
        productCode: 0x0301, fw: '0.1.0-dev'),
  ];

  const sizes = <String, Size>{
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(360, 640),
    'phone landscape': Size(640, 360),
  };

  FirmwareFile file(String project, {String version = '0.1.1'}) {
    final bytes =
        fakeFirmware(project: project, version: version, size: 100 * 4096);
    return FirmwareFile(
      name: '$project.bin',
      bytes: bytes,
      header: FirmwareImageHeader.parse(bytes),
      sha256: Uint8List(32),
    );
  }

  OtaPushState push(
    OtaPushPhase phase, {
    String project = 'sempreiot-board',
    int chunksDone = 0,
    String? boardVersion,
    String? message,
    bool boardRestarted = false,
    Map<SafrProductFamily, String> stored = const {},
    List<OtaStep> steps = const [],
    DateTime? startedAt,
  }) {
    final f = file(project);
    return OtaPushState(
      phase: phase,
      file: f,
      chunksDone: chunksDone,
      bytesDone: f.bytesBefore(chunksDone),
      boardVersionBefore: '0.1.0-dev',
      boardVersion: boardVersion,
      message: message,
      boardRestarted: boardRestarted,
      storedOnBoard: stored,
      steps: steps,
      startedAt: startedAt ?? DateTime(2026, 9, 29, 14),
      endedAt: phase == OtaPushPhase.sending ||
              phase == OtaPushPhase.verifying ||
              phase == OtaPushPhase.boardRestarting
          ? null
          : DateTime(2026, 9, 29, 14, 1),
    );
  }

  late ProviderContainer container;

  Future<void> pump(
    WidgetTester tester,
    Size size,
    Widget home,
    OtaPushState state, {
    List<TopologyNode>? nodes,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final port = _Port();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          serialProvider.overrideWith((ref) => port),
          activeAlarmProvider.overrideWithValue(false),
          topologyProvider.overrideWithValue(nodes ?? mesh),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          _push.overrideWith((ref) => state),
          otaPushViewProvider.overrideWith((ref) => ref.watch(_push)),
          // Behind the banner's tap: the update screen itself.
          boardDeviceProvider.overrideWith((ref) => Stream.value(null)),
          otaPushProvider
              .overrideWith((ref) => _Controller(ref, ref.read(_push))),
        ],
        child: MaterialApp(home: home),
      ),
    );
    container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> move(WidgetTester tester, OtaPushState state) async {
    container.read(_push.notifier).state = state;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  const banner = ValueKey('ota-rede-banner');
  const ring = ValueKey('ota-board-ring');
  const tablet = ValueKey('ota-tablet-chip');
  const pending = ValueKey('fw-pending');

  final screens = <String, Widget Function()>{
    'Rede': () => const TopologyScreen(),
    'Rede 3D': () => const Network3dScreen(),
  };

  for (final screen in screens.entries) {
    group(screen.key, () {
      for (final s in sizes.entries) {
        testWidgets('no push: the map as it is every other day — ${s.key}',
            (tester) async {
          await pump(tester, s.value, screen.value(), const OtaPushState());
          expect(find.byKey(banner), findsNothing);
          expect(find.byKey(ring), findsNothing);
          expect(find.byKey(tablet), findsNothing);
          expect(find.byKey(pending), findsNothing);
          expect(find.text('CENTRAL'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('a board image on its way — ${s.key}', (tester) async {
          await pump(tester, s.value, screen.value(),
              push(OtaPushPhase.sending, chunksDone: 43));
          expect(tester.takeException(), isNull);

          // The banner: what is going where and how far.
          expect(find.byKey(banner), findsOneWidget);
          final strip = find.byKey(banner);
          expect(
            find.descendant(
              of: strip,
              matching:
                  find.text('Atualização: placa ← firmware da placa 0.1.1'),
            ),
            findsOneWidget,
          );
          // How far: on its own, whole, on the narrowest screen too.
          final far = find.descendant(of: strip, matching: find.text('43 %'));
          expect(far, findsOneWidget);
          expect(
              tester.getRect(far).right, lessThan(tester.getRect(strip).right));
          expect(find.byTooltip('Fechar aviso'), findsNothing);

          // The board is receiving: a ring around it, the phase under it,
          // the tablet beside it.
          expect(find.byKey(ring), findsOneWidget);
          final indicator = tester.widget<CircularProgressIndicator>(
            find.descendant(
              of: find.byKey(ring),
              matching: find.byType(CircularProgressIndicator),
            ),
          );
          expect(indicator.value, closeTo(0.43, 1e-9));
          expect(find.text('Placa: recebendo 43 %'), findsOneWidget);
          expect(find.byKey(tablet), findsOneWidget);
          expect(find.text('TABLET'), findsOneWidget);

          // The banner sits inside the screen.
          final view = tester.view.physicalSize / tester.view.devicePixelRatio;
          final rect = tester.getRect(find.byKey(banner));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(view.width));
          // Three lines at most (the test font is wider than the real one).
          expect(rect.height, lessThan(76), reason: 'a strip, not a panel');
          expect(tester.takeException(), isNull);
        });

        testWidgets(
            'a node image on its way: only the board receives — '
            '${s.key}', (tester) async {
          await pump(
              tester,
              s.value,
              screen.value(),
              push(OtaPushPhase.sending,
                  project: 'sempreiot-node', chunksDone: 43));
          expect(
            find.text('Atualização: placa ← firmware de rede elétrica 0.1.1 '
                '(será guardado na placa)'),
            findsOneWidget,
          );
          expect(
            find.descendant(
                of: find.byKey(banner), matching: find.text('43 %')),
            findsOneWidget,
          );
          // One ring on the whole map, and it is the board's.
          expect(find.byKey(ring), findsOneWidget);
          expect(find.text('Placa: recebendo 43 %'), findsOneWidget);
          expect(find.textContaining('recebendo'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('the phases, one after the other', (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(),
            push(OtaPushPhase.switchingSpeed));
        expect(find.text('Placa: preparando'), findsOneWidget);

        await move(tester, push(OtaPushPhase.sending, chunksDone: 10));
        expect(find.text('Placa: recebendo 10 %'), findsOneWidget);
        await move(tester, push(OtaPushPhase.sending, chunksDone: 77));
        expect(find.text('Placa: recebendo 77 %'), findsOneWidget);
        expect(
          find.descendant(of: find.byKey(banner), matching: find.text('77 %')),
          findsOneWidget,
        );

        await move(tester, push(OtaPushPhase.verifying, chunksDone: 100));
        expect(find.text('Placa: verificando'), findsOneWidget);
        expect(
          tester
              .widget<CircularProgressIndicator>(find.descendant(
                of: find.byKey(ring),
                matching: find.byType(CircularProgressIndicator),
              ))
              .value,
          isNull,
          reason: 'no number to show: the ring turns',
        );

        await move(tester, push(OtaPushPhase.boardRestarting, chunksDone: 100));
        expect(find.text('Placa: reiniciando'), findsOneWidget);
        expect(
          find.descendant(
              of: find.byKey(banner), matching: find.text('reiniciando')),
          findsOneWidget,
        );

        await move(
          tester,
          push(OtaPushPhase.boardRestarting, chunksDone: 100, steps: const [
            OtaStep(OtaStepId.confirm, status: OtaStepStatus.running),
          ]),
        );
        expect(find.text('Placa: autoteste'), findsOneWidget);

        // It ended: the ring and the tablet leave, the banner says how.
        await move(
          tester,
          push(OtaPushPhase.confirmed,
              chunksDone: 100, boardVersion: '0.1.1', boardRestarted: true),
        );
        expect(find.byKey(ring), findsNothing);
        expect(find.byKey(tablet), findsNothing);
        expect(find.text('CENTRAL'), findsOneWidget);
        expect(
            find.text('Placa atualizada: 0.1.0-dev → 0.1.1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('chunks go by, ten a second: the map keeps drawing',
          (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(),
            push(OtaPushPhase.sending, chunksDone: 0));
        for (var i = 1; i <= 60; i++) {
          container.read(_push.notifier).state =
              push(OtaPushPhase.sending, chunksDone: i);
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Placa: recebendo 60 %'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the LED of the board is not the ring', (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(),
            const OtaPushState());
        final before = tester.widgetList(find.byType(DeviceLedDot)).length;
        await move(tester, push(OtaPushPhase.sending, chunksDone: 43));
        // Every LED lens is still there, the board's included; the ring is
        // another widget, in the app's accent colour.
        expect(tester.widgetList(find.byType(DeviceLedDot)).length, before);
        expect(
          find.descendant(
              of: find.byKey(ring), matching: find.byType(DeviceLedDot)),
          findsNothing,
        );
      });

      testWidgets('the outcome stays until it is closed', (tester) async {
        await pump(
          tester,
          const Size(800, 1280),
          screen.value(),
          push(OtaPushPhase.stored,
              project: 'sempreiot-node',
              chunksDone: 100,
              stored: const {SafrProductFamily.node: '0.1.1'}),
        );
        expect(
          find.text('Guardado na placa: firmware de rede elétrica 0.1.1 · '
              'nenhum dispositivo foi atualizado'),
          findsOneWidget,
        );
        // Nothing is on its way any more.
        expect(find.byKey(ring), findsNothing);
        expect(find.byKey(tablet), findsNothing);

        await tester.tap(find.byTooltip('Fechar aviso'));
        await tester.pump();
        expect(find.byKey(banner), findsNothing);

        // Another push: its banner shows.
        await move(
          tester,
          push(OtaPushPhase.sending,
              chunksDone: 5,
              stored: const {SafrProductFamily.node: '0.1.1'},
              startedAt: DateTime(2026, 9, 29, 15)),
        );
        expect(find.byKey(banner), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a failure, in one line', (tester) async {
        await pump(
          tester,
          const Size(360, 640),
          screen.value(),
          push(OtaPushPhase.failed,
              chunksDone: 40,
              message: 'A placa parou de responder durante o envio.'),
        );
        expect(
          find.text('Atualização não concluída: a placa parou de responder '
              'durante o envio. Nada mudou na placa.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('a tap on the banner opens the update screen',
          (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(),
            push(OtaPushPhase.sending, chunksDone: 43));
        await tester.tap(find.byKey(banner));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(FirmwareUpdateScreen), findsOneWidget);
        expect(find.text('Enviando para a placa'), findsOneWidget);
      });

      for (final s in sizes.entries) {
        testWidgets(
            'what every unit runs; what waits on the board — '
            '${s.key}', (tester) async {
          await pump(
            tester,
            s.value,
            screen.value(),
            push(OtaPushPhase.stored,
                project: 'sempreiot-node',
                chunksDone: 100,
                stored: const {SafrProductFamily.node: '0.1.1'}),
          );
          // Board, root, siren and leaf said what they run; one unit never
          // did and has no label.
          expect(
              find.text('v0.1.0-dev', skipOffstage: false), findsNWidgets(4));
          // The image waits for the three mains powered units — not for
          // the board, not for the leaf.
          expect(find.byKey(pending, skipOffstage: false), findsNWidgets(3));
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('with no mesh at all the board is still drawn receiving',
          (tester) async {
        await pump(
          tester,
          const Size(1280, 800),
          screen.value(),
          push(OtaPushPhase.sending, chunksDone: 43),
          nodes: [mesh.first],
        );
        expect(find.byKey(ring), findsOneWidget);
        expect(find.text('Placa: recebendo 43 %'), findsOneWidget);
        expect(find.text('Nenhum dispositivo na rede'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }

  group('device menu', () {
    Future<void> open(WidgetTester tester, String mac) async {
      await tester.tap(find.text(mac));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('Fechar'), findsOneWidget);
    }

    for (final s in sizes.entries) {
      testWidgets('an image waits on the board for this unit — ${s.key}',
          (tester) async {
        await pump(
          tester,
          s.value,
          const TopologyScreen(),
          push(OtaPushPhase.stored,
              project: 'sempreiot-node',
              chunksDone: 100,
              stored: const {SafrProductFamily.node: '0.1.1'}),
        );
        // The root: on the screen in every size without panning.
        await open(tester, _root);
        expect(find.text('Firmware', skipOffstage: false), findsOneWidget);
        expect(find.text('0.1.0-dev', skipOffstage: false), findsOneWidget);
        expect(find.text('Na placa', skipOffstage: false), findsOneWidget);
        expect(find.text('0.1.1 (ainda não enviado)', skipOffstage: false),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('nothing waits for a unit of another family', (tester) async {
      await pump(
        tester,
        const Size(1280, 800),
        const TopologyScreen(),
        push(OtaPushPhase.stored,
            project: 'sempreiot-node',
            chunksDone: 100,
            stored: const {SafrProductFamily.node: '0.1.1'}),
      );
      await open(tester, _leaf);
      expect(find.text('Na placa', skipOffstage: false), findsNothing);
    });

    testWidgets('nothing stored: no line', (tester) async {
      await pump(tester, const Size(1280, 800), const TopologyScreen(),
          const OtaPushState());
      await open(tester, _siren);
      expect(find.text('Na placa', skipOffstage: false), findsNothing);
    });
  });

  group('FirmwareTag', () {
    Future<void> show(WidgetTester tester, Widget child) => tester
        .pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));

    testWidgets('nothing at all when the unit never said what it runs',
        (tester) async {
      await show(tester, const FirmwareTag(version: null));
      expect(find.byType(Text), findsNothing);
      expect(find.byKey(pending), findsNothing);
      await show(tester, const FirmwareTag(version: ''));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('the version, and the marker when another waits',
        (tester) async {
      await show(tester, const FirmwareTag(version: '0.1.0-dev'));
      expect(find.text('v0.1.0-dev'), findsOneWidget);
      expect(find.byKey(pending), findsNothing);
      await show(
          tester, const FirmwareTag(version: '0.1.0-dev', pending: '0.1.1'));
      expect(find.text('v0.1.0-dev'), findsOneWidget);
      expect(find.byKey(pending), findsOneWidget);
      // The version that waits is never shown as the one that runs.
      expect(find.textContaining('0.1.1'), findsNothing);
    });
  });
}
