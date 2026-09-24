import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/services/provisioning_crypto.dart';

const _board = '7C:4F:AD:AE:85:90';
const _unitA = '5A:46:52:00:00:02';
const _unitB = '5A:46:52:00:00:03';

Uint8List _tablePage({
  required int page,
  required int pageCount,
  required List<SafrDeviceTableEntry> entries,
  int total = 2,
}) =>
    SafrDeviceTablePayload.build(
        page: page, pageCount: pageCount, total: total, entries: entries);

void main() {
  late AppDatabase db;
  late SafrIngestService ingest;
  late SafrEncoder boardEnc;
  SafrIdentity? setup;
  final acks = <SafrAckPayload>[];
  final codes = <SafrInstallationCode>[];

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    acks.clear();
    codes.clear();
    setup = null;
    ingest = SafrIngestService(
      db: db,
      onAckReceived: acks.add,
      onCode: codes.add,
      setupIdentity: () => setup,
    );
    boardEnc = SafrEncoder(srcMac: safrMacToBytes(_board), bootCtr: 3);
  });

  tearDown(() => db.close());

  Future<void> feed(Uint8List frame) => ingest.handleFrame(frame, deviceId: 't');

  group('DEVICE_TABLE ingest (spec §7.12, lifecycle §3)', () {
    test('mirrors state, flags, name and zone into MeshDevices', () async {
      final frame = boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, entries: const [
          SafrDeviceTableEntry(
            mac: _unitA,
            role: SafrNodeRole.node,
            state: SafrDeviceState.online,
            flags: SafrDeviceFlags.seenEver | SafrDeviceFlags.annotated,
            lastSeenAgeS: 5,
            name: 'Sirene 1',
            zone: 'Térreo',
          ),
          SafrDeviceTableEntry(
            mac: _unitB,
            role: SafrNodeRole.unknown,
            state: SafrDeviceState.expected,
            flags: 0,
            lastSeenAgeS: null,
            name: 'Detector 2',
            zone: '1º andar',
          ),
        ]),
      );
      await feed(frame);
      final rows = await db.select(db.meshDevices).get();
      expect(rows.length, 2);
      final a = rows.firstWhere((r) => r.mac == _unitA);
      expect(a.boardState, SafrDeviceState.online.wire);
      expect(a.boardFlags & SafrDeviceFlags.annotated, isNot(0));
      expect(a.name, 'Sirene 1');
      expect(a.zone, 'Térreo');
      expect(a.registryState, 'enrolled'); // never heard live by this tablet
      final b = rows.firstWhere((r) => r.mac == _unitB);
      expect(b.boardState, SafrDeviceState.expected.wire);
      // The board itself is not registered from its own reply.
      expect(rows.any((r) => r.mac == _board), isFalse);
    });

    test('a live unit keeps its live state; unlisted board rows are pruned', () async {
      // Unit A speaks first (live), unit B only ever came from an old table.
      final unitEnc = SafrEncoder(srcMac: safrMacToBytes(_unitA), bootCtr: 7);
      await feed(unitEnc.encode(
        msgType: SafrMsgType.nameAnnounce,
        payload: SafrNameAnnouncePayload.build(name: 'Sirene 1', zone: 'T'),
      ));
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, entries: const [
          SafrDeviceTableEntry(
              mac: _unitA, role: SafrNodeRole.node, state: SafrDeviceState.online,
              flags: 1, lastSeenAgeS: 1, name: 'Sirene 1', zone: 'T'),
          SafrDeviceTableEntry(
              mac: _unitB, role: SafrNodeRole.unknown, state: SafrDeviceState.expected,
              flags: 0, lastSeenAgeS: null, name: 'Velho', zone: ''),
        ]),
      ));
      expect((await db.select(db.meshDevices).get()).length, 2);

      // Next sync: the board forgot B.
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, total: 1, entries: const [
          SafrDeviceTableEntry(
              mac: _unitA, role: SafrNodeRole.node, state: SafrDeviceState.missing,
              flags: 1, lastSeenAgeS: 90, name: 'Sirene 1', zone: 'T'),
        ]),
      ));
      final rows = await db.select(db.meshDevices).get();
      expect(rows.map((r) => r.mac), [_unitA]);
      expect(rows.single.registryState, isNull); // still live
      expect(rows.single.boardState, SafrDeviceState.missing.wire);
    });
  });

  group('setup channel (spec §3.1 v3.2)', () {
    test('ACK and CODE under SYSTEM_ID 0 are accepted only while open', () async {
      final key = ProvisioningCrypto.deriveSetupKey(id: 'dev-1', pop: '0123456789ABCDEF');
      final setupEnc = SafrEncoder(srcMac: safrMacToBytes(_board), bootCtr: 2, systemId: 0, key: key);
      final code = SafrInstallationCode(
        systemId: 0x1234,
        channel: 6,
        meshId: 0x34,
        netSsid: 'SIOT-1234',
        netPsk: 'QR2heszWr0mJjaDd',
        safrPsk: Uint8List.fromList(List.generate(16, (i) => i)),
        name: 'Galpao',
      );
      final codeFrame = setupEnc.encode(
          msgType: SafrMsgType.code, payload: code.build(), dstMac: safrCentralMacBytes);
      final ackFrame = setupEnc.encode(
          msgType: SafrMsgType.ack,
          payload: SafrAckPayload.build(ackedMsgId: 9, detail: SafrAckDetail.notInSetupMode,
              status: SafrAckStatus.error),
          dstMac: safrCentralMacBytes);

      // Closed: foreign, nothing delivered.
      await feed(codeFrame);
      expect(codes, isEmpty);

      setup = SafrIdentity(systemId: 0, key: key);
      await feed(codeFrame);
      await feed(ackFrame);
      expect(codes.single.systemId, 0x1234);
      expect(codes.single.netPsk, 'QR2heszWr0mJjaDd');
      expect(acks.single.detail, SafrAckDetail.notInSetupMode);

      // Wrong key: still foreign.
      codes.clear();
      setup = SafrIdentity(systemId: 0, key: Uint8List(16));
      await feed(codeFrame);
      expect(codes, isEmpty);
    });
  });
}
