import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/device_settings_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';

/// SAFR v3.5: "Produto" and "Firmware" on the Dispositivo screen and in the
/// device menu of the Rede map, in both orientations.
void main() {
  const board = '00:00:00:00:00:B0';
  const siren = '5A:46:52:00:00:01';
  const old = '5A:46:52:00:00:02';
  const newer = '5A:46:52:00:00:03';
  final now = DateTime.now().toUtc();

  TopologyNode node(
    String mac,
    int layer,
    String? parent, {
    int? productCode,
    int? hwRev,
    String? fwVersion,
  }) =>
      TopologyNode(
        mac: mac,
        role: layer <= 1 ? SafrNodeRole.root : SafrNodeRole.node,
        layer: layer,
        parentMac: parent,
        rssi: -60,
        batteryPct: null,
        online: true,
        lastSeenAt: now,
        alarmLatched: false,
        productCode: productCode,
        hwRev: hwRev,
        fwVersion: fwVersion,
      );

  final mesh = <TopologyNode>[
    node(board, 0, null, productCode: 0x0100, fwVersion: '0.1.0-dev'),
    node(siren, 1, board,
        productCode: 0x0201, hwRev: 2, fwVersion: '0.1.0-dev'),
    node(old, 2, siren), // firmware older than v3.5
    node(newer, 2, siren, productCode: 0x0206, fwVersion: '0.9.0'),
  ];

  const sizes = <String, Size>{
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(360, 640),
    'phone landscape': Size(640, 360),
  };

  // One in-memory database per test, never the tablet's file.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> pump(WidgetTester tester, Size size, Widget home) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          topologyProvider.overrideWithValue(mesh),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          // No firmware push: the map as it is every other day.
          otaPushViewProvider.overrideWithValue(const OtaPushState()),
        ],
        child: MaterialApp(home: home),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> reveal(WidgetTester tester, Finder f) =>
      tester.scrollUntilVisible(f, 80,
          scrollable: find.byType(Scrollable).first);

  group('Dispositivo screen', () {
    for (final s in sizes.entries) {
      testWidgets('product, hardware revision and firmware — ${s.key}',
          (tester) async {
        await pump(tester, s.value, const DeviceSettingsScreen(mac: siren));
        await reveal(tester, find.text('Firmware'));
        expect(find.text('Produto'), findsOneWidget);
        expect(find.text('Sirene · SIOT-SIREN-01'), findsOneWidget);
        expect(find.text('Revisão de hardware'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(find.text('Firmware'), findsOneWidget);
        expect(find.text('0.1.0-dev'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('firmware older than v3.5: both facts read "—"',
        (tester) async {
      await pump(
          tester, const Size(800, 1280), const DeviceSettingsScreen(mac: old));
      await reveal(tester, find.text('Firmware'));
      final card = find.ancestor(
          of: find.text('Produto'), matching: find.byType(Column));
      expect(
          find.descendant(of: card.first, matching: find.text('—')),
          findsOneWidget);
      final fw = find.ancestor(
          of: find.text('Firmware'), matching: find.byType(Column));
      expect(find.descendant(of: fw.first, matching: find.text('—')),
          findsOneWidget);
      expect(find.text('Revisão de hardware'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a product this app does not know is still shown',
        (tester) async {
      await pump(tester, const Size(360, 640),
          const DeviceSettingsScreen(mac: newer));
      await reveal(tester, find.text('Firmware'));
      expect(find.text('Produto desconhecido 0x0206 · rede elétrica'),
          findsOneWidget);
      expect(find.text('0.9.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('device menu on the Rede map', () {
    for (final s in sizes.entries) {
      testWidgets('shows Produto and Firmware — ${s.key}', (tester) async {
        await pump(tester, s.value, const TopologyScreen());
        await tester.tap(find.text(siren));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('Fechar'), findsOneWidget);
        expect(find.text('Produto', skipOffstage: false), findsOneWidget);
        expect(find.text('Sirene · SIOT-SIREN-01', skipOffstage: false),
            findsOneWidget);
        expect(find.text('Firmware', skipOffstage: false), findsOneWidget);
        expect(find.text('0.1.0-dev', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('firmware older than v3.5: "—" for both', (tester) async {
      await pump(tester, const Size(1280, 800), const TopologyScreen());
      await tester.tap(find.text(old));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Produto'), findsOneWidget);
      expect(find.text('Firmware'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
