import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_command_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/mesh_map.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/mesh_radial_legend.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/mesh_status_bar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_model_sprites.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/ota_rede_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_models.g.dart';

/// The radial Rede map (2026-10-15): the mesh as clusters of dots around
/// the hub, for a network too big to read as rows. The whole of it fits
/// the screen at the opening zoom, no two units overlap, names come with
/// the zoom, and the strip's switch takes Rede from the tree to it and
/// back. A fake mesh of ~200 units stands in for the network to come.
///
/// With RADIAL_PNG_DIR set, the view is also written as PNGs there, to
/// look at.
void main() {
  final now = DateTime.now().toUtc();
  const board = '00:00:00:00:00:B0';
  const root = '5A:46:52:00:00:01';

  TopologyNode node(
    String mac,
    int layer,
    SafrNodeRole role,
    String? parent, {
    bool online = true,
    bool alarm = false,
    int? battery,
    Duration silent = Duration.zero,
    String? name,
    int? product,
  }) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: parent,
        productCode: product,
        rssi: -60 - (mac.codeUnitAt(mac.length - 1) % 30),
        batteryPct: battery,
        online: online,
        lastSeenAt: now.subtract(silent),
        alarmLatched: alarm,
        name: name,
        fwVersion: '0.3.8',
      );

  /// central ─ root ─ [nodes2] sirens ─ [nodes3] each ─ [leaves] detectors
  /// each, with a few offline, one in alarm, some on a low battery.
  List<TopologyNode> fakeMesh(
      {required int nodes2, required int nodes3, required int leaves}) {
    var i = 2;
    String mac() {
      final n = i++;
      final hi = (n ~/ 256).toRadixString(16).padLeft(2, '0').toUpperCase();
      final lo = (n % 256).toRadixString(16).padLeft(2, '0').toUpperCase();
      return '5A:46:52:00:$hi:$lo';
    }

    final out = [
      node(board, 0, SafrNodeRole.root, null),
      node(root, 1, SafrNodeRole.root, board,
          name: 'Sirene Hall', product: 0x0201),
    ];
    for (var a = 0; a < nodes2; a++) {
      final siren = mac();
      out.add(node(siren, 2, SafrNodeRole.node, root,
          online: a != 3, name: 'Sirene ${a + 1}', product: 0x0201));
      for (var b = 0; b < nodes3; b++) {
        final sub = mac();
        out.add(node(sub, 3, SafrNodeRole.node, siren, product: 0x0202));
        for (var c = 0; c < leaves; c++) {
          final k = a * 100 + b * 10 + c;
          out.add(node(mac(), 4, SafrNodeRole.leaf, sub,
              online: k % 23 != 7,
              alarm: k == 5,
              battery: k % 17 == 3 ? 12 : 80,
              silent: const Duration(minutes: 2),
              product: 0x0301));
        }
      }
    }
    return out;
  }

  /// The models, loaded for real (a load started in the test's fake time
  /// never ends).
  Future<void> loadModels(WidgetTester tester) => tester.runAsync(
        () => Future.wait([
          for (final slug in ['siren', 'push_button', 'smoke_detector'])
            DeviceModelSprites.load(
                deviceModelSpecs.firstWhere((m) => m.slug == slug)),
        ]),
      );

  Future<void> pumpMap(WidgetTester tester, Size size, List<TopologyNode> mesh,
      {bool radial = true, Key? boundary}) async {
    await loadModels(tester);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final units = mesh.where((n) => n.layer > 0).toList();
    Widget map = MeshMap(
      nodes: units,
      board: mesh.first,
      election: const RootElectionState(rootMac: root),
      onNodeTap: (_, __) {},
      showOta: false,
      radial: radial,
    );
    if (boundary != null) map = RepaintBoundary(key: boundary, child: map);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topologyProvider.overrideWithValue(mesh),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          otaPushViewProvider.overrideWithValue(const OtaPushState()),
          // No port, no plugin: the map alone.
          serialProvider.overrideWith((ref) => SerialNotifier.detached()),
          deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
              traffic: ref.watch(safrTrafficProvider).stream)),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: Scaffold(body: map),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  const sizes = {
    'phone portrait': Size(390, 844),
    'phone landscape': Size(844, 390),
    'tablet landscape': Size(1280, 800),
  };

  final big = fakeMesh(nodes2: 8, nodes3: 2, leaves: 11); // 201 units
  final units = big.where((n) => n.layer > 0).toList();

  for (final s in sizes.entries) {
    testWidgets(
        '201 units: the whole picture on screen, nobody on top of anybody '
        '— ${s.key}', (tester) async {
      await pumpMap(tester, s.value, big);
      final rects = <String, Rect>{};
      for (final n in units) {
        final f = find.byKey(radialChipKey(n.mac));
        expect(f, findsOneWidget, reason: '${n.mac} is on the map');
        rects[n.mac] = tester.getRect(f);
      }
      final view = s.value;
      for (final e in rects.entries) {
        expect(e.value.center.dx, inInclusiveRange(0, view.width),
            reason: '${e.key} x on screen');
        expect(e.value.center.dy, inInclusiveRange(0, view.height),
            reason: '${e.key} y on screen');
      }
      final all = rects.entries.toList();
      for (var i = 0; i < all.length; i++) {
        for (var j = i + 1; j < all.length; j++) {
          expect(all[i].value.overlaps(all[j].value), isFalse,
              reason: '${all[i].key} and ${all[j].key} overlap');
        }
      }
      // The hub: the root in the middle, the central right above it.
      final hub = tester.getCenter(find.byKey(radialChipKey(root)));
      final central = tester.getCenter(find.text('CENTRAL'));
      expect((central.dx - hub.dx).abs(), lessThan(2));
      expect(central.dy, lessThan(hub.dy));
      expect(find.byKey(MeshRadialLegend.legendKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'names come with the zoom: halos and lines first, the names '
      'once there is room', (tester) async {
    await pumpMap(tester, const Size(1280, 800), big);
    expect(find.text('Sirene Hall'), findsNothing,
        reason: '201 units: no room');
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip('Aproximar'));
      await tester.pump();
    }
    expect(find.text('Sirene Hall'), findsOneWidget);
    expect(find.byType(FirmwareTag), findsWidgets,
        reason: 'the firmware too, as the tree\'s pill');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a phone, 201 units: halos alone at the opening zoom, the models '
      'once they can be read', (tester) async {
    await pumpMap(tester, const Size(390, 844), big);
    expect(find.byType(DeviceModelAvatar), findsNothing,
        reason: 'too small to read: the glow\'s core instead');
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip('Aproximar'));
      await tester.pump();
    }
    expect(find.byType(DeviceModelAvatar), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legend counts the units by state, with their share',
      (tester) async {
    await pumpMap(tester, const Size(1280, 800), big);
    expect(find.text('201 DISPOSITIVOS'), findsOneWidget);
    expect(find.textContaining('alarme'), findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.textContaining('dormindo'), findsOneWidget);
    expect(find.textContaining('ativo'), findsOneWidget);
    expect(find.textContaining(' %'), findsWidgets);
  });

  testWidgets('a small mesh: the clusters round the hub, every unit apart',
      (tester) async {
    final small = fakeMesh(nodes2: 4, nodes3: 1, leaves: 8); // 41 units
    await pumpMap(tester, const Size(1280, 800), small);
    final macs = [
      for (final n in small)
        if (n.layer > 0) n.mac
    ];
    final rects = {
      for (final m in macs) m: tester.getRect(find.byKey(radialChipKey(m)))
    };
    for (var i = 0; i < macs.length; i++) {
      for (var j = i + 1; j < macs.length; j++) {
        expect(rects[macs[i]]!.overlaps(rects[macs[j]]!), isFalse,
            reason: '${macs[i]} and ${macs[j]} overlap');
      }
    }
    // Room for the names one step in (the opening zoom fits the whole
    // picture, a little under 1:1).
    await tester.tap(find.byTooltip('Aproximar'));
    await tester.pump();
    expect(find.text('Sirene 1'), findsOneWidget);
    expect(find.text('Sirene 2'), findsOneWidget);
    expect(find.text('Sirene 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Rede: the strip\'s switch goes from the tree to the radial '
      'picture and back', (tester) async {
    final small = fakeMesh(nodes2: 3, nodes3: 1, leaves: 4);
    await loadModels(tester);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topologyProvider.overrideWithValue(small),
          boardLinkUpProvider.overrideWithValue(true),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          otaPushViewProvider.overrideWithValue(const OtaPushState()),
          serialProvider.overrideWith((ref) => SerialNotifier.detached()),
          deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
              traffic: ref.watch(safrTrafficProvider).stream)),
        ],
        child: const MaterialApp(home: TopologyScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(radialChipKey(root)), findsNothing);
    expect(find.text('Sirene Hall'), findsOneWidget, reason: 'the tree chip');

    await tester.tap(find.byKey(MeshStatusBar.layoutKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // the slide
    expect(find.byKey(radialChipKey(root)), findsOneWidget);
    expect(find.byKey(MeshRadialLegend.legendKey), findsOneWidget);
    expect(find.text('ATIVOS'), findsOneWidget, reason: 'the strip stays');

    await tester.tap(find.byKey(MeshStatusBar.layoutKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(radialChipKey(root)), findsNothing);
    expect(find.text('Sirene Hall'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final radial in [false, true]) {
    testWidgets(
        'the ticks of a command leave the map with its status — '
        '${radial ? 'radial' : 'tree'} (2026-10-15)', (tester) async {
      final small = fakeMesh(nodes2: 2, nodes3: 1, leaves: 2);
      final siren = small.firstWhere((n) => n.name == 'Sirene 1').mac;
      late DeviceCommandTracker tracker;
      await loadModels(tester);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            topologyProvider.overrideWithValue(small),
            safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
            otaPushViewProvider.overrideWithValue(const OtaPushState()),
            serialProvider.overrideWith((ref) => SerialNotifier.detached()),
            deviceCommandProvider.overrideWith((ref) => tracker =
                DeviceCommandTracker(
                    askCentral: (_) async => null,
                    traffic: ref.watch(safrTrafficProvider).stream)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: MeshMap(
                nodes: small.where((n) => n.layer > 0).toList(),
                board: small.first,
                election: const RootElectionState(rootMac: root),
                onNodeTap: (_, __) {},
                showOta: false,
                radial: radial,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      tracker.applyRemote(DeviceCommandStatus(
          mac: siren,
          kind: DeviceCommandKind.identify,
          step: DeviceCommandStep.delivered,
          startedAt: DateTime.now()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(CommandTicks.keyTwo), findsWidgets);
      // The status leaves after its moment: the ticks with it, with no
      // other change on the map.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.byKey(CommandTicks.keyTwo), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  // ── A look at it ──────────────────────────────────────────────────────
  final pngDir = Platform.environment['RADIAL_PNG_DIR'];
  for (final (label, mesh, size) in [
    ('radial_201_tablet', big, const Size(1280, 800)),
    (
      'radial_41_tablet',
      fakeMesh(nodes2: 4, nodes3: 1, leaves: 8),
      const Size(1280, 800)
    ),
    ('radial_201_phone', big, const Size(390, 844)),
    (
      'tree_41_tablet',
      fakeMesh(nodes2: 4, nodes3: 1, leaves: 8),
      const Size(1280, 800)
    ),
  ]) {
    testWidgets('PNG: $label', skip: pngDir == null, (tester) async {
      // A real font, so the picture reads (tests draw text as boxes).
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot != null) {
        final f = File('$flutterRoot/bin/cache/artifacts/material_fonts/'
            'Roboto-Regular.ttf');
        if (f.existsSync()) {
          await tester.runAsync(() async {
            final bytes = await f.readAsBytes();
            await (FontLoader('Roboto')
                  ..addFont(Future.value(ByteData.view(bytes.buffer))))
                .load();
          });
        }
      }
      const key = ValueKey('png');
      await pumpMap(tester, size, mesh,
          radial: !label.startsWith('tree'), boundary: key);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() async {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
        final image = await boundary.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$pngDir/$label.png').writeAsBytesSync(data!.buffer.asUint8List());
      });
    });
  }
}
