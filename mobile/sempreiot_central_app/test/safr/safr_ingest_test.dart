import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

Uint8List _eventPayload({
  int type = 0x03,
  int code = 0x01,
  int battery = 85,
  int devSeq = 100,
}) =>
    Uint8List.fromList([
      type, code, 0x68, 0x6E, 0x2F, 0x00,
      0x05, battery, 0x10, 0x68, 0x02, 0x26, 0x2A, 0x00, 0x00,
      (devSeq >> 8) & 0xFF, devSeq & 0xFF,
    ]);

/// TOPOLOGY (spec §7.4) as a battery leaf sends it after a bind (§12.7):
/// role 2, layer 2, parent 5A:46:52:00:00:03, link −40, two candidates.
Uint8List _leafTopologyPayload() => Uint8List.fromList([
      0x68, 0x6E, 0x2F, 0x01, // timestamp
      0x02, 0x02, // NODE_ROLE leaf, LAYER 2
      0x5A, 0x46, 0x52, 0x00, 0x00, 0x03, // PARENT_MAC
      0xD8, // RSSI_TO_PARENT −40
      0x02, // CHILD_COUNT
      0x5A, 0x46, 0x52, 0x00, 0x00, 0x03, 0xD8, // candidate 1, −40
      0x5A, 0x46, 0x52, 0x00, 0x00, 0x04, 0xB0, // candidate 2, −80
    ]);

Uint8List _heartbeatPayload({int layer = 0}) => Uint8List.fromList([
      0x68, 0x6E, 0x2F, 0x01, 0x00, 0x00, 0x0E, 0x10,
      0x01, 0x64, 0x00, 0xFA, 0xBE,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x01, layer,
    ]);

void main() {
  late AppDatabase db;
  late SafrIngestService ingest;
  late List<SafrWireFrame> acked;
  late List<SafrEventLogDataPayload> journal;
  late int validCount;
  late int invalidCount;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    acked = [];
    journal = [];
    validCount = 0;
    invalidCount = 0;
    ingest = SafrIngestService(
      db: db,
      onValidFrame: () => validCount++,
      onInvalidFrame: () => invalidCount++,
      onAckRequired: (f) async => acked.add(f),
      onJournalData: journal.add,
    );
  });

  tearDown(() => db.close());

  SafrEncoder nodeEncoder({int bootCtr = 10}) => SafrEncoder(
        srcMac: safrMacToBytes('5A:46:52:00:00:03'),
        bootCtr: bootCtr,
      );

  test('valid EVENT: raw packet + device row + feed row + ACK', () async {
    final frame = nodeEncoder().encode(
      msgType: SafrMsgType.event,
      payload: _eventPayload(),
      ackRequired: true,
    );
    await ingest.handleFrame(frame, deviceId: 'test');

    expect(validCount, 1);
    expect(await db.select(db.serialPackets).get(), hasLength(1));

    final devices = await db.select(db.meshDevices).get();
    expect(devices, hasLength(1));
    expect(devices.first.mac, '5A:46:52:00:00:03');
    expect(devices.first.batteryPct, 85);
    expect(devices.first.lastDevSeq, 100);

    final events = await db.select(db.deviceEvents).get();
    expect(events, hasLength(1));
    expect(events.first.severity, 3); // ALARM
    expect(events.first.eventCode, SafrEventCode.smokeAlarm.wire);
    expect(events.first.devSeq, 100);
    expect(events.first.packetId, isNotNull);
    expect(events.first.ackedAt, isNotNull, reason: 'central must ACK');
    expect(acked, hasLength(1));
  });

  test('ALARM latches; RESTORE does NOT clear the latch (spec §7.1.4)',
      () async {
    final enc = nodeEncoder();
    await ingest.handleFrame(
      enc.encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(devSeq: 100), // ALARM
        ackRequired: true,
      ),
      deviceId: 'test',
    );
    var device = (await db.select(db.meshDevices).get()).single;
    expect(device.alarmLatched, 1, reason: 'UL 864/NFPA 72: alarm latches');
    expect(device.alarmLatchedAt, isNotNull);

    // RESTORE arrives (smoke cleared at the device).
    await ingest.handleFrame(
      enc.encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(type: 0x01, code: 0x0B, devSeq: 101),
      ),
      deviceId: 'test',
    );
    device = (await db.select(db.meshDevices).get()).single;
    expect(device.alarmLatched, 1,
        reason: 'only an operator RESET clears the latch');

    // Operator RESET confirmed → latch clears.
    await db.clearAlarmLatch(mac: '5A:46:52:00:00:03');
    device = (await db.select(db.meshDevices).get()).single;
    expect(device.alarmLatched, 0);
  });

  test('F_RETX re-announcement (same DEV_SEQ, fresh MSG_ID) dedupes but ACKs',
      () async {
    final enc = nodeEncoder();
    await ingest.handleFrame(
      enc.encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(devSeq: 55),
        ackRequired: true,
      ),
      deviceId: 'test',
    );
    // 60 s later: same event re-announced with a fresh MSG_ID (spec §7.2).
    await ingest.handleFrame(
      enc.encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(devSeq: 55),
        ackRequired: true,
        retx: true,
      ),
      deviceId: 'test',
    );

    expect(await db.select(db.deviceEvents).get(), hasLength(1),
        reason: 'same DEV_SEQ must never become two feed rows');
    expect(acked, hasLength(2), reason: 'spec: ACK every time');
  });

  test('plaintext frames are rejected in production posture (spec §4.1)',
      () async {
    final frame = nodeEncoder().encode(
      msgType: SafrMsgType.event,
      payload: _eventPayload(),
      encrypt: false,
      ackRequired: true,
    );
    await ingest.handleFrame(frame, deviceId: 'test');

    expect(invalidCount, 1);
    expect(acked, isEmpty, reason: 'unauthenticated frames are never ACKed');
    expect(await db.select(db.meshDevices).get(), isEmpty);
    final events = await db.select(db.deviceEvents).get();
    expect(events, hasLength(1));
    expect(events.first.errorKind, 'plaintext_rejected');
  }, skip: kSafrAllowPlaintext ? 'built with SAFR_ALLOW_PLAINTEXT' : false);

  test('foreign SYSTEM_ID: diagnostic row, state untouched (spec §3.1)',
      () async {
    final foreign = SafrEncoder(
      srcMac: safrMacToBytes('5A:46:52:00:00:03'),
      bootCtr: 10,
      systemId: 0xBEEF, // neighboring installation
    ).encode(
      msgType: SafrMsgType.event,
      payload: _eventPayload(),
      ackRequired: true,
    );
    await ingest.handleFrame(foreign, deviceId: 'test');

    expect(invalidCount, 1);
    expect(acked, isEmpty);
    expect(await db.select(db.meshDevices).get(), isEmpty);
    final events = await db.select(db.deviceEvents).get();
    expect(events.single.errorKind, 'foreign_system');
  });

  test('EVENT_LOG_DATA: historic event accepted once, deduped against live',
      () async {
    final enc = nodeEncoder();
    // Live alarm seen normally.
    await ingest.handleFrame(
      enc.encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(devSeq: 200),
        ackRequired: true,
      ),
      deviceId: 'test',
    );

    // Root replays journal: the same event (dup) + one missed event.
    final root = SafrEncoder(
      srcMac: safrMacToBytes('5A:46:52:00:00:01'),
      bootCtr: 3,
    );
    Uint8List logData(int jrn, int devSeq, {bool last = false}) =>
        root.encode(
          msgType: SafrMsgType.eventLogData,
          payload: SafrEventLogDataPayload.build(
            jrnSeq: jrn,
            logFlags: last ? safrLogFlagLast : 0,
            origSrcMac: safrMacToBytes('5A:46:52:00:00:03'),
            eventPayload17:
                _eventPayload(type: 0x04, code: 0x06, devSeq: devSeq),
          ),
        );

    await ingest.handleFrame(logData(9, 200), deviceId: 'test');
    await ingest.handleFrame(logData(10, 199, last: true), deviceId: 'test');

    expect(journal, hasLength(2), reason: 'downlink tracks every log entry');
    final events = await db.select(db.deviceEvents).get();
    // 1 live (devSeq 200) + 1 backfilled (devSeq 199); jrn 9 was a duplicate.
    expect(events, hasLength(2));
    expect(events.map((e) => e.devSeq), containsAll([200, 199]));
  });

  test('heartbeat updates registry silently (no feed row)', () async {
    final frame = nodeEncoder().encode(
      msgType: SafrMsgType.heartbeat,
      payload: _heartbeatPayload(layer: 0),
    );
    await ingest.handleFrame(frame, deviceId: 'test');

    final devices = await db.select(db.meshDevices).get();
    expect(devices, hasLength(1));
    expect(devices.first.role, SafrNodeRole.root.wire, reason: 'layer 0');
    expect(devices.first.lastRssi, -66);
    expect(devices.first.lastHeartbeatAt, isNotNull);
    expect(await db.select(db.deviceEvents).get(), isEmpty);
  });

  test('leaf HEARTBEAT with F_ACK_REQ is not ACKed by the tablet (spec §7.5)',
      () async {
    // The parent's ACK is the leaf's; the tablet's would be dropped by the
    // parent after crossing the whole mesh.
    await ingest.handleFrame(
      nodeEncoder().encode(
        msgType: SafrMsgType.heartbeat,
        payload: _heartbeatPayload(layer: 2),
        ackRequired: true,
      ),
      deviceId: 'test',
    );
    expect(validCount, 1);
    expect(await db.select(db.meshDevices).get(), hasLength(1),
        reason: 'still supervises the leaf');
    expect(acked, isEmpty);
  });

  test('auth failure: diagnostic row, device registry untouched', () async {
    final frame = Uint8List.fromList(nodeEncoder().encode(
      msgType: SafrMsgType.event,
      payload: _eventPayload(),
    ));
    frame[frame.length - 4] ^= 0x01; // corrupt tag
    _fixCrc(frame); // keep CRC valid so only auth fails
    await ingest.handleFrame(frame, deviceId: 'test');

    expect(invalidCount, 1);
    expect(await db.select(db.meshDevices).get(), isEmpty,
        reason: 'unauthenticated data must not update trusted state');
    final events = await db.select(db.deviceEvents).get();
    expect(events, hasLength(1));
    expect(events.first.errorKind, 'auth_failed');
    expect(events.first.severity, 1);
  });

  test('replay (same counters) is rejected', () async {
    final enc = nodeEncoder(bootCtr: 7);
    final frame = enc.encode(
      msgType: SafrMsgType.event,
      payload: _eventPayload(),
      msgCtr: 100,
    );
    await ingest.handleFrame(frame, deviceId: 'test');
    await ingest.handleFrame(frame, deviceId: 'test'); // exact replay

    expect(await db.select(db.deviceEvents).get(), hasLength(1));
    final device = (await db.select(db.meshDevices).get()).single;
    expect(device.lastMsgCtr, 100);
  });

  test('v1 frames are stored raw without touching trusted state', () async {
    // A minimal v1-shaped frame (VER=0x01): stored, not parsed as v2/v3.
    final v1 = Uint8List(48)..[0] = safrSof..[1] = safrVer1;
    v1[2] = 0;
    v1[3] = 48;
    await ingest.handleFrame(v1, deviceId: 'test');

    expect(await db.select(db.serialPackets).get(), hasLength(1));
    expect(await db.select(db.meshDevices).get(), isEmpty);
    expect(await db.select(db.deviceEvents).get(), isEmpty);
  });

  test('leaf: TOPOLOGY stores parent candidates; a later HEARTBEAT keeps the leaf role',
      () async {
    final leaf = SafrEncoder(srcMac: safrMacToBytes('5A:46:52:00:00:77'), bootCtr: 3);
    await ingest.handleFrame(
      leaf.encode(msgType: SafrMsgType.topology, payload: _leafTopologyPayload()),
      deviceId: 'test',
    );
    var row = await (db.select(db.meshDevices)
          ..where((t) => t.mac.equals('5A:46:52:00:00:77')))
        .getSingle();
    expect(row.role, SafrNodeRole.leaf.wire);
    expect(row.parentMac, '5A:46:52:00:00:03');
    expect(row.parentCandidates, contains('5A:46:52:00:00:04'));
    expect(row.parentCandidates, contains('-80'));

    // Heartbeat from layer 3 (parent + 1): a node would read as "node", a
    // known leaf must stay a leaf (spec §12 — TOPOLOGY comes only on a bind).
    await ingest.handleFrame(
      leaf.encode(msgType: SafrMsgType.heartbeat, payload: _heartbeatPayload(layer: 3)),
      deviceId: 'test',
    );
    row = await (db.select(db.meshDevices)
          ..where((t) => t.mac.equals('5A:46:52:00:00:77')))
        .getSingle();
    expect(row.role, SafrNodeRole.leaf.wire);
    expect(row.parentCandidates, contains('5A:46:52:00:00:04'),
        reason: 'candidates survive heartbeats');
  });
}

void _fixCrc(Uint8List f) {
  var crc = 0xFFFF;
  for (var i = 0; i < f.length - 2; i++) {
    crc ^= f[i] << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  f[f.length - 2] = (crc >> 8) & 0xFF;
  f[f.length - 1] = crc & 0xFF;

}
