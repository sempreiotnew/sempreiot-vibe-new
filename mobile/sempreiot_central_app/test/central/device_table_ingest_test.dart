import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
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
      onAckReceived: (ack, _) => acks.add(ack),
      onCode: codes.add,
      setupIdentity: () => setup,
    );
    boardEnc = SafrEncoder(srcMac: safrMacToBytes(_board), bootCtr: 3);
  });

  tearDown(() => db.close());

  Future<void> feed(Uint8List frame) =>
      ingest.handleFrame(frame, deviceId: 't');

  group('DEVICE_TABLE ingest (spec §7.12, lifecycle §3)', () {
    test('mirrors state, flags and name into MeshDevices', () async {
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
          ),
          SafrDeviceTableEntry(
            mac: _unitB,
            role: SafrNodeRole.unknown,
            state: SafrDeviceState.expected,
            flags: 0,
            lastSeenAgeS: null,
            name: 'Detector 2',
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
      expect(a.registryState, 'enrolled'); // never heard live by this tablet
      final b = rows.firstWhere((r) => r.mac == _unitB);
      expect(b.boardState, SafrDeviceState.expected.wire);
      // The board itself is not registered from its own reply.
      expect(rows.any((r) => r.mac == _board), isFalse);
    });

    test('a live unit keeps its live state; unlisted board rows are pruned',
        () async {
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
              mac: _unitA,
              role: SafrNodeRole.node,
              state: SafrDeviceState.online,
              flags: 1,
              lastSeenAgeS: 1,
              name: 'Sirene 1'),
          SafrDeviceTableEntry(
              mac: _unitB,
              role: SafrNodeRole.unknown,
              state: SafrDeviceState.expected,
              flags: 0,
              lastSeenAgeS: null,
              name: 'Velho'),
        ]),
      ));
      expect((await db.select(db.meshDevices).get()).length, 2);

      // Next sync: the board forgot B.
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, total: 1, entries: const [
          SafrDeviceTableEntry(
              mac: _unitA,
              role: SafrNodeRole.node,
              state: SafrDeviceState.missing,
              flags: 1,
              lastSeenAgeS: 90,
              name: 'Sirene 1'),
        ]),
      ));
      final rows = await db.select(db.meshDevices).get();
      expect(rows.map((r) => r.mac), [_unitA]);
      expect(rows.single.registryState, isNull); // still live
      expect(rows.single.boardState, SafrDeviceState.missing.wire);
    });
  });

  group('v3.8 labels (protocol §14.1 / §14.2)', () {
    test('LABEL_TABLE pages replace the kind\'s copy; format 2 ids reach the row',
        () async {
      Uint8List labels(SafrLabelKind kind, int page, int pageCount,
              List<SafrLabel> rows) =>
          boardEnc.encode(
            msgType: SafrMsgType.labelTable,
            payload: SafrLabelTablePayload.build(
                kind: kind,
                page: page,
                pageCount: pageCount,
                total: rows.length,
                rev: 3,
                labels: rows),
          );
      await feed(labels(SafrLabelKind.zone, 1, 2,
          const [SafrLabel(id: 1, name: 'Portões')]));
      await feed(labels(SafrLabelKind.zone, 2, 2,
          const [SafrLabel(id: 2, name: 'Térreo')]));
      await feed(labels(SafrLabelKind.address, 1, 1,
          const [SafrLabel(id: 7, name: '1º andar')]));
      var rows = await db.select(db.deviceLabels).get();
      expect(
          {for (final r in rows) (r.kind, r.labelId): r.name},
          {(1, 1): 'Portões', (1, 2): 'Térreo', (2, 7): '1º andar'});

      // The board renamed one and dropped one: the copy follows exactly.
      await feed(labels(SafrLabelKind.zone, 1, 1,
          const [SafrLabel(id: 2, name: 'Garagem')]));
      rows = await db.select(db.deviceLabels).get();
      expect({for (final r in rows) (r.kind, r.labelId): r.name},
          {(1, 2): 'Garagem', (2, 7): '1º andar'});

      // Format 2 entry: ids and link land on the unit's row.
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: SafrDeviceTablePayload.build(
          page: 1,
          pageCount: 1,
          total: 1,
          productFields: true,
          labelFields: true,
          entries: const [
            SafrDeviceTableEntry(
                mac: _unitA,
                role: SafrNodeRole.node,
                state: SafrDeviceState.online,
                flags: 1,
                lastSeenAgeS: 1,
                name: 'Sirene 1',
                zoneId: 2,
                addressId: 7,
                linkKind: safrLinkIsland),
          ],
        ),
      ));
      final a = (await db.select(db.meshDevices).get()).single;
      expect(a.zoneId, 2);
      expect(a.addressId, 7);
      expect(a.linkKind, safrLinkIsland);
      expect(await db.countUnitsWithLabel(1, 2), 1);
      expect(await db.countUnitsWithLabel(2, 1), 0);

      // A v3.5 page (no label fields) leaves the ids alone.
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, total: 1, entries: const [
          SafrDeviceTableEntry(
              mac: _unitA,
              role: SafrNodeRole.node,
              state: SafrDeviceState.online,
              flags: 1,
              lastSeenAgeS: 1,
              name: 'Sirene 1'),
        ]),
      ));
      final again = (await db.select(db.meshDevices).get()).single;
      expect(again.zoneId, 2);
      expect(again.addressId, 7);
    });
  });

  group('Sincronizar com a placa (2026-10-08)', () {
    test('a unit the tablet heard keeps its name when the board forgets it',
        () async {
      // The unit named itself to this tablet; the board's table listed it.
      final unitEnc = SafrEncoder(srcMac: safrMacToBytes(_unitA), bootCtr: 7);
      await feed(unitEnc.encode(
        msgType: SafrMsgType.nameAnnounce,
        payload: SafrNameAnnouncePayload.build(name: 'Sirene Hall', zone: 'T'),
      ));
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, total: 1, entries: const [
          SafrDeviceTableEntry(
              mac: _unitA,
              role: SafrNodeRole.node,
              state: SafrDeviceState.online,
              flags: 1,
              lastSeenAgeS: 1,
              name: 'Sirene Hall'),
        ]),
      ));
      // The board was erased (or never heard it): an empty table. The old
      // code dropped the row here; the unit came back from its heartbeat
      // as a bare MAC.
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, total: 0, entries: const []),
      ));
      final rows = await db.select(db.meshDevices).get();
      expect(rows.map((r) => r.mac), [_unitA]);
      expect(rows.single.name, 'Sirene Hall');
      expect(rows.single.boardState, isNull, reason: 'the board forgot it');
      // A table that names nothing never overwrites a name either.
      await feed(boardEnc.encode(
        msgType: SafrMsgType.deviceTable,
        payload: _tablePage(page: 1, pageCount: 1, total: 1, entries: const [
          SafrDeviceTableEntry(
              mac: _unitA,
              role: SafrNodeRole.node,
              state: SafrDeviceState.online,
              flags: 1,
              lastSeenAgeS: 1,
              name: ''),
        ]),
      ));
      expect(
          (await db.select(db.meshDevices).get()).single.name, 'Sirene Hall');
    });

    test('the silent prune: only unlisted AND silent, never on an empty table',
        () async {
      final now = DateTime.now().toUtc();
      Future<void> row(String mac, Duration ago) =>
          db.into(db.meshDevices).insert(MeshDevicesCompanion.insert(
                mac: mac,
                role: const Value(1),
                layer: const Value(1),
                firstSeenAt: now,
                lastSeenAt: now.subtract(ago),
              ));
      await row(_unitA, const Duration(seconds: 10)); // heard just now
      await row(_unitB, const Duration(minutes: 20)); // long silent
      final before = now.subtract(const Duration(minutes: 5));
      expect(await db.pruneUnlistedSilentRows(const {}, before), 0);
      expect((await db.select(db.meshDevices).get()).length, 2);
      expect(await db.pruneUnlistedSilentRows(const {'other'}, before), 1);
      expect((await db.select(db.meshDevices).get()).single.mac, _unitA);
    });
  });

  group('setup channel (spec §3.1 v3.2)', () {
    test('ACK and CODE under SYSTEM_ID 0 are accepted only while open',
        () async {
      final key = ProvisioningCrypto.deriveSetupKey(
          id: 'dev-1', pop: '0123456789ABCDEF');
      final setupEnc = SafrEncoder(
          srcMac: safrMacToBytes(_board), bootCtr: 2, systemId: 0, key: key);
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
          msgType: SafrMsgType.code,
          payload: code.build(),
          dstMac: safrCentralMacBytes);
      final ackFrame = setupEnc.encode(
          msgType: SafrMsgType.ack,
          payload: SafrAckPayload.build(
              ackedMsgId: 9,
              detail: SafrAckDetail.notInSetupMode,
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
