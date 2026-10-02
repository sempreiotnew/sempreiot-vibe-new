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
import 'package:sempreiot_central_app/features/central/data/services/firmware_library_store.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_image.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/device_update_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/network_3d_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/ota_rede_widgets.dart';

import 'fake_firmware.dart';
import 'fake_library.dart';

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
          firmwareLibraryStoreProvider.overrideWithValue(MemoryFirmwareStore()),
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

  const line = ValueKey('device-update-rede-line');

  final screens = <String, Widget Function()>{
    'Rede': () => const TopologyScreen(),
    'Rede 3D': () => const Network3dScreen(),
  };

  // Rede is the alarm view: a firmware push is drawn on "Atualizar
  // dispositivos" only. Here: one quiet line, and the way there.
  for (final screen in screens.entries) {
    group(screen.key, () {
      for (final s in sizes.entries) {
        testWidgets('no push: no line, the map as every other day — ${s.key}',
            (tester) async {
          await pump(tester, s.value, screen.value(), const OtaPushState());
          expect(find.byKey(line), findsNothing);
          expect(find.byKey(ring), findsNothing);
          expect(find.byKey(tablet), findsNothing);
          expect(tester.takeException(), isNull);
        });

        testWidgets('a push runs: nothing of it drawn, one line — ${s.key}',
            (tester) async {
          await pump(tester, s.value, screen.value(),
              push(OtaPushPhase.sending, chunksDone: 40));
          expect(find.byKey(line), findsOneWidget);
          expect(find.text('Enviando firmware à placa'), findsOneWidget);
          expect(find.byKey(banner), findsNothing);
          expect(find.byKey(ring), findsNothing);
          expect(find.byKey(tablet), findsNothing);
          expect(find.text('CENTRAL'), findsOneWidget,
              reason: 'the CENTRAL keeps its caption');
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('it ended: the line goes away', (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(),
            push(OtaPushPhase.sending, chunksDone: 40));
        expect(find.byKey(line), findsOneWidget);
        await move(
            tester,
            push(OtaPushPhase.confirmed,
                chunksDone: 100, boardVersion: '0.1.1'));
        expect(find.byKey(line), findsNothing);
      });

      testWidgets('the line opens "Atualizar dispositivos"', (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(),
            push(OtaPushPhase.sending, chunksDone: 40));
        await tester.tap(find.byKey(line));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(DeviceUpdateScreen), findsOneWidget);
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
      testWidgets(
          'what the unit runs; never what waits on the board — '
          '${s.key}', (tester) async {
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
        expect(find.text('Na placa', skipOffstage: false), findsNothing);
        expect(find.byKey(pending), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
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
