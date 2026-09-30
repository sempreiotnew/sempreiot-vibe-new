import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_state.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';
import 'package:sempreiot_central_app/features/central/application/supervision_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';

/// Supervision and the one exception to it (protocol §13.4 `DEADLINE_S`): a
/// unit that is being updated is UPDATING, not missing, for up to 300 s
/// since its row of the rollout entered offered / downloading / verifying /
/// rebooting / self-test. After that the normal rule applies again.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const siren = '5A:46:52:00:00:02';
  const other = '5A:46:52:00:00:03';
  final t0 = DateTime.utc(2026, 9, 29, 14);

  late AppDatabase db;
  late DateTime now;
  late Map<String, DateTime> updating;
  SupervisionNotifier? notifier;

  Future<void> device(String mac, {required Duration silentFor}) =>
      db.into(db.meshDevices).insertOnConflictUpdate(MeshDevicesCompanion.insert(
            mac: mac,
            role: Value(SafrNodeRole.node.wire),
            layer: const Value(2),
            firstSeenAt: t0.subtract(const Duration(days: 1)),
            lastSeenAt: t0.subtract(silentFor),
            lastBootCtr: const Value(1),
            lastMsgCtr: const Value(1),
          ));

  SupervisionNotifier supervise({Duration grace = otaUpdatingGrace}) =>
      notifier = SupervisionNotifier(
        db,
        updatingSince: (mac) => updating[mac],
        updatingGrace: grace,
        clock: () => now,
      );

  Future<List<Map<String, dynamic>>> troubles() async {
    final rows = await db.select(db.deviceEvents).get();
    return [
      for (final r in rows)
        {
          'mac': r.deviceMac,
          'kind': (jsonDecode(r.detailJson) as Map)['kind'],
          'severity': r.severity,
        },
    ];
  }

  DeviceSupervision of(String mac) =>
      notifier!.state.firstWhere((s) => s.device.mac == mac);

  Future<int> supervisionState(String mac) async =>
      (await (db.select(db.meshDevices)..where((t) => t.mac.equals(mac)))
              .getSingle())
          .supervisionState;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    now = t0;
    updating = {};
  });

  tearDown(() async {
    notifier?.dispose();
    notifier = null;
    await db.close();
  });

  test('the rule: silent for longer than 45 s is missing, with a trouble',
      () async {
    await device(siren, silentFor: const Duration(seconds: 60));
    await supervise().evaluate();

    expect(of(siren).online, isFalse);
    expect(of(siren).heard, isFalse);
    expect(of(siren).updating, isFalse);
    expect(await troubles(), [
      {'mac': siren, 'kind': 'device_missing', 'severity': 1},
    ]);
    expect(await supervisionState(siren), 1);
  });

  test('a unit that is being updated and silent is not missing: no trouble',
      () async {
    await device(siren, silentFor: const Duration(seconds: 60));
    await device(other, silentFor: const Duration(seconds: 60));
    // Its row entered an active state 100 s ago; it restarted 60 s ago.
    updating[siren] = t0.subtract(const Duration(seconds: 100));
    await supervise().evaluate();

    expect(of(siren).online, isTrue);
    expect(of(siren).updating, isTrue);
    expect(of(siren).heard, isFalse, reason: 'it IS silent');
    expect(await supervisionState(siren), 0);
    // The exception is for that unit alone.
    expect(of(other).online, isFalse);
    expect(await troubles(), [
      {'mac': other, 'kind': 'device_missing', 'severity': 1},
    ]);
  });

  test('up to 300 s, not a second more', () async {
    await device(siren, silentFor: const Duration(seconds: 20));
    updating[siren] = t0;
    final s = supervise();

    now = t0.add(const Duration(seconds: 299));
    await s.evaluate();
    expect(of(siren).online, isTrue);
    expect(of(siren).updating, isTrue);
    expect(await troubles(), isEmpty);

    now = t0.add(const Duration(seconds: 300));
    await s.evaluate();
    expect(of(siren).online, isFalse);
    expect(of(siren).updating, isFalse);
    expect(await troubles(), [
      {'mac': siren, 'kind': 'device_missing', 'severity': 1},
    ]);
    expect(await supervisionState(siren), 1);
  });

  test('it comes back in time: never missing, nothing restored', () async {
    await device(siren, silentFor: const Duration(seconds: 50));
    updating[siren] = t0.subtract(const Duration(seconds: 70));
    final s = supervise();
    await s.evaluate();
    expect(of(siren).online, isTrue);

    // Its NAME_ANNOUNCE with the new version; its row of the rollout is
    // settled.
    now = t0.add(const Duration(seconds: 30));
    await (db.update(db.meshDevices)..where((t) => t.mac.equals(siren)))
        .write(MeshDevicesCompanion(lastSeenAt: Value(now)));
    updating.remove(siren);
    await s.evaluate();

    expect(of(siren).online, isTrue);
    expect(of(siren).heard, isTrue);
    expect(of(siren).updating, isFalse);
    expect(await troubles(), isEmpty);
  });

  test('it never comes back: missing when the time is over', () async {
    await device(siren, silentFor: const Duration(seconds: 10));
    updating[siren] = t0.subtract(const Duration(seconds: 10));
    final s = supervise();
    await s.evaluate();
    expect(await troubles(), isEmpty);

    // The board gave up on it (TIMED_OUT): its row is failed.
    now = t0.add(const Duration(seconds: 295));
    updating.remove(siren);
    await s.evaluate();
    expect(of(siren).online, isFalse);
    expect((await troubles()).single['kind'], 'device_missing');
  });

  test('the board saying MISSING does not beat the exception', () async {
    await device(siren, silentFor: const Duration(seconds: 10));
    await (db.update(db.meshDevices)..where((t) => t.mac.equals(siren))).write(
      MeshDevicesCompanion(
        boardState: Value(SafrDeviceState.missing.wire),
        tableSyncedAt: Value(t0),
      ),
    );
    updating[siren] = t0.subtract(const Duration(seconds: 5));
    await supervise().evaluate();
    expect(of(siren).online, isTrue);
    expect(of(siren).heard, isFalse);
    expect(await troubles(), isEmpty);
  });

  test('a unit that is updating and talks is simply online', () async {
    await device(siren, silentFor: const Duration(seconds: 2));
    updating[siren] = t0.subtract(const Duration(seconds: 30));
    await supervise().evaluate();
    expect(of(siren).online, isTrue);
    expect(of(siren).heard, isTrue);
    expect(of(siren).updating, isTrue);
  });

  group('on the screens', () {
    TopologyNode node({
      required bool online,
      bool updating = false,
      bool heard = true,
      int layer = 2,
    }) =>
        TopologyNode(
          mac: siren,
          role: layer == 1 ? SafrNodeRole.root : SafrNodeRole.node,
          layer: layer,
          parentMac: null,
          rssi: -60,
          batteryPct: null,
          online: online,
          lastSeenAt: DateTime.now().toUtc(),
          alarmLatched: false,
          updating: updating,
          heard: heard,
        );

    test('"Atualizando", never "Sem comunicação"', () {
      expect(deviceStateLabel(node(online: false)), 'Sem comunicação');
      expect(deviceStateLabel(node(online: true)), 'Online');
      expect(
          deviceStateLabel(node(online: true, updating: true, heard: false)),
          'Atualizando');
      expect(deviceStateLabel(node(online: true, updating: true)),
          'Atualizando');
    });

    test('a root that restarts into its new firmware is no root contender',
        () {
      final election = RootElectionNotifier(db);
      addTearDown(election.dispose);
      election.update(
        [node(online: true, updating: true, heard: false, layer: 1)],
        linkUp: true,
      );
      expect(election.state.candidates, isEmpty);
      election.update([node(online: true, layer: 1)], linkUp: true);
      expect(election.state.candidates, {siren});
    });

    test('who is updating is read from the rollout, row by row', () {
      OtaRolloutUnit unit(String mac, SafrOtaUnitState s, DateTime? since) =>
          OtaRolloutUnit(
            mac: mac,
            productCode: 0x0201,
            state: s,
            changedAt: t0,
            activeSince: since,
          );
      final rollout = OtaRolloutState(
        boardAnswered: true,
        families: {
          SafrProductFamily.node: OtaFamilyRollout(
            family: SafrProductFamily.node,
            state: SafrOtaRolloutState.rolling,
            target: '0.2.0',
            total: 3,
            updatedAt: t0,
            units: [
              unit(siren, SafrOtaUnitState.rebooting, t0),
              unit(other, SafrOtaUnitState.waiting, null),
              unit('5A:46:52:00:00:04', SafrOtaUnitState.done, null),
            ],
          ),
        },
      );
      final units = OtaUpdatingUnits.of(rollout);
      expect(units.since(siren), t0);
      expect(units.since(other), isNull);
      expect(units.since('5A:46:52:00:00:04'), isNull);
      expect(
          units.updatingAt(
              siren, t0.add(const Duration(seconds: 299)), otaUpdatingGrace),
          isTrue);
      expect(
          units.updatingAt(
              siren, t0.add(const Duration(seconds: 300)), otaUpdatingGrace),
          isFalse);
      // Equal when they say the same: what watches it is not rebuilt for
      // a percent.
      expect(OtaUpdatingUnits.of(rollout), units);
      expect(OtaUpdatingUnits.of(const OtaRolloutState()),
          OtaUpdatingUnits.none);
    });
  });
}
