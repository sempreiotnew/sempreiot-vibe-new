import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_events_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// The rollout's frames through the ingest pipeline (protocol §13.4, §13.6):
/// what is handed to the rollout, what is acknowledged, what is registered.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const boardMac = '7C:4F:AD:AE:85:90';
  const unitMac = '5A:46:52:00:00:02';

  late AppDatabase db;
  late SafrIngestService ingest;
  late List<OtaRolloutEvent> events;
  late List<SafrWireFrame> acked;
  late List<SafrAckPayload> confirmed;
  late List<(String, SafrMsgType)> traffic;

  SafrEncoder encoder(String mac, {int bootCtr = 5}) =>
      SafrEncoder(srcMac: safrMacToBytes(mac), bootCtr: bootCtr);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    events = [];
    acked = [];
    confirmed = [];
    traffic = [];
    ingest = SafrIngestService(
      db: db,
      onOtaRolloutEvent: events.add,
      onAckRequired: (f) async => acked.add(f),
      onAckReceived: confirmed.add,
      onTraffic: (mac, severity, parentMac, msgType, eventCode, uptimeS) =>
          traffic.add((mac, msgType)),
    );
  });

  tearDown(() => db.close());

  Future<void> feed(Uint8List frame) =>
      ingest.handleFrame(frame, deviceId: 't');

  test('OTA_ROLLOUT: handed over, the board is not registered by it',
      () async {
    await feed(encoder(boardMac).encode(
      msgType: SafrMsgType.otaRollout,
      payload: const SafrOtaRolloutPayload(
        page: 1,
        pageCount: 1,
        total: 0,
        state: SafrOtaRolloutState.staged,
        family: 0x02,
        target: '0.1.1',
      ).build(),
      dstMac: safrCentralMacBytes,
    ));

    final page = (events.single as OtaRolloutPageEvent).page;
    expect(page.state, SafrOtaRolloutState.staged);
    expect(page.target, '0.1.1');
    expect(acked, isEmpty);
    expect(await db.select(db.meshDevices).get(), isEmpty);
    // The board put a frame on the link: its LED ticked.
    expect(traffic.single, (boardMac, SafrMsgType.otaRollout));
  });

  test('OTA_STATUS: handed over with the unit\'s MAC, the unit was heard',
      () async {
    await feed(encoder(unitMac).encode(
      msgType: SafrMsgType.otaStatus,
      payload: const SafrOtaStatusPayload(
        state: SafrOtaUnitState.downloading,
        percent: 40,
      ).build(),
    ));

    final e = events.single as OtaUnitStatusEvent;
    expect(e.mac, unitMac);
    expect(e.status.state, SafrOtaUnitState.downloading);
    expect(e.status.percent, 40);
    expect(acked, isEmpty, reason: 'never acknowledged');
    final row = (await db.select(db.meshDevices).get()).single;
    expect(row.mac, unitMac);
    expect(DateTime.now().toUtc().difference(row.lastSeenAt).inSeconds,
        lessThan(5));
    expect(traffic.single, (unitMac, SafrMsgType.otaStatus));
  });

  test('OTA_RESULT: acknowledged every time, handed over once', () async {
    final unit = encoder(unitMac);
    final payload =
        const SafrOtaResultPayload(ok: true, version: '0.2.0').build();
    Uint8List result() => unit.encode(
          msgType: SafrMsgType.otaResult,
          payload: payload,
          ackRequired: true,
          msgId: 77,
        );

    await feed(result());
    // The unit repeats it under the same MSG_ID until somebody answers.
    await feed(result());
    await feed(result());

    expect(events, hasLength(1));
    final e = events.single as OtaUnitResultEvent;
    expect(e.mac, unitMac);
    expect(e.result.ok, isTrue);
    expect(e.result.version, '0.2.0');
    expect(acked, hasLength(3));
    expect(acked.every((f) => f.srcMac == unitMac && f.msgId == 77), isTrue);
  });

  test('a replay of an OTA_STATUS is not handed over', () async {
    final frame = encoder(unitMac).encode(
      msgType: SafrMsgType.otaStatus,
      payload: const SafrOtaStatusPayload(
        state: SafrOtaUnitState.rebooting,
        percent: 100,
      ).build(),
    );
    await feed(frame);
    await feed(frame); // the same bytes: same counters
    expect(events, hasLength(1));
  });

  test('a unit that restarted counts its MSG_IDs from the start again',
      () async {
    Uint8List status(int bootCtr, SafrOtaUnitState s) =>
        encoder(unitMac, bootCtr: bootCtr).encode(
          msgType: SafrMsgType.otaStatus,
          payload: SafrOtaStatusPayload(state: s, percent: 100).build(),
          msgId: 1,
        );
    await feed(status(5, SafrOtaUnitState.rebooting));
    // The new image, seconds later: MSG_ID 1 of another boot.
    await feed(status(6, SafrOtaUnitState.selfTest));

    expect(events, hasLength(2));
    expect((events.last as OtaUnitStatusEvent).status.state,
        SafrOtaUnitState.selfTest);
  });

  test('a payload that is not one is dropped, not handed over', () async {
    await feed(encoder(unitMac).encode(
      msgType: SafrMsgType.otaStatus,
      payload: Uint8List.fromList([2, 101]),
    ));
    expect(events, isEmpty);
    expect(await db.select(db.meshDevices).get(), isEmpty);
  });

  group('an ACK', () {
    Uint8List ack(String from, Uint8List to, int msgId) =>
        encoder(from).encode(
          msgType: SafrMsgType.ack,
          payload: SafrAckPayload.build(ackedMsgId: msgId),
          dstMac: to,
        );

    test('addressed to the tablet confirms the tablet\'s frame', () async {
      await feed(ack(boardMac, safrCentralMacBytes, 41));
      expect(confirmed.single.ackedMsgId, 41);
    });

    test('of a unit to the board (its answer to OTA_OFFER) confirms nothing '
        'of the tablet\'s', () async {
      await feed(ack(unitMac, safrMacToBytes(boardMac), 41));
      expect(confirmed, isEmpty,
          reason: 'MSG_ID 41 of the board is not MSG_ID 41 of the tablet');
      // The unit put a frame on the link all the same: its LED pulsed.
      expect(traffic.single, (unitMac, SafrMsgType.ack));
    });

    test('to everybody still counts (older firmware)', () async {
      await feed(ack(boardMac, safrBroadcastMacBytes, 9));
      expect(confirmed.single.ackedMsgId, 9);
    });
  });
}
