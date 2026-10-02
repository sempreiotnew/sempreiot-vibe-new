import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/alarm_latch_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_board_events_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_state.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/data/services/firmware_library_store.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/device_update_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/network_3d_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/topology_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';

import 'fake_library.dart';

/// The Rede screens (map and 3D) while the board sends its image to the
/// units and after it: who is being updated and how far, who waits, who is
/// done, who failed. Protocol §13.4, §13.6.
class _Port extends SerialNotifier {
  _Port() : super.detached();

  @override
  Future<bool> portWrite(Uint8List bytes) async => true;

  @override
  Future<bool> portSetBaud(int baud) async => true;
}

class _Push extends OtaPushController {
  _Push(super.ref);
}

class _Rollout extends OtaRolloutController {
  _Rollout(super.ref, OtaRolloutState initial) {
    state = initial;
  }

  @override
  Future<void> refresh() async {}
}

class _Root extends RootElectionNotifier {
  _Root(super.db, String? root) {
    state =
        RootElectionState(rootMac: root, candidates: {if (root != null) root});
  }

  @override
  void update(List<TopologyNode> nodes, {required bool linkUp}) {}

  @override
  void tick() {}
}

/// The rollout the screens read; a test moves it.
final _shown = StateProvider<OtaRolloutState>((_) => const OtaRolloutState());

const _board = '7C:4F:AD:AE:85:90';
const _root = '5A:46:52:00:00:01';
const _siren = '5A:46:52:00:00:02';
const _button = '5A:46:52:00:00:03';
const _leaf = '5A:46:52:00:00:04';

const node = SafrProductFamily.node;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final now = DateTime.now().toUtc();
  TopologyNode unit(
    String mac,
    int layer,
    SafrNodeRole role,
    String? parent, {
    String? name,
    int? productCode,
    String? fw = '0.1.0',
    bool updating = false,
    bool heard = true,
  }) =>
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
        name: name,
        productCode: productCode,
        fwVersion: fw,
        updating: updating,
        heard: heard,
      );

  List<TopologyNode> mesh({String? updating, bool silent = false}) => [
        unit(_board, 0, SafrNodeRole.root, null, productCode: 0x0100),
        unit(_root, 1, SafrNodeRole.root, _board,
            name: 'Repetidor escada',
            productCode: 0x0204,
            updating: updating == _root,
            heard: !(updating == _root && silent)),
        unit(_siren, 2, SafrNodeRole.node, _root,
            name: 'Sirene hall',
            productCode: 0x0201,
            updating: updating == _siren,
            heard: !(updating == _siren && silent)),
        unit(_button, 2, SafrNodeRole.node, _root,
            name: 'Botoeira garagem',
            productCode: 0x0202,
            updating: updating == _button,
            heard: !(updating == _button && silent)),
        unit(_leaf, 3, SafrNodeRole.leaf, _siren,
            name: 'Detector sala', productCode: 0x0301),
      ];

  const sizes = <String, Size>{
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(360, 640),
    'phone landscape': Size(640, 360),
  };

  final t0 = DateTime(2026, 9, 29, 14);

  OtaRolloutUnit row(
    String mac,
    SafrOtaUnitState s, {
    int percent = 0,
    int reason = 0,
    String version = '0.1.0',
  }) =>
      OtaRolloutUnit(
        mac: mac,
        productCode: 0x0201,
        state: s,
        percent: percent,
        reasonRaw: reason,
        version: version,
        versionBefore: '0.1.0',
        changedAt: t0,
        activeSince: s.active ? DateTime.now() : null,
      );

  OtaRolloutState rollout(
    SafrOtaRolloutState state,
    List<OtaRolloutUnit> units, {
    OtaPauseCause? cause,
    DateTime? endedAt,
  }) =>
      OtaRolloutState(
        boardAnswered: true,
        families: {
          node: OtaFamilyRollout(
            family: node,
            state: state,
            target: '0.2.0',
            total: units.length,
            units: units,
            updatedAt: DateTime.now(),
            startedAt: t0,
            startedAtExact: true,
            endedAt: endedAt,
            pauseCause: cause,
          ),
        },
      );

  /// The siren is done, the push button downloads, the root waits.
  OtaRolloutState rolling({
    SafrOtaUnitState button = SafrOtaUnitState.downloading,
    int percent = 40,
  }) =>
      rollout(SafrOtaRolloutState.rolling, [
        row(_root, SafrOtaUnitState.waiting),
        row(_siren, SafrOtaUnitState.done, version: '0.2.0'),
        row(_button, button, percent: percent),
      ]);

  final staged = OtaRolloutState(
    boardAnswered: true,
    families: {
      node: OtaFamilyRollout(
        family: node,
        state: SafrOtaRolloutState.staged,
        target: '0.2.0',
        updatedAt: t0,
      ),
    },
  );

  late ProviderContainer container;

  Future<void> pump(
    WidgetTester tester,
    Size size,
    Widget home,
    OtaRolloutState state, {
    List<TopologyNode>? nodes,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final port = _Port();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          serialProvider.overrideWith((ref) => port),
          activeAlarmProvider.overrideWithValue(false),
          topologyProvider.overrideWithValue(nodes ?? mesh()),
          rootElectionProvider.overrideWith((ref) => _Root(db, _root)),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          _shown.overrideWith((ref) => state),
          otaRolloutViewProvider.overrideWith((ref) => ref.watch(_shown)),
          otaPushViewProvider.overrideWithValue(const OtaPushState()),
          // Behind the banner's tap: the update screen itself.
          boardDeviceProvider.overrideWith((ref) => Stream.value(null)),
          otaPushProvider.overrideWith((ref) => _Push(ref)),
          otaRolloutProvider
              .overrideWith((ref) => _Rollout(ref, ref.read(_shown))),
          firmwareLibraryStoreProvider.overrideWithValue(MemoryFirmwareStore()),
        ],
        child: MaterialApp(home: home),
      ),
    );
    container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> move(WidgetTester tester, OtaRolloutState state) async {
    container.read(_shown.notifier).state = state;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  const banner = ValueKey('ota-rollout-banner');
  const pushBanner = ValueKey('ota-rede-banner');
  const ring = ValueKey('ota-unit-ring');
  const boardRing = ValueKey('ota-board-ring');
  const tablet = ValueKey('ota-tablet-chip');
  const caption = ValueKey('ota-unit-caption');
  const waiting = ValueKey('ota-unit-waiting');
  const done = ValueKey('ota-unit-done');
  const failed = ValueKey('ota-unit-failed');
  const skipped = ValueKey('ota-unit-skipped');
  const pending = ValueKey('fw-pending');

  const line = ValueKey('device-update-rede-line');

  final screens = <String, Widget Function()>{
    'Rede': () => const TopologyScreen(),
    'Rede 3D': () => const Network3dScreen(),
  };

  // Rede is the alarm view: a rollout is drawn on "Atualizar dispositivos"
  // only. Here: one quiet line, the way there, and "Atualizando" for a unit
  // that restarts (supervision, not a drawing of the update).
  for (final screen in screens.entries) {
    group(screen.key, () {
      for (final s in sizes.entries) {
        testWidgets(
            'a unit downloads: nothing of it drawn, one line — '
            '${s.key}', (tester) async {
          await pump(tester, s.value, screen.value(), rolling());
          expect(find.byKey(line), findsOneWidget);
          expect(find.text('A placa está atualizando dispositivos'),
              findsOneWidget);
          for (final k in [ring, caption, waiting, done, failed, skipped]) {
            expect(find.byKey(k), findsNothing, reason: '$k');
          }
          expect(find.byKey(banner), findsNothing);
          expect(find.byKey(pushBanner), findsNothing);
          expect(find.byKey(boardRing), findsNothing);
          expect(find.byKey(tablet), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('it ended: the line goes away', (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(), rolling());
        expect(find.byKey(line), findsOneWidget);
        await move(
            tester,
            rollout(SafrOtaRolloutState.done, [
              row(_root, SafrOtaUnitState.done, version: '0.2.0'),
              row(_siren, SafrOtaUnitState.done, version: '0.2.0'),
              row(_button, SafrOtaUnitState.done, version: '0.2.0'),
            ]));
        expect(find.byKey(line), findsNothing);
        expect(find.byKey(done), findsNothing);
      });

      testWidgets('nothing sent yet: no marker on the units', (tester) async {
        await pump(tester, const Size(1280, 800), screen.value(), staged);
        expect(find.byKey(pending), findsNothing);
        expect(find.byKey(line), findsNothing);
      });

      testWidgets('the line opens "Atualizar dispositivos"', (tester) async {
        await pump(tester, const Size(800, 1280), screen.value(), rolling());
        await tester.tap(find.byKey(line));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(DeviceUpdateScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'a unit that restarts is "Atualizando" in its menu, never '
          '"Sem comunicação"', (tester) async {
        final nodes = mesh(updating: _root, silent: true);
        await pump(
          tester,
          const Size(800, 1280),
          screen.value(),
          rollout(SafrOtaRolloutState.rolling, [
            row(_root, SafrOtaUnitState.rebooting, percent: 100),
            row(_siren, SafrOtaUnitState.done, version: '0.2.0'),
            row(_button, SafrOtaUnitState.done, version: '0.2.0'),
          ]),
          nodes: nodes,
        );
        expect(deviceStateLabel(nodes.firstWhere((n) => n.mac == _root)),
            'Atualizando');

        await tester.tap(find.text('Repetidor escada'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('Fechar'), findsOneWidget);
        expect(find.text('Atualizando', skipOffstage: false), findsOneWidget);
        expect(find.textContaining('Sem comunicação', skipOffstage: false),
            findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
