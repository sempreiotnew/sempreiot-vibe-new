import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

const _board = '7C:4F:AD:AE:85:90';
const _unitA = '5A:46:52:00:00:02';
const _unitB = '5A:46:52:00:00:03';

Uint8List _heartbeat({int layer = 2}) => Uint8List.fromList([
      0x68, 0x6E, 0x2F, 0x01, 0x00, 0x00, 0x0E, 0x10,
      0x01, 0x64, 0x00, 0xFA, 0xBE,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x01, layer,
    ]);

Uint8List _alarm({int devSeq = 100}) => Uint8List.fromList([
      0x03, 0x01, 0x68, 0x6E, 0x2F, 0x00,
      0x05, 85, 0x10, 0x68, 0x02, 0x26, 0x2A, 0x00, 0x00,
      (devSeq >> 8) & 0xFF, devSeq & 0xFF,
    ]);

SafrDeviceTableEntry _entry(
  String mac, {
  int productCode = 0,
  int hwRev = 0,
  String fwVersion = '',
}) =>
    SafrDeviceTableEntry(
      mac: mac,
      role: SafrNodeRole.node,
      state: SafrDeviceState.online,
      flags: SafrDeviceFlags.seenEver,
      lastSeenAgeS: 3,
      name: 'Sirene 1',
      zone: 'T',
      productCode: productCode,
      hwRev: hwRev,
      fwVersion: fwVersion,
    );

/// SAFR v3.5: product / hardware revision / firmware version reach the
/// MeshDevices row and are never lost to a frame that does not carry them.
void main() {
  late AppDatabase db;
  late SafrIngestService ingest;
  late SafrEncoder unit;
  late SafrEncoder board;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ingest = SafrIngestService(db: db);
    unit = SafrEncoder(srcMac: safrMacToBytes(_unitA), bootCtr: 7);
    board = SafrEncoder(srcMac: safrMacToBytes(_board), bootCtr: 3);
  });

  tearDown(() => db.close());

  Future<void> feed(Uint8List frame) => ingest.handleFrame(frame, deviceId: 't');

  Future<MeshDevice> row(String mac) =>
      (db.select(db.meshDevices)..where((t) => t.mac.equals(mac))).getSingle();

  Future<void> announce({
    int? productCode,
    int hwRev = 0,
    String fwVersion = '',
    SafrNodeRole? role = SafrNodeRole.node,
  }) =>
      feed(unit.encode(
        msgType: SafrMsgType.nameAnnounce,
        payload: SafrNameAnnouncePayload.build(
          name: 'Sirene 1',
          zone: 'T',
          role: role,
          productCode: productCode,
          hwRev: hwRev,
          fwVersion: fwVersion,
        ),
      ));

  Future<void> table(List<SafrDeviceTableEntry> entries,
          {required bool productFields}) =>
      feed(board.encode(
        msgType: SafrMsgType.deviceTable,
        payload: SafrDeviceTablePayload.build(
          page: 1,
          pageCount: 1,
          total: entries.length,
          entries: entries,
          productFields: productFields,
        ),
      ));

  test('NAME_ANNOUNCE with the extension stores the three values', () async {
    await announce(productCode: 0x0201, hwRev: 2, fwVersion: '0.1.0-dev');
    final r = await row(_unitA);
    expect(r.name, 'Sirene 1');
    expect(r.role, SafrNodeRole.node.wire);
    expect(r.productCode, 0x0201);
    expect(r.hwRev, 2);
    expect(r.fwVersion, '0.1.0-dev');
  });

  test('NAME_ANNOUNCE from older firmware leaves them null', () async {
    await announce();
    final r = await row(_unitA);
    expect(r.name, 'Sirene 1');
    expect(r.productCode, isNull);
    expect(r.hwRev, isNull);
    expect(r.fwVersion, isNull);
  });

  test('later frames that lack the fields do not erase them', () async {
    await announce(productCode: 0x0201, hwRev: 2, fwVersion: '0.1.0-dev');

    Future<void> stillThere(String after) async {
      final r = await row(_unitA);
      expect(r.productCode, 0x0201, reason: after);
      expect(r.hwRev, 2, reason: after);
      expect(r.fwVersion, '0.1.0-dev', reason: after);
    }

    await feed(unit.encode(
        msgType: SafrMsgType.heartbeat, payload: _heartbeat()));
    await stillThere('HEARTBEAT');

    await feed(unit.encode(
        msgType: SafrMsgType.event, payload: _alarm(), ackRequired: true));
    await stillThere('EVENT');
    expect((await row(_unitA)).alarmLatched, 1);

    await announce(); // v3.2 announce: name/zone/role only
    await stillThere('NAME_ANNOUNCE without the extension');

    await announce(role: null); // v3.1 announce
    await stillThere('NAME_ANNOUNCE without ROLE');

    await announce(productCode: 0); // extension present, nothing stated
    await stillThere('NAME_ANNOUNCE with product 0 / hw 0 / empty version');

    await table([_entry(_unitA)], productFields: false);
    await stillThere('DEVICE_TABLE v3.2 page');

    await table([_entry(_unitA)], productFields: true);
    await stillThere('DEVICE_TABLE v3.5 page, board does not know');

    // Journal replay of one of this unit's events (frame from the board).
    await feed(board.encode(
      msgType: SafrMsgType.eventLogData,
      payload: SafrEventLogDataPayload.build(
        jrnSeq: 9,
        logFlags: 0,
        origSrcMac: safrMacToBytes(_unitA),
        eventPayload17: _alarm(devSeq: 101),
      ),
    ));
    await stillThere('EVENT_LOG_DATA');
    expect((await row(_unitA)).lastDevSeq, 101);
  });

  test('a new version replaces the old one (after an update)', () async {
    await announce(productCode: 0x0201, hwRev: 2, fwVersion: '0.1.0-dev');
    await announce(productCode: 0x0201, hwRev: 2, fwVersion: '0.2.0');
    final r = await row(_unitA);
    expect(r.productCode, 0x0201);
    expect(r.fwVersion, '0.2.0');
  });

  test('DEVICE_TABLE v3.5 stores product and version, field by field',
      () async {
    await table([
      _entry(_unitA, productCode: 0x0201, hwRev: 1, fwVersion: '0.1.0'),
      _entry(_unitB, productCode: 0x0206), // newer product, version unknown
    ], productFields: true);

    final a = await row(_unitA);
    expect(a.productCode, 0x0201);
    expect(a.hwRev, 1);
    expect(a.fwVersion, '0.1.0');
    final b = await row(_unitB);
    expect(b.productCode, 0x0206); // kept although not in the catalogue
    expect(b.hwRev, isNull);
    expect(b.fwVersion, isNull);

    // Next sync: the board learned B's version, and only that.
    await table([
      _entry(_unitA),
      _entry(_unitB, fwVersion: '0.3.1'),
    ], productFields: true);
    final a2 = await row(_unitA);
    expect(a2.productCode, 0x0201);
    expect(a2.hwRev, 1);
    expect(a2.fwVersion, '0.1.0');
    final b2 = await row(_unitB);
    expect(b2.productCode, 0x0206);
    expect(b2.fwVersion, '0.3.1');
  });

  test('DEVICE_TABLE from an older board (bit 7 clear) stores nothing',
      () async {
    await table([_entry(_unitA)], productFields: false);
    final r = await row(_unitA);
    expect(r.name, 'Sirene 1');
    expect(r.boardState, SafrDeviceState.online.wire);
    expect(r.productCode, isNull);
    expect(r.hwRev, isNull);
    expect(r.fwVersion, isNull);
  });
}
