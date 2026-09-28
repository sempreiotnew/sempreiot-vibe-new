import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  TextColumn get zone =>
      text().nullable()(); // from NAME_ANNOUNCE/INSTALLATION (spec §7.10/§7.11)
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

@DriftDatabase(tables: [
  SerialPackets,
  DeviceMetadata,
  AuditEvents,
  MeshDevices,
  DeviceEvents,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'sempreiot'));

  /// For unit tests: pass NativeDatabase.memory().
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 9;

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
            await m.addColumn(meshDevices, meshDevices.zone);
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
        },
      );

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

  /// Wipes the mesh device registry (the Rede map). Live devices
  /// reappear on their next heartbeat; history in deviceEvents is kept.
  Future<void> clearMeshDevices() => delete(meshDevices).go();

  /// After a complete DEVICE_TABLE sync: rows the board no longer lists and
  /// that this tablet only ever knew through the board (never heard live, or
  /// already mirrored from an earlier table) are dropped.
  Future<int> pruneUnlistedBoardRows(Set<String> listedMacs) {
    final q = delete(meshDevices)
      ..where((t) => t.registryState.equals('enrolled') | t.boardState.isNotNull());
    if (listedMacs.isNotEmpty) {
      q.where((t) => t.mac.isNotIn(listedMacs.toList()));
    }
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
