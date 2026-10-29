import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/central/domain/system_test/system_test_run.dart';

part 'app_database.g.dart';

class SerialPackets extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get receivedAt => dateTime()();
  TextColumn get deviceId => text()();
  BlobColumn get rawBytes => blob()();
  IntColumn get byteLength => integer()();
  TextColumn get hexPreview => text()();
}

/// Key/value store for app settings and device configuration.
/// Values are JSON-encoded strings to support any future type.
class DeviceMetadata extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Append-only trail of security-relevant events on this central: PIN
/// changes, grants/blocks, unlock failures, master add/remove. Detail is a
/// small JSON payload and must never contain a PIN or password.
class AuditEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get at => dateTime()();
  TextColumn get actor => text()(); // 'master' | 'admin' | 'root' | 'system'
  TextColumn get action => text()(); // e.g. 'pin_changed', 'master_granted'
  TextColumn get detail => text()(); // JSON
}

/// Registry of mesh devices, keyed by MAC — the trusted state built from
/// authenticated SAFR frames only (docs/safr/protocol-safr-v3.md).
class MeshDevices extends Table {
  TextColumn get mac => text()();
  IntColumn get role => integer().withDefault(const Constant(255))();
  IntColumn get layer => integer().withDefault(const Constant(0))();
  TextColumn get parentMac => text().nullable()();
  IntColumn get lastRssi => integer().nullable()(); // dBm
  IntColumn get batteryPct => integer().nullable()();
  // v3.6 DL_HEARD (spec §7.3): board heartbeats the unit heard in the last
  // 120 s, 0..8; null = not reported (leaf, older firmware, window restarted).
  IntColumn get dlHeard => integer().nullable()();
  // 0 = link ok, 1 = "qualidade do enlace degradada" raised (spec §9.4):
  // persisted so the trouble is not raised again on every restart.
  IntColumn get linkDegraded => integer().withDefault(const Constant(0))();
  DateTimeColumn get firstSeenAt => dateTime()();
  DateTimeColumn get lastSeenAt => dateTime()();
  DateTimeColumn get lastHeartbeatAt => dateTime().nullable()();
  // Replay detection: last accepted nonce counters (spec §4).
  IntColumn get lastBootCtr => integer().withDefault(const Constant(0))();
  IntColumn get lastMsgCtr => integer().withDefault(const Constant(0))();
  // 0 = online, 1 = offline ("device missing" already raised) — persisted so
  // the trouble isn't re-raised on every app restart.
  IntColumn get supervisionState => integer().withDefault(const Constant(0))();
  TextColumn get name => text().nullable()(); // future friendly names
  // v3.8 labels (spec §14.1): the unit's zone / endereçamento ids as the
  // board's table holds them (DEVICE_TABLE format 2) or as this tablet set
  // them; null = never reported, 0 = none. The names are in DeviceLabels.
  // linkKind: safrLinkMesh (0) / safrLinkIsland (1), spec §7.12.
  IntColumn get zoneId => integer().nullable()();
  IntColumn get addressId => integer().nullable()();
  IntColumn get linkKind => integer().withDefault(const Constant(0))();
  // 'enrolled' = known only from the board's INSTALLATION reply (spec §7.10),
  // never yet heard from directly over the mesh; null once any live frame
  // arrives (supervisionState/alarmLatched then carry online/missing).
  TextColumn get registryState => text().nullable()();
  // Highest accepted event DEV_SEQ (SAFR v3 §6) — dedupes 60 s alarm
  // re-announcements and journal replays. 0 = none seen (v2 events).
  IntColumn get lastDevSeq => integer().withDefault(const Constant(0))();
  // Alarm latch (SAFR v3 §7.1.4 — UL 864/NFPA 72): set on accepted ALARM,
  // cleared ONLY by operator RESET. Survives restarts by design.
  IntColumn get alarmLatched => integer().withDefault(const Constant(0))();
  DateTimeColumn get alarmLatchedAt => dateTime().nullable()();
  // v3.2 DEVICE_TABLE mirror (spec §7.12, lifecycle §3): the board's view of
  // this MAC. boardState: 0 expected · 1 online · 2 missing · 3 retired,
  // null = not (yet) in the board's table. boardFlags: SafrDeviceFlags bits.
  IntColumn get boardState => integer().nullable()();
  IntColumn get boardFlags => integer().withDefault(const Constant(0))();
  DateTimeColumn get tableSyncedAt => dateTime().nullable()();
  // v3.4 (spec §12.7): a battery leaf's parent candidates from its bind-time
  // TOPOLOGY, JSON [{"mac":..,"rssi":..}] — "pais ao alcance" on the sheet and
  // the walk-test flags (fewer than 2, link below −85 dBm). Null for nodes.
  TextColumn get parentCandidates => text().nullable()();
  // v3.5 product identity (spec §7.11 NAME_ANNOUNCE / §7.12 DEVICE_TABLE).
  // productCode: the 16-bit PRODUCT (high byte = family), catalogue in
  // safr_product.dart; hwRev: hardware revision; fwVersion: e.g. "0.1.0-dev".
  // Null = never reported (firmware older than v3.5). A known value is never
  // replaced by unknown/empty.
  IntColumn get productCode => integer().nullable()();
  IntColumn get hwRev => integer().nullable()();
  TextColumn get fwVersion => text().nullable()();

  @override
  Set<Column> get primaryKey => {mac};
}

/// Humanized event feed: decoded device events, supervision troubles and
/// link diagnostics. severity: 0 ok · 1 trouble · 2 alert · 3 alarm.
class DeviceEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get receivedAt => dateTime()();
  TextColumn get deviceMac => text()();
  IntColumn get msgType => integer()(); // SAFR MSG_TYPE; 0 = synthetic
  IntColumn get eventType => integer().nullable()(); // SAFR EVENT_TYPE wire
  IntColumn get eventCode => integer().nullable()(); // SAFR EVENT_CODE wire
  IntColumn get severity => integer()();
  TextColumn get detailJson => text()();
  IntColumn get packetId => integer().nullable()(); // SerialPackets.id
  TextColumn get errorKind =>
      text().nullable()(); // crc_failed|auth_failed|parse_error|replay
  DateTimeColumn get ackedAt => dateTime().nullable()(); // central's ACK time
  // SAFR v3 event identity (spec §6) — (deviceMac, devSeq) dedupes 60 s alarm
  // re-announcements and journal replays exactly, including gap backfill.
  IntColumn get devSeq => integer().nullable()();
}

/// One firmware update started on "Atualizar dispositivos" (OTA brief
/// decision 9, §6): who, when, what, how it ended. Kept on the tablet;
/// [syncedAt] is for the cloud mirror (null = not sent yet).
class OtaRuns extends Table {
  /// Random, unique also in the cloud (16 hex digits).
  TextColumn get runId => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();

  /// Audit actor who started it: 'master' | 'admin' | 'system', or
  /// 'remote:<name>' for a user's phone (docs/ota/ota-internet-plan.md §5.4).
  TextColumn get startedBy => text()();

  /// Where the image came from: 'manual' (a file chosen on the tablet) or
  /// 'internet' (a published release, docs/ota/ota-internet-plan.md).
  TextColumn get source => text().withDefault(const Constant('manual'))();

  /// Who published the release ("tallesaugusto · MacBook-Pro · 4706fbb");
  /// null for a manual image.
  TextColumn get publishedBy => text().nullable()();

  /// "Atualizar tudo" (board → nodes → detectors).
  BoolColumn get allPhases => boolean()();
  TextColumn get target => text()(); // the version every unit goes to
  TextColumn get families => text()(); // 'board,node,leaf' in phase order

  /// 'done' | 'partial' | 'failed' | 'cancelled' | 'stopped'; null = running.
  TextColumn get outcome => text().nullable()();
  TextColumn get message => text().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {runId};
}

/// One unit in one update: what it ran, what it runs now, how it went. One
/// row per unit per run, rewritten while the run goes on (a retry included).
class OtaRunUnits extends Table {
  TextColumn get runId => text()();
  TextColumn get unitKey => text()(); // MAC; '@board' for the board
  TextColumn get family => text()(); // 'board' | 'node' | 'leaf'
  TextColumn get versionBefore => text()();
  TextColumn get versionAfter => text()();

  /// SafrOtaUnitState name: waiting … done | failed | skipped.
  TextColumn get state => text()();
  IntColumn get attempts => integer()();
  IntColumn get reasonRaw => integer()(); // protocol §13.7 REASON
  TextColumn get note => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {runId, unitKey};
}

/// One "Teste do sistema" (TESTAR to every unit at once; reference §3.6.1,
/// `system_test_run.dart`): when it ran, who started it, how it ended and
/// each unit's answer, as the run's JSON. One row per test, rewritten while
/// it runs and once when it ends.
class SystemTests extends Table {
  TextColumn get testId => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();

  /// Who started it from a phone; null = the tablet itself.
  TextColumn get startedBy => text().nullable()();

  /// `SystemTestVerdict` name: 'running' | 'passed' | 'failed' | 'cancelled'.
  TextColumn get verdict => text()();

  /// `SystemTestRun.toJson()`: the units with their outcomes.
  TextColumn get runJson => text()();

  @override
  Set<Column> get primaryKey => {testId};
}

/// The board's zone / endereçamento tables (spec §14.2), mirrored page by
/// page from LABEL_TABLE: the names behind the ids in [MeshDevices]. `kind`
/// is the SafrLabelKind wire value (1 zone · 2 endereçamento).
class DeviceLabels extends Table {
  IntColumn get kind => integer()();
  IntColumn get labelId => integer()();
  TextColumn get name => text()();

  @override
  Set<Column> get primaryKey => {kind, labelId};
}

@DriftDatabase(tables: [
  SerialPackets,
  DeviceMetadata,
  AuditEvents,
  MeshDevices,
  DeviceEvents,
  OtaRuns,
  OtaRunUnits,
  SystemTests,
  DeviceLabels,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sempreiot'));

  /// For unit tests: pass NativeDatabase.memory().
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 15;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
            'CREATE INDEX idx_received_at ON serial_packets(received_at DESC)',
          );
          await _createDeviceEventIndexes();
          await seedDefaultMetadata();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(deviceMetadata);
          }
          if (from < 3) {
            // Seeds new defaults; insertOrIgnore preserves existing rows.
            await seedDefaultMetadata();
          }
          if (from < 4) {
            await m.createTable(auditEvents);
          }
          if (from < 5) {
            await m.createTable(meshDevices);
            await m.createTable(deviceEvents);
            await _createDeviceEventIndexes();
          }
          if (from < 6) {
            // SAFR v3: event identity + alarm latching (docs/safr/protocol-safr-v3.md).
            await m.addColumn(meshDevices, meshDevices.lastDevSeq);
            await m.addColumn(meshDevices, meshDevices.alarmLatched);
            await m.addColumn(meshDevices, meshDevices.alarmLatchedAt);
            await m.addColumn(deviceEvents, deviceEvents.devSeq);
          }
          if (from < 7) {
            // SAFR v3.1 (POC-BRIEF.md §4.2/§6.3): NAME_ANNOUNCE/INSTALLATION.
            // (The zone string column of that revision is gone since v15.)
            await m.addColumn(meshDevices, meshDevices.registryState);
          }
          if (from < 8) {
            // SAFR v3.2 DEVICE_TABLE mirror (installation-lifecycle-v1.md §3).
            await m.addColumn(meshDevices, meshDevices.boardState);
            await m.addColumn(meshDevices, meshDevices.boardFlags);
            await m.addColumn(meshDevices, meshDevices.tableSyncedAt);
          }
          if (from < 9) {
            // SAFR v3.4 leaf link (protocol §12.7): parent candidates.
            await m.addColumn(meshDevices, meshDevices.parentCandidates);
          }
          if (from < 10) {
            // SAFR v3.5 product identity (protocol §7.11/§7.12).
            await m.addColumn(meshDevices, meshDevices.productCode);
            await m.addColumn(meshDevices, meshDevices.hwRev);
            await m.addColumn(meshDevices, meshDevices.fwVersion);
          }
          if (from < 11) {
            // Firmware update history (OTA brief decision 9).
            await m.createTable(otaRuns);
            await m.createTable(otaRunUnits);
          }
          if (from < 12 && from >= 11) {
            // OTA through the Internet: where the image came from, and who
            // published it (docs/ota/ota-internet-plan.md D12). A database
            // older than 11 got the table with these columns just above.
            await m.addColumn(otaRuns, otaRuns.source);
            await m.addColumn(otaRuns, otaRuns.publishedBy);
          }
          if (from < 13) {
            // System tests kept and reported (2026-10-14).
            await m.createTable(systemTests);
          }
          if (from < 14) {
            // SAFR v3.6 downlink loss (protocol §7.3 DL_HEARD, §9.4). Added
            // only when absent: a file created by this version and taken
            // back to an older one (the migration tests) already has them.
            if (!await _hasColumn('mesh_devices', 'dl_heard')) {
              await m.addColumn(meshDevices, meshDevices.dlHeard);
            }
            if (!await _hasColumn('mesh_devices', 'link_degraded')) {
              await m.addColumn(meshDevices, meshDevices.linkDegraded);
            }
          }
          if (from < 15) {
            // SAFR v3.8 labels (protocol §14.1): zone / endereçamento ids
            // and the link kind per unit, the label tables, and the zone
            // string column gone (the board no longer sends it).
            // Each step only when absent: a file created by this version
            // and taken back to an older one (the migration tests) has them.
            if (!await _hasTable('device_labels')) {
              await m.createTable(deviceLabels);
            }
            if (!await _hasColumn('mesh_devices', 'zone_id')) {
              await m.addColumn(meshDevices, meshDevices.zoneId);
            }
            if (!await _hasColumn('mesh_devices', 'address_id')) {
              await m.addColumn(meshDevices, meshDevices.addressId);
            }
            if (!await _hasColumn('mesh_devices', 'link_kind')) {
              await m.addColumn(meshDevices, meshDevices.linkKind);
            }
            if (await _hasColumn('mesh_devices', 'zone')) {
              await customStatement('ALTER TABLE mesh_devices DROP COLUMN zone');
            }
          }
        },
      );

  Future<bool> _hasTable(String table) async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(table)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<bool> _hasColumn(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  Future<void> _createDeviceEventIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_dev_events_received '
      'ON device_events(received_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_dev_events_mac '
      'ON device_events(device_mac)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_dev_events_severity '
      'ON device_events(severity)',
    );
  }

  Future<void> deleteOlderThan(DateTime cutoff) async {
    await (delete(serialPackets)
          ..where((t) => t.receivedAt.isSmallerThanValue(cutoff)))
        .go();
    await (delete(deviceEvents)
          ..where((t) => t.receivedAt.isSmallerThanValue(cutoff)))
        .go();
  }

  Future<void> deleteAllPackets() => delete(serialPackets).go();

  /// Seeds the three default metadata rows. Safe to call multiple times —
  /// uses insertOrIgnore so existing values (e.g. user-set pin) are preserved.
  Future<void> seedDefaultMetadata() async {
    Future<void> seed(String key, Object defaults) =>
        into(deviceMetadata).insert(
          DeviceMetadataCompanion.insert(key: key, value: jsonEncode(defaults)),
          mode: InsertMode.insertOrIgnore,
        );

    await seed('info', {
      'name': '',
      'firmware_version': '',
      'subId': '',
      'old_subId': '',
      'created_at': '',
      'updated_at': '',
    });
    await seed('credentials', {
      'pin': '',
      'root': '',
      'password': '',
      'level_pins': <String, String>{}
    });
    await seed('access', <dynamic>[]);
    await seed('iot', {'iot_client_id': '', 'iot_password': ''});
  }

  Future<void> clearAllMeta() => delete(deviceMetadata).go();

  /// Everything this central knows about the units of the installation it
  /// is leaving: the device registry (the Rede map and its names), the zone
  /// / endereçamento tables and the event feed. Called whenever the central
  /// changes identity — "Desvincular", or a code with another SYSTEM_ID
  /// adopted — so the next installation starts empty and never inherits the
  /// units of the one before (lifecycle §5 N). Audit, OTA history, system
  /// tests and raw packets stay: they are this tablet's record.
  Future<void> forgetInstallationUnits() => transaction(() async {
        await delete(meshDevices).go();
        await delete(deviceLabels).go();
        await delete(deviceEvents).go();
      });

  /// Wipes the mesh device registry (the Rede map). Live devices
  /// reappear on their next heartbeat; history in deviceEvents is kept.
  /// After a complete DEVICE_TABLE sync. Rows the board no longer lists:
  /// one this tablet only ever knew through the board (`enrolled`, never
  /// heard) is dropped; one the tablet heard itself stays — with its name —
  /// and only forgets what the board said about it (`boardState`, flags).
  /// A board that was erased sends an empty table: the tablet's own
  /// knowledge of the units is never thrown away for that.
  Future<int> pruneUnlistedBoardRows(Set<String> listedMacs) async {
    final gone = delete(meshDevices)
      ..where((t) => t.registryState.equals('enrolled'));
    final forget = update(meshDevices)..where((t) => t.boardState.isNotNull());
    if (listedMacs.isNotEmpty) {
      gone.where((t) => t.mac.isNotIn(listedMacs.toList()));
      forget.where((t) => t.mac.isNotIn(listedMacs.toList()));
    }
    final dropped = await gone.go();
    await forget.write(const MeshDevicesCompanion(
      boardState: Value(null),
      boardFlags: Value(0),
      tableSyncedAt: Value(null),
    ));
    return dropped;
  }

  /// After a "Sincronizar com a placa": rows the board does not list and
  /// that have been silent since [silentBefore] — units removed from the
  /// installation, or left over from another one. A unit heard recently
  /// stays whatever the table says: it is plainly there.
  /// An empty table (a board just erased) removes nothing.
  Future<int> pruneUnlistedSilentRows(
      Set<String> listedMacs, DateTime silentBefore) {
    if (listedMacs.isEmpty) return Future.value(0);
    final q = delete(meshDevices)
      ..where((t) =>
          t.lastSeenAt.isSmallerThanValue(silentBefore) &
          t.mac.isNotIn(listedMacs.toList()));
    return q.go();
  }

  // Metadata helpers — upsert and read by key
  Future<void> setMeta(String key, String value) =>
      into(deviceMetadata).insertOnConflictUpdate(
        DeviceMetadataCompanion.insert(key: key, value: value),
      );

  Future<String?> getMeta(String key) async {
    final row = await (select(deviceMetadata)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  // Audit trail helpers
  /// Writes a system test as it is now (one row per test).
  Future<void> saveSystemTest(SystemTestRun run) =>
      into(systemTests).insertOnConflictUpdate(SystemTestsCompanion.insert(
        testId: run.id,
        startedAt: run.startedAt,
        endedAt: Value(run.endedAt),
        startedBy: Value(run.by),
        verdict: run.verdict.name,
        runJson: jsonEncode(run.toJson()),
      ));

  /// The last tests, newest first.
  Future<List<SystemTestRun>> recentSystemTests({int limit = 20}) async {
    final rows = await (select(systemTests)
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(limit))
        .get();
    return [
      for (final r in rows)
        if (SystemTestRun.fromJson(jsonDecode(r.runJson)) case final run?) run,
    ];
  }

  /// Every label of every kind, live (the board's tables as last mirrored).
  Stream<List<DeviceLabel>> watchLabels() => select(deviceLabels).watch();

  /// The board sent a kind's complete table (protocol §14.2): this copy
  /// becomes exactly that.
  Future<void> replaceLabels(int kind, Map<int, String> labels) =>
      transaction(() async {
        await (delete(deviceLabels)..where((t) => t.kind.equals(kind))).go();
        for (final e in labels.entries) {
          await into(deviceLabels).insert(DeviceLabelsCompanion.insert(
              kind: kind, labelId: e.key, name: e.value));
        }
      });

  /// How many units carry this label (DEL_LABEL is refused while any does).
  Future<int> countUnitsWithLabel(int kind, int labelId) async {
    final column = kind == 1 ? meshDevices.zoneId : meshDevices.addressId;
    final n = meshDevices.mac.count();
    final row = await (selectOnly(meshDevices)
          ..addColumns([n])
          ..where(column.equals(labelId)))
        .getSingle();
    return row.read(n) ?? 0;
  }

  Future<void> addAudit(
          String actor, String action, Map<String, Object?> detail) =>
      into(auditEvents).insert(AuditEventsCompanion.insert(
        at: DateTime.now(),
        actor: actor,
        action: action,
        detail: jsonEncode(detail),
      ));

  Future<List<AuditEvent>> recentAudit({int limit = 100}) =>
      (select(auditEvents)
            ..orderBy([(t) => OrderingTerm.desc(t.at)])
            ..limit(limit))
          .get();

  /// Clears the alarm latch (SAFR v3 §7.1.4) — call ONLY after the root ACKed
  /// an operator RESET command. Null mac / broadcast clears every latch.
  Future<void> clearAlarmLatch({String? mac}) async {
    final query = update(meshDevices);
    if (mac != null && mac != safrBroadcastMac) {
      query.where((t) => t.mac.equals(mac));
    }
    await query.write(const MeshDevicesCompanion(
      alarmLatched: Value(0),
      alarmLatchedAt: Value(null),
    ));
  }
}

/// Broadcast destination as the registry spells MACs.
const safrBroadcastMac = 'FF:FF:FF:FF:FF:FF';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
