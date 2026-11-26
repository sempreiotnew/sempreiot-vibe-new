import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
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
    test('version 2: where the unit went, after the twelve bytes', () {
      // siot_netcore.c report_start(): … ‖ TO(6) ‖ FROM(6) ‖ PATH_BEFORE ‖
      // PATH_AFTER, VERSION 2, 26 bytes.
      final bytes = Uint8List.fromList([
        2, 0, 0, 0, 6, 6, 0, 0, 0, 0, 0, 4, //
        0x5A, 0x46, 0x52, 0, 0, 0x0B, 0x5A, 0x46, 0x52, 0, 0, 0x0A, //
        0xAA, 0xB9,
      ]);
      final p = SafrOutageReportPayload.parse(bytes)!;
      expect(p.cause, SafrOutageCause.moved);
      expect(p.end, SafrOutageEnd.moved);
      expect(p.moveTo, '5A:46:52:00:00:0B');
      expect(p.moveFrom, '5A:46:52:00:00:0A');
      expect(p.pathBefore, -86);
      expect(p.pathAfter, -71);
      expect(p.cleanMove, isTrue);
      expect(p.build(), bytes);

      // The unit it left not known: zeros. Cut short: the twelve bytes.
      final unknown = Uint8List.fromList(bytes)..fillRange(18, 24, 0);
      expect(SafrOutageReportPayload.parse(unknown)!.moveFrom, isNull);
      final cut = SafrOutageReportPayload.parse(bytes.sublist(0, 12))!;
      expect(cut.moveTo, isNull);
      expect(cut.cause, SafrOutageCause.moved);
      expect(cut.describe(),
          'mudou para um dispositivo com sinal melhor · levou 6 s');
    });

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
      final later =
          Uint8List.fromList([2, 0, 0, 0, 45, 3, 0, 1, 0, 0, 0, 1, 9]);
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

    // v3.15: a unit that left its parent for a better path says so.
    const parent = '5A:46:52:00:00:0A';
    const better = '5A:46:52:00:00:0B';
    String nameOf(String mac) =>
        {_unit: 'Sirene 2º andar', parent: 'Hall', better: 'Escada'}[mac] ??
        mac;

    test('a move that worked is news, with the units named', () async {
      await send(const SafrOutageReportPayload(
        duration: Duration(seconds: 6),
        cause: SafrOutageCause.moved,
        end: SafrOutageEnd.moved,
        moveTo: better,
        moveFrom: parent,
        pathBefore: -86,
        pathAfter: -71,
      ));
      final r = await rows();
      expect(r.single.severity, 0);
      final detail = jsonDecode(r.single.detailJson) as Map<String, dynamic>;
      expect(detail['move_to'], better);
      expect(detail['move_from'], parent);
      expect(detail['path_before'], -86);
      expect(acked, hasLength(1));

      final line = panelEventOf(r.single, nameOf)!;
      expect(line.kind, PanelEventKind.info);
      expect(
          line.text,
          'Sirene 2º andar — mudou de Hall para Escada, por um sinal melhor '
          '(-86 para -71 dBm) · levou 6 s');
      expect(line.outage!.cause, 6);
      expect(line.outage!.end, 4);
    });

    test('a move that came back by another unit, with no restart, is news',
        () async {
      await send(const SafrOutageReportPayload(
        duration: Duration(seconds: 44),
        cause: SafrOutageCause.moved,
        rescues: 1,
        end: SafrOutageEnd.rescued,
        moveTo: better,
        moveFrom: parent,
        pathBefore: -86,
        pathAfter: -71,
      ));
      final r = await rows();
      expect(r.single.severity, 0);
      expect(panelEventOf(r.single, nameOf)!.kind, PanelEventKind.info);
    });

    test('a move that went wrong is a trouble that says it left by itself',
        () async {
      await send(const SafrOutageReportPayload(
        duration: Duration(seconds: 134),
        cause: SafrOutageCause.moved,
        flags: 0x04,
        rescues: 1,
        restarts: 1,
        moveTo: better,
        moveFrom: parent,
        pathBefore: -86,
        pathAfter: -71,
      ));
      final r = await rows();
      expect(r.single.severity, 1);
      final line = panelEventOf(r.single, nameOf)!;
      expect(line.kind, PanelEventKind.trouble);
      expect(
          line.text,
          'Sirene 2º andar — ficou 2 min 14 s sem caminho até a central · '
          'saiu de Hall para Escada, por um sinal melhor (-86 para -71 dBm) · '
          '1 tentativa de religar por outro dispositivo · '
          'reiniciou sozinho 1 vez · '
          'não ligou nele e voltou por outro caminho');
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
