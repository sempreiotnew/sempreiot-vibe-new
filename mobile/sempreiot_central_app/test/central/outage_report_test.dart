import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/panel_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

const _unit = '5A:46:52:00:00:02';

/// OUTAGE_REPORT (protocol §7.17, v3.14): a unit that had no path to the
/// central says what happened once it is back, and the tablet keeps it as
/// one line of the unit's history.
void main() {
  group('payload', () {
    test('the twelve bytes the firmware sends are read field by field', () {
      // siot_netcore.c: VER ‖ DURATION_S u32 ‖ CAUSE ‖ FLAGS ‖ RESCUES ‖
      // RESCUES_MISSED ‖ ANY_ROUNDS ‖ RESTARTS ‖ END.
      final p = SafrOutageReportPayload.parse(Uint8List.fromList(
          [1, 0x00, 0x00, 0x1C, 0x20, 2, 0x05, 3, 2, 1, 1, 1]))!;
      expect(p.duration, const Duration(hours: 2));
      expect(p.cause, SafrOutageCause.parentLost);
      expect(p.heldRootRole, isTrue);
      expect(p.underPathlessParent, isFalse);
      expect(p.attachedToNothing, isTrue);
      expect(p.rescues, 3);
      expect(p.rescuesMissed, 2);
      expect(p.anyRounds, 1);
      expect(p.restarts, 1);
      expect(p.end, SafrOutageEnd.rescued);
      expect(p.build(), [1, 0x00, 0x00, 0x1C, 0x20, 2, 0x05, 3, 2, 1, 1, 1]);
    });

    test('a short payload is not a report; a longer, later one still is', () {
      expect(SafrOutageReportPayload.parse(Uint8List(11)), isNull);
      final later = Uint8List.fromList([2, 0, 0, 0, 45, 3, 0, 1, 0, 0, 0, 1, 9]);
      expect(SafrOutageReportPayload.parse(later)!.duration,
          const Duration(seconds: 45));
    });

    test('the line says how long, why, what it took and how it came back', () {
      const p = SafrOutageReportPayload(
        duration: Duration(minutes: 3, seconds: 10),
        cause: SafrOutageCause.parentLost,
        rescues: 2,
        rescuesMissed: 1,
        restarts: 1,
        end: SafrOutageEnd.rescued,
      );
      expect(
          p.describe(),
          'ficou 3 min 10 s sem caminho até a central · '
          'o dispositivo ao qual estava ligado saiu do ar · '
          '2 tentativas de religar por outro dispositivo, 1 sem sucesso · '
          'reiniciou sozinho 1 vez · voltou por outro dispositivo');
      const short = SafrOutageReportPayload(
        duration: Duration(seconds: 25),
        cause: SafrOutageCause.unknown,
      );
      expect(short.describe(), 'ficou 25 s sem caminho até a central · voltou');
    });
  });

  group('ingest', () {
    late AppDatabase db;
    late SafrIngestService ingest;
    late SafrEncoder unit;
    final acked = <SafrWireFrame>[];

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      acked.clear();
      ingest = SafrIngestService(
        db: db,
        onAckRequired: (frame) async => acked.add(frame),
      );
      unit = SafrEncoder(srcMac: safrMacToBytes(_unit), bootCtr: 7);
    });

    tearDown(() => db.close());

    const report = SafrOutageReportPayload(
      duration: Duration(minutes: 4),
      cause: SafrOutageCause.parentSilent,
      flags: 0x02,
      rescues: 1,
      end: SafrOutageEnd.rescued,
    );

    Future<void> send(SafrOutageReportPayload p, {int? msgId}) =>
        ingest.handleFrame(
          unit.encode(
            msgType: SafrMsgType.outageReport,
            payload: p.build(),
            ackRequired: true,
            msgId: msgId,
          ),
          deviceId: 't',
        );

    Future<List<DeviceEvent>> rows() => (db.select(db.deviceEvents)
          ..where((t) => t.msgType.equals(SafrMsgType.outageReport.wire)))
        .get();

    test('one row in the history, in words, and the frame is ACKed', () async {
      await send(report);
      final r = await rows();
      expect(r, hasLength(1));
      expect(r.single.deviceMac, _unit);
      expect(r.single.severity, 1);
      final detail = jsonDecode(r.single.detailJson) as Map<String, dynamic>;
      expect(detail['kind'], 'outage');
      expect(detail['duration_s'], 240);
      expect(detail['cause'], 3);
      expect(detail['rescues'], 1);
      expect(acked, hasLength(1));

      final line = panelEventOf(r.single, (mac) => 'Sirene 2º andar')!;
      expect(
          line.text,
          'Sirene 2º andar — ficou 4 min sem caminho até a central · '
          'o dispositivo ao qual estava ligado ficou sem caminho · '
          '1 tentativa de religar por outro dispositivo · '
          'voltou por outro dispositivo');
    });

    test('the unit repeating it until the ACK arrives adds nothing', () async {
      await send(report, msgId: 40);
      await send(report, msgId: 40); // fast retry: same MSG_ID
      await send(report, msgId: 41); // a later copy, as after a restart
      expect(await rows(), hasLength(1));
      expect(acked, hasLength(3)); // ACK every time (spec §9.1)
    });

    test('another outage of the same unit is another row', () async {
      await send(report);
      await send(const SafrOutageReportPayload(
        duration: Duration(seconds: 50),
        cause: SafrOutageCause.parentLost,
        rescues: 1,
        end: SafrOutageEnd.rescued,
      ));
      expect(await rows(), hasLength(2));
    });
  });
}
