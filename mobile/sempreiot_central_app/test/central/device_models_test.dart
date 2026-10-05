import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/device_led_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_3d_chip.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_model_painter.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_model_sprites.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_models.g.dart';

/// The generated model registry (tool/blender/factory.sh) against the
/// product catalogue, the assets on disk and pubspec.yaml; the model in
/// place of the circle on Dispositivos (spinning) and Dispositivo (still,
/// drag to turn); the siren's alarm; the LED always shown.
void main() {
  group('device model registry', () {
    test('every model maps catalogue products of one family', () {
      expect(deviceModelSpecs, isNotEmpty);
      for (final spec in deviceModelSpecs) {
        for (final code in spec.productCodes) {
          final p = SafrProduct.fromCode(code)!;
          expect(p.isKnown, isTrue, reason: '${spec.slug}: ${p.codeHex}');
          if (spec.familyFallback != null) {
            expect(p.family, spec.familyFallback,
                reason: '${spec.slug}: ${p.codeHex} is not a '
                    '${spec.familyFallback!.name}');
          }
        }
      }
    });

    test('no product and no family fallback is claimed twice', () {
      final codes = <int>{};
      final fallbacks = <SafrProductFamily>{};
      for (final spec in deviceModelSpecs) {
        for (final c in spec.productCodes) {
          expect(codes.add(c), isTrue, reason: safrProductCodeHex(c));
        }
        final f = spec.familyFallback;
        if (f != null) expect(fallbacks.add(f), isTrue, reason: f.name);
      }
    });

    test('assets exist, are bundled, and their frames are complete', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final spec in deviceModelSpecs) {
        expect(spec.glow == null, spec.spinGlow == null, reason: spec.slug);
        for (final path in [
          spec.atlas,
          spec.spin,
          if (spec.glow != null) spec.glow!,
          if (spec.spinGlow != null) spec.spinGlow!,
          spec.frames,
        ]) {
          expect(File(path).existsSync(), isTrue, reason: path);
          expect(pubspec.contains('- $path'), isTrue,
              reason: '$path not in pubspec.yaml');
        }
        final frames =
            DeviceModelFrames.parse(File(spec.frames).readAsStringSync());
        expect(frames.frameCount, greaterThan(0), reason: spec.slug);
        expect(frames.spinYaws.length, greaterThan(frames.yaws.length),
            reason: '${spec.slug}: the spin turns in finer steps');
        expect(frames.bodyFraction, inExclusiveRange(0, 1.0001));
        expect(frames.markers.containsKey('led'), isTrue,
            reason: '${spec.slug}: no LED marker');
        for (final m in frames.markers.entries) {
          expect(m.value.length, frames.frameCount,
              reason: '${spec.slug}.${m.key}');
        }
        for (final m in frames.spinMarkers.entries) {
          expect(m.value.length, frames.spinYaws.length,
              reason: '${spec.slug}.spin.${m.key}');
        }
      }
    });

    test('the siren lights up and rings in alarm, the detector does not',
        () {
      final siren = deviceModelSpecs.firstWhere((s) => s.slug == 'siren');
      final detector =
          deviceModelSpecs.firstWhere((s) => s.slug == 'smoke_detector');
      expect(siren.glow, isNotNull);
      expect(siren.alarmSound, isTrue);
      expect(detector.glow, isNull);
      expect(detector.alarmSound, isFalse);
    });
  });

  group('deviceModelFor', () {
    String? slug(int? code, {bool isLeaf = false}) =>
        deviceModelFor(code, isLeaf: isLeaf)?.slug;

    test('a product with its own model gets it', () {
      expect(slug(0x0201), 'siren');
      expect(slug(0x0202), 'push_button'); // manual call point
      expect(slug(0x0301, isLeaf: true), 'smoke_detector');
    });

    test('a leaf without a model of its own gets the leaf fallback', () {
      expect(slug(0x0302, isLeaf: true), 'smoke_detector'); // heat detector
      expect(slug(null, isLeaf: true), 'smoke_detector'); // not reported
      expect(slug(0x0000, isLeaf: true), 'smoke_detector');
    });

    test('mains units and the board without a model are spheres', () {
      expect(slug(0x0203), isNull); // I/O module
      expect(slug(null), isNull);
      expect(slug(0x0100), isNull);
    });

    test('the code decides the family, not the flag', () {
      expect(slug(0x0302), 'smoke_detector');
      expect(slug(0x0203, isLeaf: true), isNull);
    });
  });

  group('DeviceModelFrames', () {
    const json = '{"size":10,"yaws":[0,90,180,270],"pitches":[0,45],'
        '"bodyFraction":0.8,"markers":{"led":[[0.5,0.5,1],[0.6,0.5,1],'
        '[0.5,0.5,0],[0.4,0.5,1],[0.5,0.4,1],[0.6,0.4,1],[0.5,0.4,0],'
        '[0.4,0.4,1]]},"spin":{"pitch":15,"yaws":[0,120,240],"cols":2,'
        '"markers":{"led":[[0.2,0.5,1],[0.6,0.5,1],[0.4,0.5,0]]}}}';

    test('parses markers and picks the nearest atlas frame', () {
      final f = DeviceModelFrames.parse(json);
      expect(f.frameCount, 8);
      expect(f.markers['led']![2].visible, isFalse);
      expect(f.frameFor(0, 0), 0);
      expect(f.frameFor(3.14159 / 2, 0), 1);
      expect(f.frameFor(-3.14159 / 2, 0.7), 4 + 3);
      expect(f.source(5), const Rect.fromLTWH(10, 10, 10, 10));
    });

    test('the spin blends the two frames around the angle', () {
      final f = DeviceModelFrames.parse(json);
      final s = f.spinBetween(60 * 3.141592653589793 / 180);
      expect(s.a, 0);
      expect(s.b, 1);
      expect(s.t, closeTo(0.5, 1e-9));
      expect(f.spinBetween(-0.0001).a, 2); // just before a full turn
      expect(f.spinSource(2), const Rect.fromLTWH(0, 10, 10, 10));
    });
  });

  group('DeviceModelAvatar (Dispositivos, Dispositivo)', () {
    TopologyNode unit(int? product,
            {bool leaf = false, bool alarm = false}) =>
        TopologyNode(
          mac: '5A:46:52:00:00:01',
          role: leaf ? SafrNodeRole.leaf : SafrNodeRole.node,
          layer: 2,
          parentMac: '00:00:00:00:00:B0',
          rssi: -60,
          batteryPct: leaf ? 90 : null,
          online: true,
          lastSeenAt: DateTime.now().toUtc(),
          alarmLatched: alarm,
          productCode: product,
        );

    Future<void> show(WidgetTester tester, TopologyNode node,
        {bool spin = false,
        bool interactive = false,
        bool reduceMotion = false}) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          deviceLedProvider.overrideWith((ref) => DeviceLedEngine(
              traffic: const Stream.empty(), nodes: () => [node])),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: Center(
                child: DeviceModelAvatar(
                    node: node,
                    size: 72,
                    spin: spin,
                    interactive: interactive),
              ),
            ),
          ),
        ),
      ));
    }

    DeviceModelSpec spec(String slug) =>
        deviceModelSpecs.firstWhere((s) => s.slug == slug);

    // The sprites decode for real (runAsync); the widget hears about them
    // on the real event loop, so let it turn once before pumping.
    Future<void> settleModel(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }

    DeviceModelPainter painter(WidgetTester tester) => tester
        .widget<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is DeviceModelPainter))
        .painter as DeviceModelPainter;

    testWidgets('a product without a model is the circle', (tester) async {
      await show(tester, unit(0x0203)); // I/O module
      await tester.pump();
      expect(find.byType(DeviceAvatar), findsOneWidget);
    });

    testWidgets('a siren is drawn as its model, with its LED',
        (tester) async {
      await tester.runAsync(() => DeviceModelSprites.load(spec('siren')));
      await show(tester, unit(0x0201));
      await settleModel(tester);
      expect(find.byType(DeviceAvatar), findsNothing);
      expect(find.byType(DeviceLedDot), findsOneWidget);
      expect(painter(tester).alarm, isNull);
    });

    testWidgets('a leaf with no product reported is the detector model',
        (tester) async {
      await tester
          .runAsync(() => DeviceModelSprites.load(spec('smoke_detector')));
      await show(tester, unit(null, leaf: true));
      await settleModel(tester);
      expect(find.byType(DeviceAvatar), findsNothing);
      expect(find.byType(DeviceLedDot), findsOneWidget);
    });

    testWidgets('on Dispositivos it spins, and the LED goes round with it',
        (tester) async {
      await tester.runAsync(() => DeviceModelSprites.load(spec('siren')));
      await show(tester, unit(0x0201), spin: true);
      await settleModel(tester);
      final first = painter(tester).pose;
      final ledAt = tester.getTopLeft(find.byType(DeviceLedDot));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(painter(tester).pose, isNot(first));
      expect(tester.getTopLeft(find.byType(DeviceLedDot)), isNot(ledAt));
      expect(find.byType(DeviceLedDot), findsOneWidget);
    });

    testWidgets('reduced motion: no spin', (tester) async {
      await tester.runAsync(() => DeviceModelSprites.load(spec('siren')));
      await show(tester, unit(0x0201), spin: true, reduceMotion: true);
      await settleModel(tester);
      final first = painter(tester).pose;
      await tester.pump(const Duration(milliseconds: 1500));
      expect(painter(tester).pose, first);
    });

    testWidgets('on Dispositivo it stands still; a drag turns it back and '
        'forth, a double tap puts it back', (tester) async {
      await tester.runAsync(() => DeviceModelSprites.load(spec('siren')));
      await show(tester, unit(0x0201), interactive: true);
      await settleModel(tester);
      final rest = painter(tester).pose;
      await tester.pump(const Duration(milliseconds: 1500));
      expect(painter(tester).pose, rest, reason: 'no spin on Dispositivo');
      await tester.drag(find.byType(DeviceModelAvatar), const Offset(-80, 0));
      await tester.pump();
      expect(painter(tester).pose, isNot(rest));
      await tester.tap(find.byType(DeviceModelAvatar));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(DeviceModelAvatar));
      await tester.pump(const Duration(milliseconds: 400));
      expect(painter(tester).pose, rest);
    });

    testWidgets('a siren in ALARME lights up and rings; its LED stays',
        (tester) async {
      await tester.runAsync(() => DeviceModelSprites.load(spec('siren')));
      await show(tester, unit(0x0201, alarm: true), interactive: true);
      await settleModel(tester);
      final p = painter(tester);
      expect(p.alarm, isNotNull);
      expect(p.sound, isTrue);
      expect(p.pose.glow, isNotNull);
      await tester.pump(const Duration(milliseconds: 300));
      expect(painter(tester).alarm, isNot(p.alarm), reason: 'animated');
      expect(find.byType(DeviceLedDot), findsOneWidget);
      expect(find.text('ALARME'), findsOneWidget);
    });
  });

  group('offline (2026-10-05)', () {
    TopologyNode unit(int? product, {required bool online}) => TopologyNode(
          mac: '5A:46:52:00:00:09',
          role: SafrNodeRole.node,
          layer: 2,
          parentMac: '00:00:00:00:00:B0',
          rssi: -60,
          batteryPct: null,
          online: online,
          lastSeenAt: DateTime.now().toUtc(),
          alarmLatched: false,
          productCode: product,
        );

    Future<void> show(WidgetTester tester, TopologyNode node, Widget w) =>
        tester.pumpWidget(ProviderScope(
          overrides: [
            deviceLedProvider.overrideWith((ref) => DeviceLedEngine(
                traffic: const Stream.empty(), nodes: () => [node])),
          ],
          child: MaterialApp(home: Scaffold(body: Center(child: w))),
        ));

    Finder modelPaint() => find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is DeviceModelPainter);

    testWidgets(
        'an offline model is faded as one picture — it no longer flickers '
        'while it turns', (tester) async {
      final siren = deviceModelSpecs.firstWhere((s) => s.slug == 'siren');
      await tester.runAsync(() => DeviceModelSprites.load(siren));
      final off = unit(0x0201, online: false);
      await show(tester, off, DeviceModelAvatar(node: off, size: 72, spin: true));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 700));
      // One layer for the whole model: both frames of the turn are drawn
      // solid inside it, and the layer fades them together.
      expect(modelPaint(), paintsExactlyCountTimes(#saveLayer, 1));
      expect(modelPaint(), paints..drawImageRect());

      final on = unit(0x0201, online: true);
      await show(tester, on, DeviceModelAvatar(node: on, size: 72, spin: true));
      await tester.pump(const Duration(milliseconds: 700));
      expect(modelPaint(), paintsExactlyCountTimes(#saveLayer, 0));
    });

    testWidgets('Rede 3D: OFFLINE over a unit without communication, no ring',
        (tester) async {
      final off = unit(0x0203, online: false); // I/O: no model, the sphere
      await show(tester, off,
          Device3dChip(node: off, light: Alignment.topLeft));
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.byType(DeviceLedDot), findsOneWidget);

      final on = unit(0x0203, online: true);
      await show(tester, on, Device3dChip(node: on, light: Alignment.topLeft));
      expect(find.text('OFFLINE'), findsNothing);
    });
  });
}
