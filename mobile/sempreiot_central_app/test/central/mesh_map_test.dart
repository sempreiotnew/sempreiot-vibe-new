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
import 'package:sempreiot_central_app/features/central/presentation/widgets/mesh_map.dart';

import '../ota/fake_firmware.dart';

/// The map Rede and "Atualizar dispositivos" share. `showOta` decides
/// whether a firmware push / rollout is drawn on it at all: Rede will stop
/// drawing it, the update screen draws it.
void main() {
  final now = DateTime.now().toUtc();
  const board = '7C:4F:AD:AE:85:90';
  const root = '5A:46:52:00:00:01';

  TopologyNode node(String mac, int layer, SafrNodeRole role, String? parent) =>
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

  Future<void> pump(WidgetTester tester, {required bool showOta}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topologyProvider.overrideWithValue([boardNode, ...mesh]),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          otaPushViewProvider.overrideWithValue(sending),
          otaRolloutOverlayProvider.overrideWithValue(OtaRolloutOverlay.none),
          otaHeldOnBoardProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MeshMap(
              nodes: mesh,
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
}
