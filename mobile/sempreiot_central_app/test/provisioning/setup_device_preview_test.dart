import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/led/led_language.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_model_painter.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_models.g.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/network_3d/device_model_sprites.dart';
import 'package:sempreiot_central_app/features/provisioning/presentation/widgets/setup_device_preview.dart';

/// The unit being set up is drawn as its product's model (the same sprites
/// as Rede / Dispositivos) with the LED the real unit shows; the central as
/// the tablet; a product without a model is its type's placeholder, LED
/// included.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> show(WidgetTester tester, Widget w) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: w))));

  Finder modelPaint() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is DeviceModelPainter);

  LedLens lens(WidgetTester tester) =>
      tester.widget<LedLens>(find.byKey(setupLedLensKey));

  testWidgets('a siren is drawn as the siren model, blinking white',
      (tester) async {
    final spec = deviceModelSpecs.firstWhere((s) => s.slug == 'siren');
    DeviceModelSprites.resetCache();
    await tester.runAsync(() => DeviceModelSprites.load(spec));
    await show(
        tester,
        SetupDevicePreview(
          product: SafrProduct.fromCode(0x0201),
          family: SafrProductFamily.node,
          pattern: LedSetupPattern.whiteBlink,
        ));
    expect(modelPaint(), findsOneWidget);
    expect(find.text('Sirene'), findsOneWidget);
    expect(find.text('SIOT-SIREN-01'), findsOneWidget);
    expect(find.text('DISPOSITIVO AC'), findsOneWidget);
    expect(lens(tester).color, LedColor.white, reason: 'phase starts on');
    await tester.pump(const Duration(milliseconds: 600));
    expect(lens(tester).color, isNull, reason: '500 ms on, then off');
    await tester.pump(const Duration(milliseconds: 500));
    expect(lens(tester).color, LedColor.white);
  });

  testWidgets('the central is drawn as the tablet, the LED on it',
      (tester) async {
    DeviceModelSprites.resetCache();
    await tester.runAsync(() => DeviceModelSprites.load(deviceCentralModel!));
    await show(
        tester,
        SetupDevicePreview(
          product: SafrProduct.fromCode(0x0100),
          family: SafrProductFamily.board,
          pattern: LedSetupPattern.whiteBlink,
        ));
    expect(modelPaint(), findsOneWidget);
    expect(find.byIcon(Icons.developer_board_rounded), findsNothing);
    expect(find.text('CENTRAL'), findsOneWidget);
    expect(lens(tester).color, LedColor.white);
  });

  testWidgets('stays centred when the parent stretches (the result step)',
      (tester) async {
    final spec = deviceModelSpecs.firstWhere((s) => s.slug == 'siren');
    DeviceModelSprites.resetCache();
    await tester.runAsync(() => DeviceModelSprites.load(spec));
    const box = Key('stretched');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: box,
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SetupDevicePreview(
                  product: SafrProduct.fromCode(0x0201),
                  family: SafrProductFamily.node,
                  pattern: LedSetupPattern.whiteBreathe,
                  size: 112,
                  labels: false,
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    final centre = tester.getCenter(find.byKey(box)).dx;
    final paint = tester.getRect(modelPaint());
    expect(paint.width, 112, reason: 'the picture keeps its own box');
    expect(paint.center.dx, closeTo(centre, 0.5));
    final led = tester.getRect(find.byKey(setupLedLensKey));
    expect(led.left, greaterThanOrEqualTo(paint.left));
    expect(led.right, lessThanOrEqualTo(paint.right));
  });

  testWidgets('a sticker with only the type: the type\'s picture and name',
      (tester) async {
    await show(
        tester,
        const SetupDevicePreview(
          product: null,
          family: SafrProductFamily.leaf,
          pattern: LedSetupPattern.whiteBreathe,
        ));
    // The leaf family has a fallback model (the smoke detector).
    expect(SetupDevicePreview.modelCode(null, SafrProductFamily.leaf), 0x0300);
    expect(find.text('Dispositivo Bateria'), findsOneWidget);
    expect(find.text('DISPOSITIVO BATERIA'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(lens(tester).color, LedColor.white);
    expect(lens(tester).intensity, closeTo(ledBreatheMaxDuty, 0.02));
  });

  testWidgets('no pattern: the LED is dark and nothing animates',
      (tester) async {
    await show(
        tester,
        SetupDevicePreview(
          product: SafrProduct.fromCode(0x0202),
          family: SafrProductFamily.node,
          pattern: null,
          labels: false,
        ));
    expect(lens(tester).color, isNull);
    expect(find.text('Acionador manual'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(lens(tester).color, isNull);
  });
}
