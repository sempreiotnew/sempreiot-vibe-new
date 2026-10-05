import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_report.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_image.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/mesh_map.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_model_painter.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_model_sprites.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_models.g.dart';

import '../ota/fake_firmware.dart';

/// The map Rede and "Atualizar dispositivos" share. `showOta` decides
/// whether a firmware push / rollout is drawn on it at all: Rede will stop
/// drawing it, the update screen draws it.
void main() {
  final now = DateTime.now().toUtc();
  const board = '7C:4F:AD:AE:85:90';
  const root = '5A:46:52:00:00:01';

  TopologyNode node(String mac, int layer, SafrNodeRole role, String? parent,
          {int? product, bool online = true}) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: parent,
        rssi: layer == 0 ? null : -60,
        batteryPct: null,
        online: online,
        lastSeenAt: now,
        alarmLatched: false,
        productCode: product,
      );

  final boardNode = node(board, 0, SafrNodeRole.root, null);
  final mesh = [node(root, 1, SafrNodeRole.root, board)];

  // A board image on its way over the cable.
  final bytes =
      fakeFirmware(project: 'sempreiot-board', version: '0.1.1', size: 40960);
  final file = FirmwareFile(
    name: 'board.bin',
    bytes: bytes,
    header: FirmwareImageHeader.parse(bytes),
    sha256: Uint8List(32),
  );
  final sending = OtaPushState(
    phase: OtaPushPhase.sending,
    file: file,
    chunksDone: 4,
    bytesDone: file.bytesBefore(4),
    startedAt: DateTime(2026, 10, 2, 14),
  );

  Future<void> pump(WidgetTester tester,
      {required bool showOta, List<TopologyNode>? units}) async {
    final nodes = units ?? mesh;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topologyProvider.overrideWithValue([boardNode, ...nodes]),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          otaPushViewProvider.overrideWithValue(sending),
          otaRolloutOverlayProvider.overrideWithValue(OtaRolloutOverlay.none),
          otaHeldOnBoardProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MeshMap(
              nodes: nodes,
              board: boardNode,
              election: const RootElectionState(rootMac: root),
              onNodeTap: (_, __) {},
              showOta: showOta,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  const ring = ValueKey('ota-board-ring');
  const tablet = ValueKey('ota-tablet-chip');

  testWidgets('showOta: a running push is drawn (ring, tablet beside it)',
      (tester) async {
    await pump(tester, showOta: true);
    expect(find.byKey(ring), findsOneWidget);
    expect(find.byKey(tablet), findsOneWidget);
    expect(find.text('CENTRAL'), findsNothing,
        reason: 'the caption says what the board does instead');
  });

  testWidgets('no showOta: the same push leaves the map as every other day',
      (tester) async {
    await pump(tester, showOta: false);
    expect(find.byKey(ring), findsNothing);
    expect(find.byKey(tablet), findsNothing);
    expect(find.text('CENTRAL'), findsOneWidget);
    expect(find.text(root), findsOneWidget);
  });

  testWidgets(
      'every unit is drawn as its 3D model; one without communication says '
      'OFFLINE (2026-10-05)', (tester) async {
    final siren = deviceModelSpecs.firstWhere((m) => m.slug == 'siren');
    await tester.runAsync(() => DeviceModelSprites.load(siren));
    const sirenMac = '5A:46:52:00:00:02';
    const deadMac = '5A:46:52:00:00:03';
    await pump(tester, showOta: false, units: [
      node(root, 1, SafrNodeRole.root, board, product: 0x0201),
      node(sirenMac, 2, SafrNodeRole.node, root, product: 0x0201),
      node(deadMac, 2, SafrNodeRole.node, root, product: 0x0201, online: false),
    ]);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.byType(DeviceModelAvatar), findsNWidgets(3));
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is DeviceModelPainter),
        findsNWidgets(3),
        reason: 'the models, not the circles');
    expect(find.byType(DeviceLedDot), findsNWidgets(4),
        reason: 'each unit keeps its LED, and the board has its own');
    expect(find.text('OFFLINE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
