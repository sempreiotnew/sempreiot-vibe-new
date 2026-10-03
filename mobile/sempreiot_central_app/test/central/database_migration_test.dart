import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';

const _unitA = '5A:46:52:00:00:02';

/// Drift migrations that must not lose what a tablet in the field holds.
void main() {
  // The same file is opened twice on purpose, one after the other.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('schema v9 -> v10 adds the three columns and keeps the rows', () async {
    final dir = await Directory.systemTemp.createTemp('siot_migr_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sempreiot.sqlite');

    // A database as schema v10 creates it, then taken back to v9.
    final fresh = AppDatabase.forTesting(NativeDatabase(file));
    await fresh.into(fresh.meshDevices).insert(MeshDevicesCompanion.insert(
          mac: _unitA,
          firstSeenAt: DateTime.utc(2026, 9, 1),
          lastSeenAt: DateTime.utc(2026, 9, 2),
        ));
    await fresh.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase(file, setup: (raw) {
      raw.execute('ALTER TABLE mesh_devices DROP COLUMN product_code');
      raw.execute('ALTER TABLE mesh_devices DROP COLUMN hw_rev');
      raw.execute('ALTER TABLE mesh_devices DROP COLUMN fw_version');
      raw.execute('PRAGMA user_version = 9');
    }));
    addTearDown(upgraded.close);

    final r = await (upgraded.select(upgraded.meshDevices)
          ..where((t) => t.mac.equals(_unitA)))
        .getSingle();
    expect(r.lastSeenAt.toUtc(), DateTime.utc(2026, 9, 2));
    expect(r.productCode, isNull);
    expect(r.hwRev, isNull);
    expect(r.fwVersion, isNull);

    await (upgraded.update(upgraded.meshDevices)
          ..where((t) => t.mac.equals(_unitA)))
        .write(const MeshDevicesCompanion(
      productCode: Value(0x0301),
      hwRev: Value(1),
      fwVersion: Value('0.1.0'),
    ));
    final cols = await upgraded
        .customSelect('PRAGMA table_info(mesh_devices)')
        .map((row) => '${row.read<String>('name')}:'
            '${row.read<String>('type')}:${row.read<int>('notnull')}')
        .get();
    expect(
        cols,
        containsAll([
          'product_code:INTEGER:0',
          'hw_rev:INTEGER:0',
          'fw_version:TEXT:0'
        ]));
    final version = await upgraded
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    expect(version, 11);
  });

  test('schema v10 -> v11 adds the firmware update history, rows kept',
      () async {
    final dir = await Directory.systemTemp.createTemp('siot_migr_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sempreiot.sqlite');

    final fresh = AppDatabase.forTesting(NativeDatabase(file));
    await fresh.into(fresh.meshDevices).insert(MeshDevicesCompanion.insert(
          mac: _unitA,
          firstSeenAt: DateTime.utc(2026, 9, 1),
          lastSeenAt: DateTime.utc(2026, 9, 2),
        ));
    await fresh.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase(file, setup: (raw) {
      raw.execute('DROP TABLE ota_runs');
      raw.execute('DROP TABLE ota_run_units');
      raw.execute('PRAGMA user_version = 10');
    }));
    addTearDown(upgraded.close);

    expect(await upgraded.select(upgraded.meshDevices).get(), hasLength(1));
    await upgraded.into(upgraded.otaRuns).insert(OtaRunsCompanion.insert(
          runId: '0011223344556677',
          startedAt: DateTime.utc(2026, 10, 2, 15),
          startedBy: 'admin',
          allPhases: true,
          target: '0.2.6',
          families: 'board,node',
        ));
    await upgraded
        .into(upgraded.otaRunUnits)
        .insert(OtaRunUnitsCompanion.insert(
          runId: '0011223344556677',
          unitKey: _unitA,
          family: 'node',
          versionBefore: '2.2.5',
          versionAfter: '0.2.6',
          state: 'done',
          attempts: 1,
          reasonRaw: 0,
          updatedAt: DateTime.utc(2026, 10, 2, 15, 3),
        ));
    expect(await upgraded.select(upgraded.otaRunUnits).get(), hasLength(1));
    final version = await upgraded
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    expect(version, 11);
  });
}
