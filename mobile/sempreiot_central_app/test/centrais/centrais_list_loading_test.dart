import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/access/application/user_access_provider.dart';
import 'package:sempreiot_central_app/features/access/domain/entities/saved_central.dart';
import 'package:sempreiot_central_app/features/centrais/presentation/screens/centrais_list_screen.dart';

/// Centrais (USER mode): while the list is being read it says so — never
/// "Nenhuma central adicionada" before it is known.
void main() {
  Future<void> pump(WidgetTester tester, Size size,
      {required bool loading, List<SavedCentral> centrals = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        savedCentralsProvider
            .overrideWith((ref) => SavedCentralsNotifier(ref)..state = centrals),
        savedCentralsLoadingProvider.overrideWith((ref) => loading),
      ],
      child: const MaterialApp(home: CentralsListScreen()),
    ));
    await tester.pump();
  }

  for (final size in const [Size(390, 844), Size(844, 390)]) {
    testWidgets('loading with no card yet: a spinner — $size', (tester) async {
      await pump(tester, size, loading: true);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('centrais-loading')), findsOneWidget);
      expect(find.text('Carregando suas centrais…'), findsOneWidget);
      expect(find.text('Nenhuma central adicionada'), findsNothing);
      expect(find.text('Nenhuma central'), findsNothing);
    });

    testWidgets('loaded and empty: the empty state — $size', (tester) async {
      await pump(tester, size, loading: false);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('centrais-loading')), findsNothing);
      expect(find.text('Nenhuma central adicionada'), findsOneWidget);
    });
  }

  testWidgets('loading with cards from this device: the cards and a thin bar',
      (tester) async {
    await pump(
      tester,
      const Size(390, 844),
      loading: true,
      centrals: [
        SavedCentral(
          subId: 'central-003',
          identityId: 'us-east-1:c',
          name: 'Bloco A',
          status: 'PENDING',
          addedAt: DateTime(2026, 10, 3),
        ),
      ],
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('centrais-loading-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('centrais-loading')), findsNothing);
    expect(find.text('Bloco A'), findsOneWidget);
  });
}
