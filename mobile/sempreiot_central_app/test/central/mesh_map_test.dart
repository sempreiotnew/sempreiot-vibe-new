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
      {required bool showOta,
      List<TopologyNode>? units,
      bool withBoard = true}) async {
    final nodes = units ?? mesh;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topologyProvider
              .overrideWithValue([if (withBoard) boardNode, ...nodes]),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          otaPushViewProvider.overrideWithValue(sending),
          otaRolloutOverlayProvider.overrideWithValue(OtaRolloutOverlay.none),
          otaHeldOnBoardProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MeshMap(
              nodes: nodes,
              board: withBoard ? boardNode : null,
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

  group('a weak link (protocol §9.4, 2026-10-26)', () {
    testWidgets('the legend counts it and says where the new node goes',
        (tester) async {
      final far = TopologyNode(
        mac: '5A:46:52:00:00:02',
        role: SafrNodeRole.node,
        layer: 2,
        parentMac: root,
        rssi: -91,
        batteryPct: null,
        online: true,
        lastSeenAt: now,
        alarmLatched: false,
      );
      await pump(tester, showOta: false, units: [...mesh, far]);
      expect(find.text('1 enlace fraco · falta um nó no caminho'),
          findsOneWidget);
    });

    testWidgets('a good link has no such row', (tester) async {
      await pump(tester, showOta: false);
      expect(find.textContaining('enlace fraco'), findsNothing);
    });
  });
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

  group('a brand-new central (2026-10-26)', () {
    testWidgets('the board heard and no unit yet: the CENTRAL chip alone',
        (tester) async {
      await pump(tester, showOta: false, units: const []);
      expect(find.text('CENTRAL'), findsOneWidget);
      expect(find.text('Nenhum dispositivo na rede'), findsNothing);
    });

    testWidgets('nothing heard at all: the empty message, no chip',
        (tester) async {
      await pump(tester, showOta: false, units: const [], withBoard: false);
      expect(find.text('CENTRAL'), findsNothing);
      expect(find.text('Nenhum dispositivo na rede'), findsOneWidget);
    });
  });

  group('a dead unit is never a hop (2026-10-14)', () {
    const a = '5A:46:52:00:00:0A', b = '5A:46:52:00:00:0B';
    const c = '5A:46:52:00:00:0C';
    // central ─ root ─ a (dead) ─ b (alive, still says a) ─ c (alive)
    final byMac = {
      for (final n in [
        node(root, 1, SafrNodeRole.root, board),
        node(a, 2, SafrNodeRole.node, root, online: false),
        node(b, 3, SafrNodeRole.node, a),
        node(c, 4, SafrNodeRole.node, b),
      ])
        n.mac: n
    };

    test(
        'a live unit under a dead parent hangs off the nearest live '
        'ancestor, as a presumed link', () {
      final t = meshLinkTargetOf(byMac[b]!, byMac, board);
      expect(t, isNotNull);
      expect(t!.key, root);
      expect(t.presumed, isTrue);
    });

    test('a live unit under a live parent keeps its real link', () {
      final t = meshLinkTargetOf(byMac[c]!, byMac, board)!;
      expect(t.key, b);
      expect(t.presumed, isFalse);
    });

    test('the dead unit keeps its last known parent (a ghost line)', () {
      final t = meshLinkTargetOf(byMac[a]!, byMac, board)!;
      expect(t.key, root);
      expect(t.presumed, isFalse);
    });

    test('nothing live above it: the central, presumed', () {
      final lone = {
        root: node(root, 1, SafrNodeRole.root, board, online: false),
        b: node(b, 2, SafrNodeRole.node, root),
      };
      final t = meshLinkTargetOf(lone[b]!, lone, board)!;
      expect(t.key, '@central');
      expect(t.presumed, isTrue);
    });

    test('the root hangs off the central; an unknown parent is no link', () {
      expect(meshLinkTargetOf(byMac[root]!, byMac, board)!.key, '@central');
      final stray = node('5A:46:52:00:00:0F', 3, SafrNodeRole.node, 'ZZ:00');
      expect(meshLinkTargetOf(stray, byMac, board), isNull);
    });
  });

  group(
      'a tidy tree: every unit under its parent, no link crosses '
      '(2026-10-15)', () {
    // central ─ root ─ a ─ {a1, a2} and root ─ b ─ {b1}, given scrambled:
    // the order the units were heard must not decide where they sit.
    const a = '5A:46:52:00:00:0A', b = '5A:46:52:00:00:0B';
    const a1 = '5A:46:52:00:00:A1', a2 = '5A:46:52:00:00:A2';
    const b1 = '5A:46:52:00:00:B1';
    final units = [
      node(b1, 3, SafrNodeRole.node, b),
      node(a, 2, SafrNodeRole.node, root),
      node(a2, 3, SafrNodeRole.node, a),
      node(b, 2, SafrNodeRole.node, root),
      node(root, 1, SafrNodeRole.root, board),
      node(a1, 3, SafrNodeRole.node, a),
    ];

    testWidgets('children side by side under their parent', (tester) async {
      await pump(tester, showOta: false, units: units);
      double x(String mac) => tester.getCenter(find.text(mac)).dx;
      double y(String mac) => tester.getCenter(find.text(mac)).dy;
      // The rows: a layer per row.
      expect(y(root), lessThan(y(a)));
      expect(y(a), closeTo(y(b), 0.5));
      expect(y(a), lessThan(y(a1)));
      // a's children under a, b's under b, the two families apart — a
      // line from a1 or a2 up to a never meets b1's line up to b.
      expect(x(a), closeTo((x(a1) + x(a2)) / 2, 1));
      expect(x(b), closeTo(x(b1), 1));
      expect(x(a1), lessThan(x(a2)));
      expect(x(a2), lessThan(x(b1)));
      expect(x(a), lessThan(x(b)));
      // The root over the whole tree, the central over the root.
      expect(x(root), closeTo((x(a1) + x(b1)) / 2, 1));
      expect(tester.getCenter(find.text('CENTRAL')).dx, closeTo(x(root), 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a unit that changes parent slides over to it', (tester) async {
      await pump(tester, showOta: false, units: units);
      double x(String mac) => tester.getCenter(find.text(mac)).dx;
      final before = x(a1);
      final moved = [
        for (final n in units)
          n.mac == a1 ? node(a1, 3, SafrNodeRole.node, b) : n,
      ];
      await pump(tester, showOta: false, units: moved);
      await tester.pump(const Duration(milliseconds: 200));
      final midway = x(a1);
      expect(midway, greaterThan(before + 5), reason: 'on its way right');
      expect(midway, lessThan(x(b1) - 5), reason: 'not there yet');
      await tester.pump(const Duration(milliseconds: 400));
      // Under b now, beside b1 (its MAC sorts first); a keeps a2 alone.
      expect(x(b), closeTo((x(a1) + x(b1)) / 2, 1));
      expect(x(a1), greaterThan(x(a2)));
      expect(x(a), closeTo(x(a2), 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a live unit under a dead parent sits under the unit its '
        'line goes to', (tester) async {
      // a dies: a1 and a2 (still saying a) hang off the root, as their
      // dashed lines do; a keeps its ghost line and its own column.
      final dead = [
        for (final n in units)
          n.mac == a ? node(a, 2, SafrNodeRole.node, root, online: false) : n,
      ];
      await pump(tester, showOta: false, units: dead);
      double x(String mac) => tester.getCenter(find.text(mac)).dx;
      // Root's children now, in layer-then-MAC order: a (dead, alone in
      // its column), b (with b1), then a1 and a2 — each in its own span.
      expect(x(a), lessThan(x(b)));
      expect(x(b), closeTo(x(b1), 1));
      expect(x(b1), lessThan(x(a1)));
      expect(x(a1), lessThan(x(a2)));
      expect(tester.takeException(), isNull);
    });
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
