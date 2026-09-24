import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/shared/widgets/encrypted_share_dialog.dart';

/// Regression for the first bench bug (2026-09-24): the share QR inside an
/// AlertDialog threw "LayoutBuilder does not support returning intrinsic
/// dimensions" on every frame. The dialog must lay out cleanly on a phone in
/// portrait and on a tablet in landscape.
void main() {
  const envelope =
      '{"v":2,"kdf":"pbkdf2-sha256","iter":200000,"salt":"AAAAAAAAAAAAAAAAAAAAAA==",'
      '"nonce":"AAAAAAAAAAAAAAAA","ct":"'
      'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo'
      'wMTIzNDU2Nzg5QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5QUJDREVGR0hJSktMTU5PUA=="}';

  Future<void> pumpDialog(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showEncryptedShareDialog(
                context,
                title: 'Compartilhar "Galpão 2"',
                envelope: envelope,
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('lays out without exceptions on a phone in portrait', (tester) async {
    await pumpDialog(tester, const Size(360, 780));
    expect(tester.takeException(), isNull);
    expect(find.text('Copiar como texto'), findsOneWidget);
    expect(find.text('Fechar'), findsOneWidget);
  });

  testWidgets('lays out without exceptions on a tablet in landscape', (tester) async {
    await pumpDialog(tester, const Size(1024, 600));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Fechar'));
    await tester.pumpAndSettle();
    expect(find.text('Copiar como texto'), findsNothing);
  });
}
