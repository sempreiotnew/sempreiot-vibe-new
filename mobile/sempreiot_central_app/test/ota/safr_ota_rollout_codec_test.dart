import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// Protocol §13.4 / §13.6 (v3.5): the rollout. The vectors are the ones of
/// the firmware's host tests (firmware/test/host/main/test_ota_proto.c,
/// cases "OTA_OFFER args, OTA_STATUS, OTA_RESULT", "OTA_CONTROL filters" and
/// "OTA_ROLLOUT page, header and entries"): a layout that changes on one side
/// and not on the other fails here.
void main() {
  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  group('numbers', () {
    test('unit STATE', () {
      expect([for (final s in SafrOtaUnitState.values) s.wire],
          [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(SafrOtaUnitState.fromWire(2), SafrOtaUnitState.downloading);
      expect(SafrOtaUnitState.fromWire(5), SafrOtaUnitState.selfTest);
      expect(SafrOtaUnitState.fromWire(9), isNull);
    });

    test('updating = offered … self-test, settled = done / failed / skipped',
        () {
      expect(
        [
          for (final s in SafrOtaUnitState.values)
            if (s.active) s
        ],
        [
          SafrOtaUnitState.offered,
          SafrOtaUnitState.downloading,
          SafrOtaUnitState.verifying,
          SafrOtaUnitState.rebooting,
          SafrOtaUnitState.selfTest,
        ],
      );
      expect(
        [
          for (final s in SafrOtaUnitState.values)
            if (s.settled) s
        ],
        [
          SafrOtaUnitState.done,
          SafrOtaUnitState.failed,
          SafrOtaUnitState.skipped,
        ],
      );
    });

    test('rollout STATE', () {
      expect([for (final s in SafrOtaRolloutState.values) s.wire],
          [0, 1, 2, 3, 4, 5]);
      expect(SafrOtaRolloutState.fromWire(5), SafrOtaRolloutState.partial);
      expect(SafrOtaRolloutState.fromWire(6), isNull);
      expect(SafrOtaRolloutState.rolling.running, isTrue);
      expect(SafrOtaRolloutState.paused.running, isTrue);
      expect(SafrOtaRolloutState.staged.running, isFalse);
      expect(SafrOtaRolloutState.partial.ended, isTrue);
    });

    test('ACTION, FILTER and the commands', () {
      expect([for (final a in SafrOtaAction.values) a.wire], [1, 2, 3, 4]);
      expect([for (final k in SafrOtaFilterKind.values) k.wire], [0, 1, 2, 3]);
      expect(SafrCommand.getRollout.wire, 0x1C);
      expect(SafrCommand.otaControl.wire, 0x1D);
      expect(SafrCommand.getRollout.isBoardOnly, isTrue);
      expect(SafrCommand.otaControl.isBoardOnly, isTrue);
    });
  });

  group('OTA_STATUS', () {
    test('downloading 40 %', () {
      final p = const SafrOtaStatusPayload(
        state: SafrOtaUnitState.downloading,
        percent: 40,
      ).build();
      expect(p, [2, 40]);
      final back = SafrOtaStatusPayload.parse(p)!;
      expect(back.state, SafrOtaUnitState.downloading);
      expect(back.percent, 40);
    });

    test('a percent over 100 is written as 100', () {
      expect(
        const SafrOtaStatusPayload(
          state: SafrOtaUnitState.downloading,
          percent: 130,
        ).build(),
        [2, 100],
      );
    });

    test('refused: percent 101, a state that does not exist, 1 byte, 3 bytes',
        () {
      expect(SafrOtaStatusPayload.parse(bytes([2, 101])), isNull);
      expect(SafrOtaStatusPayload.parse(bytes([9, 0])), isNull);
      expect(SafrOtaStatusPayload.parse(bytes([2])), isNull);
      expect(SafrOtaStatusPayload.parse(bytes([2, 40, 0])), isNull);
    });
  });

  group('OTA_RESULT', () {
    // {.ok = false, .reason = SELFTEST_FAIL, .awake_s = 62, "0.1.0"}
    const want = [0x00, 0x09, 0x00, 0x3E, 0x05, 0x30, 0x2E, 0x31, 0x2E, 0x30];

    test('layout', () {
      final p = const SafrOtaResultPayload(
        ok: false,
        reasonRaw: 9,
        awakeS: 62,
        version: '0.1.0',
      ).build();
      expect(p, want);
    });

    test('round trip', () {
      final r = SafrOtaResultPayload.parse(bytes(want))!;
      expect(r.ok, isFalse);
      expect(r.reason, SafrOtaReason.selftestFail);
      expect(r.awakeS, 62);
      expect(r.version, '0.1.0');
    });

    test('ok, on a mains unit', () {
      final p = const SafrOtaResultPayload(ok: true, version: '0.2.0').build();
      expect(p, [0x01, 0x00, 0x00, 0x00, 0x05, ...ascii.encode('0.2.0')]);
      final r = SafrOtaResultPayload.parse(p)!;
      expect(r.ok, isTrue);
      expect(r.reason, SafrOtaReason.none);
      expect(r.awakeS, 0);
    });

    test('DETAIL: one trailing byte, the reset reason with NOT_VALIDATED', () {
      final p = const SafrOtaResultPayload(
        ok: false,
        reasonRaw: 18,
        version: '0.1.0',
        detail: 4,
      ).build();
      expect(p, [0x00, 18, 0, 0, 0x05, ...ascii.encode('0.1.0'), 4]);
      final r = SafrOtaResultPayload.parse(p)!;
      expect(r.reason, SafrOtaReason.notValidated);
      expect(r.detail, 4);
      expect(r.version, '0.1.0');
      expect(SafrOtaResultPayload.parse(bytes(want))!.detail, 0);
    });

    test('refused: two bytes more, OK = 2, short', () {
      expect(SafrOtaResultPayload.parse(bytes([...want, 0, 0])), isNull);
      expect(SafrOtaResultPayload.parse(bytes([2, ...want.sublist(1)])),
          isNull);
      expect(SafrOtaResultPayload.parse(bytes(want.sublist(0, 4))), isNull);
      expect(SafrOtaResultPayload.parse(bytes(want.sublist(0, 9))), isNull);
    });
  });

  group('OTA_CONTROL', () {
    test('"only the sirens": start, node image, product 0x0201', () {
      final p = const SafrOtaControlArgs(
        action: SafrOtaAction.start,
        family: 0x02,
        filter: SafrOtaFilter.product(0x0201),
      ).build();
      expect(p, [0x01, 0x02, 0x01, 0x02, 0x01]);
      final back = SafrOtaControlArgs.parse(p)!;
      expect(back.action, SafrOtaAction.start);
      expect(back.family, 0x02);
      expect(back.filter, const SafrOtaFilter.product(0x0201));
    });

    test('a product of another family, or none, is refused', () {
      expect(SafrOtaControlArgs.parse(bytes([0x01, 0x03, 0x01, 0x02, 0x01])),
          isNull);
      expect(SafrOtaControlArgs.parse(bytes([0x01, 0x02, 0x01, 0x00, 0x00])),
          isNull);
      expect(SafrOtaControlArgs.parse(bytes([0x01, 0x02, 0x01, 0x02])), isNull);
    });

    test('pause: three bytes', () {
      final p = const SafrOtaControlArgs(
        action: SafrOtaAction.pause,
        family: 0x02,
      ).build();
      expect(p, [0x02, 0x02, 0x00]);
      expect(SafrOtaControlArgs.parse(p)!.filter, const SafrOtaFilter.all());
      expect(SafrOtaControlArgs.parse(bytes([...p, 0])), isNull);
      expect(SafrOtaControlArgs.parse(bytes([0, 0x02, 0x00])), isNull);
      expect(SafrOtaControlArgs.parse(bytes([5, 0x02, 0x00])), isNull);
      expect(SafrOtaControlArgs.parse(bytes([2, 0x00, 0x00])), isNull);
      expect(SafrOtaControlArgs.parse(bytes([2, 0x02])), isNull);
    });

    test('resume and abort', () {
      expect(
        const SafrOtaControlArgs(action: SafrOtaAction.resume, family: 0x02)
            .build(),
        [0x03, 0x02, 0x00],
      );
      expect(
        const SafrOtaControlArgs(action: SafrOtaAction.abort, family: 0x02)
            .build(),
        [0x04, 0x02, 0x00],
      );
    });

    test('a zone: length in bytes, UTF-8', () {
      final p = const SafrOtaControlArgs(
        action: SafrOtaAction.start,
        family: 0x03,
        filter: SafrOtaFilter.zone('Térreo'),
      ).build();
      // "Térreo" is 7 bytes.
      expect(p, [0x01, 0x03, 0x02, 7, ...utf8.encode('Térreo')]);
      expect(SafrOtaControlArgs.parse(p)!.filter.zone, 'Térreo');
      // An empty zone.
      expect(SafrOtaControlArgs.parse(bytes([0x01, 0x03, 0x02, 0])), isNull);
      // A length that runs past the end.
      expect(SafrOtaControlArgs.parse(bytes([0x01, 0x03, 0x02, 7, 0x54])),
          isNull);
    });

    test('a zone longer than 16 bytes is never sent', () {
      expect(
        () => const SafrOtaControlArgs(
          action: SafrOtaAction.start,
          family: 0x02,
          filter: SafrOtaFilter.zone('Depósito dos fundos'),
        ).build(),
        throwsArgumentError,
      );
    });

    test('one unit, never broadcast', () {
      const mac = '80:45:6B:72:E3:30';
      final p = const SafrOtaControlArgs(
        action: SafrOtaAction.start,
        family: 0x03,
        filter: SafrOtaFilter.unit(mac),
      ).build();
      expect(p.length, 9);
      expect(p, [0x01, 0x03, 0x03, 0x80, 0x45, 0x6B, 0x72, 0xE3, 0x30]);
      expect(SafrOtaControlArgs.parse(p)!.filter.mac, mac);
      expect(
        SafrOtaControlArgs.parse(
            bytes([0x01, 0x03, 0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),
        isNull,
      );
      // FILTER 4 does not exist.
      expect(
        SafrOtaControlArgs.parse(
            bytes([0x01, 0x03, 0x04, 0x80, 0x45, 0x6B, 0x72, 0xE3, 0x30])),
        isNull,
      );
    });

    test('rides as COMMAND 0x1D', () {
      final payload = SafrCommandPayload.build(
        cmd: SafrCommand.otaControl,
        args: const SafrOtaControlArgs(
          action: SafrOtaAction.start,
          family: 0x02,
          filter: SafrOtaFilter.product(0x0201),
        ).build(),
      );
      expect(payload.sublist(0, 2), [0x1D, 5]);
      expect(payload.sublist(2), [0x01, 0x02, 0x01, 0x02, 0x01]);
    });
  });

  group('GET_ROLLOUT', () {
    test('PAGE u8, 0 = all pages', () {
      expect(SafrGetRolloutArgs.build(), [0]);
      expect(SafrGetRolloutArgs.build(page: 2), [2]);
      expect(SafrGetRolloutArgs.parse(bytes([2])), 2);
      expect(SafrGetRolloutArgs.parse(bytes([])), isNull);
      expect(
        SafrCommandPayload.build(
            cmd: SafrCommand.getRollout, args: SafrGetRolloutArgs.build()),
        [0x1C, 1, 0],
      );
    });
  });

  group('OTA_ROLLOUT', () {
    const wantHeader = [
      0x01, 0x02, 0x00, 0x09, 0x02, 0x02, 0x02, 0x05, //
      0x30, 0x2E, 0x32, 0x2E, 0x30,
    ];
    const wantE1 = [
      0x80, 0x45, 0x6B, 0x74, 0x23, 0x20, 0x02, 0x01, //
      0x02, 40, 1, 0, 0x00, 0x03, 5,
      0x30, 0x2E, 0x31, 0x2E, 0x30,
    ];
    const wantE2 = [
      0x7C, 0x4F, 0xAD, 0xAE, 0x85, 0x90, 0x02, 0x02, //
      0x00, 0, 0, 0, 0xFF, 0xFF, 0,
    ];

    const e1 = SafrOtaRolloutEntry(
      mac: '80:45:6B:74:23:20',
      productCode: 0x0201,
      state: SafrOtaUnitState.downloading,
      percent: 40,
      attempts: 1,
      ageS: 3,
      version: '0.1.0',
    );
    const e2 = SafrOtaRolloutEntry(
      mac: '7C:4F:AD:AE:85:90',
      productCode: 0x0202,
      state: SafrOtaUnitState.waiting,
    );
    const page = SafrOtaRolloutPayload(
      page: 1,
      pageCount: 2,
      total: 9,
      state: SafrOtaRolloutState.rolling,
      family: 0x02,
      target: '0.2.0',
      entries: [e1, e2],
    );

    test('header and entries, byte for byte', () {
      expect(e1.encode(), wantE1);
      expect(e1.wireLength, 14 + 1 + 5);
      expect(e2.encode(), wantE2);
      expect(e2.wireLength, 15);
      expect(page.build(), [...wantHeader, ...wantE1, ...wantE2]);
    });

    test('round trip', () {
      final back = SafrOtaRolloutPayload.parse(page.build())!;
      expect(back.page, 1);
      expect(back.pageCount, 2);
      expect(back.isLastPage, isFalse);
      expect(back.total, 9);
      expect(back.state, SafrOtaRolloutState.rolling);
      expect(back.family, 0x02);
      expect(back.productFamily, SafrProductFamily.node);
      expect(back.target, '0.2.0');
      expect(back.entries, hasLength(2));

      final a = back.entries[0];
      expect(a.mac, '80:45:6B:74:23:20');
      expect(a.productCode, 0x0201);
      expect(a.state, SafrOtaUnitState.downloading);
      expect(a.percent, 40);
      expect(a.attempts, 1);
      expect(a.reason, SafrOtaReason.none);
      expect(a.ageS, 3);
      expect(a.version, '0.1.0');

      final b = back.entries[1];
      expect(b.state, SafrOtaUnitState.waiting);
      expect(b.ageS, isNull, reason: '0xFFFF = never');
      expect(b.version, '', reason: 'no version known yet');
    });

    test('an entry that lacks its last byte', () {
      final p = page.build();
      expect(SafrOtaRolloutPayload.parse(p.sublist(0, p.length - 1)), isNull);
      expect(SafrOtaRolloutEntry.decodeAt(bytes(wantE2.sublist(0, 14)), 0),
          isNull);
    });

    test('page 3 of 2, page 0 and a state that does not exist', () {
      final p = page.build();
      expect(SafrOtaRolloutPayload.parse(bytes([3, ...p.sublist(1)])), isNull);
      expect(SafrOtaRolloutPayload.parse(bytes([0, ...p.sublist(1)])), isNull);
      final badState = Uint8List.fromList(p)..[5] = 6;
      expect(SafrOtaRolloutPayload.parse(badState), isNull);
    });

    test('an entry out of range: state 9, percent 101', () {
      final p = page.build();
      final state = Uint8List.fromList(p)..[wantHeader.length + 8] = 9;
      expect(SafrOtaRolloutPayload.parse(state), isNull);
      final percent = Uint8List.fromList(p)..[wantHeader.length + 9] = 101;
      expect(SafrOtaRolloutPayload.parse(percent), isNull);
    });

    test('fewer entries than COUNT, and bytes behind the last entry', () {
      final p = page.build();
      final three = Uint8List.fromList(p)..[4] = 3;
      expect(SafrOtaRolloutPayload.parse(three), isNull);
      expect(SafrOtaRolloutPayload.parse(bytes([...p, 0x00])), isNull);
    });

    test('the worst entry is 39 bytes: at least 4 in a page', () {
      final big = SafrOtaRolloutEntry(
        mac: '80:45:6B:74:23:20',
        productCode: 0x0201,
        state: SafrOtaUnitState.failed,
        percent: 100,
        attempts: 2,
        reasonRaw: 9,
        ageS: 65000,
        version: '9' * safrFwVersionMaxLen,
      );
      expect(big.wireLength, 39);
      const maxPayload = 202; // SAFR_MAX_PAYLOAD
      expect((maxPayload - (7 + 1 + safrFwVersionMaxLen)) ~/ 39,
          greaterThanOrEqualTo(4));
      final p = SafrOtaRolloutPayload(
        page: 1,
        pageCount: 1,
        total: 4,
        state: SafrOtaRolloutState.partial,
        family: 0x02,
        target: '9' * safrFwVersionMaxLen,
        entries: [big, big, big, big],
      ).build();
      expect(p.length, lessThanOrEqualTo(maxPayload));
      expect(SafrOtaRolloutPayload.parse(p)!.entries, hasLength(4));
    });

    test('staged: what the board holds, no rollout started', () {
      final p = const SafrOtaRolloutPayload(
        page: 1,
        pageCount: 1,
        total: 0,
        state: SafrOtaRolloutState.staged,
        family: 0x02,
        target: '0.1.1',
      ).build();
      expect(p, [1, 1, 0, 0, 0, 1, 0x02, 5, ...ascii.encode('0.1.1')]);
      final back = SafrOtaRolloutPayload.parse(p)!;
      expect(back.state, SafrOtaRolloutState.staged);
      expect(back.total, 0);
      expect(back.entries, isEmpty);
      expect(back.target, '0.1.1');
      expect(back.isLastPage, isTrue);
    });

    test('idle: no rollout, nothing stored, no version', () {
      final p = const SafrOtaRolloutPayload(
        page: 1,
        pageCount: 1,
        total: 0,
        state: SafrOtaRolloutState.idle,
        family: 0x02,
        target: '',
      ).build();
      expect(p, [1, 1, 0, 0, 0, 0, 0x02, 0]);
      expect(SafrOtaRolloutPayload.parse(p)!.state, SafrOtaRolloutState.idle);
    });

    test('a version that is not text is refused', () {
      final p = page.build();
      final bad = Uint8List.fromList(p)..[9] = 0x01;
      expect(SafrOtaRolloutPayload.parse(bad), isNull);
    });
  });

  group('in a frame', () {
    final key = Uint8List.fromList([for (var i = 0; i < 16; i++) 0x30 + i]);
    final unit = SafrEncoder(
      srcMac: safrMacToBytes('80:45:6B:74:23:20'),
      bootCtr: 7,
      systemId: 0x4A17,
      key: key,
    );

    SafrWireFrame through(SafrMsgType type, Uint8List payload,
            {bool ackRequired = false}) =>
        parseSafrWireFrame(
          unit.encode(
            msgType: type,
            payload: payload,
            dstMac: safrCentralMacBytes,
            ackRequired: ackRequired,
          ),
          key: key,
          expectedSystemId: 0x4A17,
        );

    test('OTA_STATUS', () {
      final f = through(
        SafrMsgType.otaStatus,
        const SafrOtaStatusPayload(
          state: SafrOtaUnitState.verifying,
          percent: 100,
        ).build(),
      );
      expect(f.error, isNull);
      expect(f.msgTypeRaw, 0x13);
      expect(f.srcMac, '80:45:6B:74:23:20');
      expect(f.ackRequired, isFalse);
      expect((f.payload as SafrOtaStatusPayload).state,
          SafrOtaUnitState.verifying);
    });

    test('OTA_RESULT asks for an ACK', () {
      final f = through(
        SafrMsgType.otaResult,
        const SafrOtaResultPayload(ok: true, version: '0.2.0').build(),
        ackRequired: true,
      );
      expect(f.error, isNull);
      expect(f.msgTypeRaw, 0x14);
      expect(f.ackRequired, isTrue);
      expect((f.payload as SafrOtaResultPayload).version, '0.2.0');
    });

    test('OTA_ROLLOUT', () {
      final f = through(
        SafrMsgType.otaRollout,
        const SafrOtaRolloutPayload(
          page: 1,
          pageCount: 1,
          total: 0,
          state: SafrOtaRolloutState.staged,
          family: 0x02,
          target: '0.1.1',
        ).build(),
      );
      expect(f.error, isNull);
      expect(f.msgTypeRaw, 0x15);
      expect((f.payload as SafrOtaRolloutPayload).target, '0.1.1');
    });

    test('a payload that is not one is a parse error, not a crash', () {
      final f = through(SafrMsgType.otaStatus, Uint8List.fromList([2, 101]));
      expect(f.error, SafrWireError.payloadParseError);
    });
  });
}
