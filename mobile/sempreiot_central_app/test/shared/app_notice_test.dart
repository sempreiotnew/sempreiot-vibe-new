import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sempreiot_central_app/shared/widgets/app_notice.dart';

/// The app's notice (2026-11-19): the card that replaced the Material
/// snackbar. Every kind, both themes, a phone and a tablet in both
/// orientations: it shows, never overflows, and keeps a phone's width on
/// a wide screen. With NOTICE_PNG_DIR set, it is also written as PNGs.
void main() {
  const long = 'A placa não respondeu. Confira o cabo da placa, o pop da '
      'etiqueta e se a placa já foi configurada (LED magenta).';

  Future<void> pump(WidgetTester tester, Size size, Brightness b,
      AppNoticeKind kind, String message,
      {Key? boundary}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        theme: ThemeData(brightness: b, useMaterial3: true),
        home: Scaffold(
          backgroundColor: b == Brightness.dark
              ? const Color(0xFF0B0F1A)
              : const Color(0xFFFFFFFF),
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showAppNotice(context, message, kind: kind),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  for (final s in {
    'phone portrait': const Size(360, 640),
    'phone landscape': const Size(640, 360),
    'tablet portrait': const Size(800, 1280),
    'tablet landscape': const Size(1280, 800),
  }.entries) {
    for (final kind in AppNoticeKind.values) {
      testWidgets('${kind.name} — ${s.key}', (tester) async {
        await pump(tester, s.value, Brightness.dark, kind, long);
        expect(find.text(long), findsOneWidget);
        expect(find.byIcon(kind.icon), findsOneWidget);
        final card = tester.getRect(find
            .ancestor(of: find.text(long), matching: find.byType(DecoratedBox))
            .first);
        expect(card.width, lessThanOrEqualTo(460));
        expect(card.left, greaterThanOrEqualTo(16));
        expect(card.right, lessThanOrEqualTo(s.value.width - 16));
        expect(card.bottom, lessThanOrEqualTo(s.value.height));
        expect((card.center.dx - s.value.width / 2).abs(), lessThan(1));
        expect(tester.takeException(), isNull);
        // It leaves by itself.
        await tester.pump(const Duration(seconds: 7));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text(long), findsNothing);
      });
    }
  }

  testWidgets('a new notice takes the place of the one on screen',
      (tester) async {
    await pump(tester, const Size(360, 640), Brightness.light,
        AppNoticeKind.copied, 'Sub ID copiado.');
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Sub ID copiado.'), findsOneWidget);
  });

  final pngDir = Platform.environment['NOTICE_PNG_DIR'];
  for (final b in Brightness.values) {
    for (final (kind, text) in [
      (AppNoticeKind.success, 'Nome atualizado.'),
      (AppNoticeKind.copied, 'Sub ID copiado.'),
      (AppNoticeKind.warning, 'A central não confirmou o reinício.'),
      (AppNoticeKind.error, long),
    ]) {
      testWidgets('PNG: ${b.name} ${kind.name}', skip: pngDir == null,
          (tester) async {
        final root = Platform.environment['FLUTTER_ROOT'];
        if (root != null) {
          final f = File('$root/bin/cache/artifacts/material_fonts/'
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
        await pump(tester, const Size(520, 200), b, kind, text, boundary: key);
        await tester.runAsync(() async {
          final boundary =
              tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$pngDir/notice_${b.name}_${kind.name}.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
        });
      });
    }
  }
}
