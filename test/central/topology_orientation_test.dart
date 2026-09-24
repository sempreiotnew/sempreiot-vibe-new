import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';

/// The Rede map must work in BOTH orientations (app CLAUDE.md, "Both
/// orientations, ALWAYS") with the SAME picture: a vertical tree that is
/// zoomed out to fit when the screen is short, chips never overlapping,
/// nothing overflowing, and no floating button colliding with another.
void main() {
  final now = DateTime.now().toUtc();
  TopologyNode node(String mac, int layer, SafrNodeRole role, String? parent) =>
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
        name: null,
      );

  final mesh = <TopologyNode>[
    node('00:00:00:00:00:B0', 0, SafrNodeRole.root, null), // board
    node('5A:46:52:00:00:01', 1, SafrNodeRole.root, '00:00:00:00:00:B0'),
    node('5A:46:52:00:00:02', 2, SafrNodeRole.node, '5A:46:52:00:00:01'),
    for (var i = 3; i <= 8; i++)
      node('5A:46:52:00:00:0$i', 3, SafrNodeRole.leaf, '5A:46:52:00:00:02'),
  ];

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topologyProvider.overrideWithValue(mesh),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
        ],
        child: const MaterialApp(home: TopologyScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Centre of each node chip (the tappable GestureDetector), keyed by MAC.
  Map<String, Offset> chipCentres(WidgetTester tester) {
    final out = <String, Offset>{};
    for (final n in mesh.where((n) => n.layer > 0)) {
      final finder = find.text(n.mac);
      expect(finder, findsOneWidget, reason: '${n.mac} is on the map');
      out[n.mac] = tester.getCenter(finder);
    }
    return out;
  }

  /// Rendered on-screen rectangle of a node chip (its tappable area),
  /// after the fit zoom — so overlap is judged at the size the user sees.
  Rect chipRect(WidgetTester tester, String mac) => tester.getRect(
        find
            .ancestor(
                of: find.text(mac),
                matching: find.byWidgetPredicate(
                    (w) => w.runtimeType.toString() == '_ArenaFreeTap'))
            .first,
      );

  void expectNoOverlap(WidgetTester tester, Map<String, Offset> centres) {
    final rects = {for (final mac in centres.keys) mac: chipRect(tester, mac)};
    final entries = rects.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      for (var j = i + 1; j < entries.length; j++) {
        expect(
            entries[i].value.deflate(1).overlaps(entries[j].value.deflate(1)),
            isFalse,
            reason: '${entries[i].key} and ${entries[j].key} overlap');
      }
    }
  }

  /// Every chip is inside the viewport: the opening view is zoomed out to
  /// fit the whole tree instead of cropping it.
  void expectAllVisible(WidgetTester tester, Map<String, Offset> centres) {
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final e in centres.entries) {
      expect(e.value.dx, inInclusiveRange(0, view.width),
          reason: '${e.key} x inside the screen');
      expect(e.value.dy, inInclusiveRange(0, view.height),
          reason: '${e.key} y inside the screen');
    }
  }

  /// The strip above the map is a single compact line (it once doubled to
  /// two, stealing a third of a landscape screen).
  void expectSingleLineStrip(WidgetTester tester) {
    final strip = tester.getRect(find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_MeshStatusBar'));
    expect(strip.height, lessThan(60), reason: 'status strip is one line');
  }

  /// The tree is centred across the screen and its chips stay readable
  /// (never below 70 % of their 1:1 size).
  void expectCentredAndReadable(WidgetTester tester) {
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    final central = tester.getCenter(find.text('CENTRAL'));
    expect((central.dx - view.width / 2).abs(), lessThan(3),
        reason: 'CENTRAL sits on the horizontal centre line');
    final chip = chipRect(tester, '5A:46:52:00:00:01');
    expect(chip.width, greaterThanOrEqualTo(104 * 0.7 - 1),
        reason: 'chips are not shrunk past the readable floor');
  }

  /// The lane-label gutter is pinned to the left edge of the screen.
  void expectLabelsOnLeftEdge(WidgetTester tester) {
    final gutter = find.byWidgetPredicate((w) =>
        w.runtimeType.toString() == '_LaneLabelsPainter'
            ? true
            : w is CustomPaint &&
                w.painter.runtimeType.toString() == '_LaneLabelsPainter');
    final rect = tester.getRect(gutter.first);
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.left, 0, reason: 'gutter overlay starts at the screen edge');
    expect(rect.width, view.width, reason: 'overlay is in screen space');
  }

  void expectVerticalTree(WidgetTester tester, Map<String, Offset> chips) {
    final central = tester.getCenter(find.text('CENTRAL'));
    final root = chips['5A:46:52:00:00:01']!;
    final relay = chips['5A:46:52:00:00:02']!;
    final leaf = chips['5A:46:52:00:00:05']!;
    expect(root.dy, greaterThan(central.dy), reason: 'root below central');
    expect(relay.dy, greaterThan(root.dy), reason: 'relay below root');
    expect(leaf.dy, greaterThan(relay.dy), reason: 'leaves below relay');
    final leafYs = {
      for (var i = 3; i <= 8; i++) chips['5A:46:52:00:00:0$i']!.dy.round()
    };
    expect(leafYs.length, 1, reason: 'all leaves share one row');
  }

  testWidgets('portrait tablet: vertical tree, nothing overflows',
      (tester) async {
    await pump(tester, const Size(800, 1280));
    expect(tester.takeException(), isNull);
    final chips = chipCentres(tester);
    expectVerticalTree(tester, chips);
    expectSingleLineStrip(tester);
    expectCentredAndReadable(tester);
    expectLabelsOnLeftEdge(tester);
    expectAllVisible(tester, chips);
    expectNoOverlap(tester, chips);
  });

  testWidgets('landscape tablet: SAME vertical tree, zoomed out to fit',
      (tester) async {
    await pump(tester, const Size(1280, 800));
    expect(tester.takeException(), isNull);
    final chips = chipCentres(tester);
    expectVerticalTree(tester, chips);
    expectSingleLineStrip(tester);
    expectCentredAndReadable(tester);
    expectLabelsOnLeftEdge(tester);
    expectAllVisible(tester, chips);
    expectNoOverlap(tester, chips);
  });

  testWidgets('short landscape (small tablet / phone): fits, no overflow',
      (tester) async {
    // ~ a 1280×800 tablet at DPR 2 once app bar, bottom nav and status
    // strip took their share — the case that used to pile rows up.
    await pump(tester, const Size(640, 300));
    expect(tester.takeException(), isNull);
    final chips = chipCentres(tester);
    expectVerticalTree(tester, chips);
    expectSingleLineStrip(tester);
    expectCentredAndReadable(tester);
    expectLabelsOnLeftEdge(tester);
    // Too short for the whole tree at a readable size: it opens at the top,
    // central and root on screen, the rest reached by panning.
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getCenter(find.text('CENTRAL')).dy,
        inInclusiveRange(0, view.height));
    expect(chips['5A:46:52:00:00:01']!.dy, inInclusiveRange(0, view.height));
    expectNoOverlap(tester, chips);
  });

  testWidgets('portrait phone: centred even when wider than the screen',
      (tester) async {
    await pump(tester, const Size(400, 700));
    expect(tester.takeException(), isNull);
    final chips = chipCentres(tester);
    expectVerticalTree(tester, chips);
    expectSingleLineStrip(tester);
    expectCentredAndReadable(tester);
    expectLabelsOnLeftEdge(tester);
    expectNoOverlap(tester, chips);
  });

  testWidgets('zooming in/out keeps the labels pinned and the map coherent',
      (tester) async {
    await pump(tester, const Size(640, 282));
    final before = tester.getCenter(find.text('CENTRAL'));
    await tester.tap(find.byTooltip('Aproximar'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expectLabelsOnLeftEdge(tester);
    // Zoom is about the viewport centre: the tree's own centre line stays.
    expect((tester.getCenter(find.text('CENTRAL')).dx - before.dx).abs(),
        lessThan(1));
    await tester.tap(find.byTooltip('Afastar'));
    await tester.tap(find.byTooltip('Afastar'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Ajustar à tela'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
        (tester.getCenter(find.text('CENTRAL')) - before).distance, lessThan(1),
        reason: '"Ajustar à tela" returns to the opening view');
  });

  Future<void> pinchOut(WidgetTester tester, Offset at, Offset drift,
      {int steps = 12}) async {
    final g1 =
        await tester.createGesture(pointer: 1, kind: PointerDeviceKind.touch);
    final g2 =
        await tester.createGesture(pointer: 2, kind: PointerDeviceKind.touch);
    await g1.down(at + const Offset(-40, 0));
    await g2.down(at + const Offset(40, 0));
    await tester.pump();
    for (var i = 1; i <= steps; i++) {
      await g1.moveBy(const Offset(-4, 0) + drift);
      await g2.moveBy(const Offset(4, 0) + drift);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await g2.up();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Pinch = the same zoom the buttons do (pivot on the tree's centre line
  /// and the fingers' row), plus a pan equal to the hand's travel. Wherever
  /// the fingers are, the tree's centre line moves by the drift and by
  /// nothing else. Run at a 1:1 fit AND at the landscape tablet's 0.7 fit —
  /// the zoomed-out case is where the scale used to be misread as 1.0.
  for (final size in const [Size(1280, 800), Size(640, 282)]) {
    testWidgets(
        'pinch on a chip with drifting fingers: no sideways drift $size',
        (tester) async {
      await pump(tester, size);
      final root = find.text('5A:46:52:00:00:01');
      final centralBefore = tester.getCenter(find.text('CENTRAL'));
      final scaleBefore = chipRect(tester, '5A:46:52:00:00:01').width / 104;
      const drift = Offset(6, -3);
      await pinchOut(tester, tester.getCenter(root), drift);
      expect(tester.takeException(), isNull);
      final central = tester.getCenter(find.text('CENTRAL'));
      expect(
          (central.dx - (centralBefore.dx + drift.dx * 12)).abs(), lessThan(4),
          reason: 'centre line followed the hand only');
      expect(chipRect(tester, '5A:46:52:00:00:01').width / 104,
          greaterThan(scaleBefore * 1.4),
          reason: 'and the pinch actually zoomed in');
    });

    testWidgets('pinch far off-centre, no drift: tree stays centred $size',
        (tester) async {
      await pump(tester, size);
      final centralBefore = tester.getCenter(find.text('CENTRAL'));
      final scaleBefore = chipRect(tester, '5A:46:52:00:00:01').width / 104;
      await pinchOut(
          tester, Offset(size.width - 120, centralBefore.dy + 80), Offset.zero);
      expect(tester.takeException(), isNull);
      final central = tester.getCenter(find.text('CENTRAL'));
      expect((central.dx - centralBefore.dx).abs(), lessThan(4),
          reason: 'no sideways drift even when pinching at the right edge');
      expect(chipRect(tester, '5A:46:52:00:00:01').width / 104,
          greaterThan(scaleBefore * 1.4));
    });
  }

  testWidgets('one-finger drag pans by exactly the finger travel',
      (tester) async {
    await pump(tester, const Size(1280, 800));
    final before = tester.getCenter(find.text('CENTRAL'));
    final g =
        await tester.createGesture(pointer: 9, kind: PointerDeviceKind.touch);
    await g.down(before + const Offset(200, 60)); // empty canvas
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-5, 7));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    final moved = tester.getCenter(find.text('CENTRAL')) - before;
    expect((moved - const Offset(-50, 70)).distance, lessThan(3));
  });

  testWidgets('a still tap on a chip opens its sheet; a drag does not',
      (tester) async {
    await pump(tester, const Size(1280, 800));
    final root = find.text('5A:46:52:00:00:01');
    // Drag starting on the chip: pans the map, no sheet.
    final g =
        await tester.createGesture(pointer: 7, kind: PointerDeviceKind.touch);
    await g.down(tester.getCenter(root));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, -8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('COMANDOS — CENTRAL → DISPOSITIVO'), findsNothing);
    // Still tap: sheet opens.
    await tester.tap(root);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('COMANDOS — CENTRAL → DISPOSITIVO'), findsOneWidget);
  });

  testWidgets('clear button sits in the status strip, apart from zoom',
      (tester) async {
    await pump(tester, const Size(640, 300));
    final clear = tester.getRect(find.byTooltip('Ressincronizar com a placa'));
    for (final tip in ['Aproximar', 'Afastar', 'Ajustar à tela']) {
      final zoom = tester.getRect(find.byTooltip(tip));
      expect(clear.overlaps(zoom), isFalse, reason: 'clear vs $tip');
    }
    final strip = tester.getRect(find.text('ATIVOS'));
    expect((clear.center.dy - strip.center.dy).abs(), lessThan(40),
        reason: 'clear button is on the status strip row');
  });

  testWidgets('rotating keeps the tree vertical and fully visible',
      (tester) async {
    await pump(tester, const Size(800, 1280));
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    final chips = chipCentres(tester);
    expectVerticalTree(tester, chips);
    expectSingleLineStrip(tester);
    expectCentredAndReadable(tester);
    expectLabelsOnLeftEdge(tester);
    expectAllVisible(tester, chips);
    expectNoOverlap(tester, chips);
  });
}
