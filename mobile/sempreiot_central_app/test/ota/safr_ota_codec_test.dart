import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/crc32.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// Protocol §13.3 / §13.7 (v3.5). The vectors are the ones of the firmware's
/// host tests (firmware/test/host/main/test_ota_proto.c): a layout that
/// changes on one side and not on the other fails here.
void main() {
  // fill_sha() of test_ota_proto.c: 0xA0, 0xA1, … 0xBF.
  final sha = Uint8List.fromList([for (var i = 0; i < 32; i++) 0xA0 + i]);

  group('CRC-32', () {
    test('check value', () {
      expect(otaCrc32(ascii.encode('123456789')), 0xCBF43926);
    });

    test('of nothing is 0', () {
      expect(otaCrc32(const <int>[]), 0);
    });

    test('of a range', () {
      final data = ascii.encode('xx123456789yy');
      expect(otaCrc32(data, 2, 11), 0xCBF43926);
    });

    test('of a whole chunk of 0xFF', () {
      // zlib.crc32(b'\xff' * 4096)
      expect(otaCrc32(Uint8List(4096)..fillRange(0, 4096, 0xFF)), 0xF154670A);
    });
  });

  group('OTA_PUSH_BEGIN', () {
    final begin = SafrOtaPushBeginPayload(
      family: 0x02,
      size: 0x000E1000,
      sha256: sha,
      chunk: 4096,
      version: '0.2.0',
    );

    test('layout', () {
      final p = begin.build();
      expect(p.length, 1 + 4 + 32 + 2 + 1 + 1 + 5);
      expect(p[0], 0x02);
      expect(p.sublist(1, 5), [0x00, 0x0E, 0x10, 0x00]);
      expect(p[5], 0xA0);
      expect(p[36], 0xBF);
      expect(p[37], 0x10); // chunk 4096
      expect(p[38], 0x00);
      expect(p[39], 0x00); // flags
      expect(p[40], 5);
      expect(ascii.decode(p.sublist(41)), '0.2.0');
    });

    test('round trip', () {
      final back = SafrOtaPushBeginPayload.parse(begin.build())!;
      expect(back.family, 0x02);
      expect(back.size, 0x000E1000);
      expect(back.sha256, sha);
      expect(back.chunk, 4096);
      expect(back.flags, 0);
      expect(back.force, isFalse);
      expect(back.version, '0.2.0');
    });

    test('FORCE is bit 0 of FLAGS', () {
      final p = SafrOtaPushBeginPayload(
        family: 0x01,
        size: 4096,
        sha256: sha,
        flags: safrOtaFlagForce,
        version: '0.1.0',
      ).build();
      expect(p[39], 0x01);
      expect(SafrOtaPushBeginPayload.parse(p)!.force, isTrue);
    });

    test('limits', () {
      final p = begin.build();
      final n = p.length;
      Uint8List copy() => Uint8List.fromList(p);

      expect(SafrOtaPushBeginPayload.parse(p.sublist(0, n - 1)), isNull,
          reason: 'truncated');
      expect(
          SafrOtaPushBeginPayload.parse(Uint8List.fromList([...p, 0])), isNull,
          reason: 'trailing byte');
      expect(SafrOtaPushBeginPayload.parse(copy()..[0] = 0x04), isNull,
          reason: 'no such family');
      expect(SafrOtaPushBeginPayload.parse(copy()..fillRange(1, 5, 0)), isNull,
          reason: 'size 0');
      expect(
          SafrOtaPushBeginPayload.parse(copy()
            ..[37] = 0x10
            ..[38] = 0x01),
          isNull,
          reason: 'chunk 4097');
      expect(
          SafrOtaPushBeginPayload.parse(copy()
            ..[37] = 0
            ..[38] = 0),
          isNull,
          reason: 'chunk 0');
      expect(SafrOtaPushBeginPayload.parse(copy()..[40] = 25), isNull,
          reason: 'VER_LEN past the cap');
      expect(
          SafrOtaPushBeginPayload.parse(SafrOtaPushBeginPayload(
            family: 0x02,
            size: 4096,
            sha256: sha,
            version: '',
          ).build()),
          isNull,
          reason: 'no version');
    });

    test('a version of 24 bytes fits, 25 does not', () {
      final v24 = '1.2.3-${'a' * 18}';
      expect(v24.length, 24);
      final p = SafrOtaPushBeginPayload(
              family: 0x01, size: 1, sha256: sha, version: v24)
          .build();
      expect(SafrOtaPushBeginPayload.parse(p)!.version, v24);
      expect(
          () => SafrOtaPushBeginPayload(
                  family: 0x01, size: 1, sha256: sha, version: '${v24}b')
              .build(),
          throwsArgumentError);
    });

    test('fits a frame', () {
      final p = SafrOtaPushBeginPayload(
              family: 0x01, size: 1, sha256: sha, version: 'v' * 24)
          .build();
      final frame = SafrEncoder(bootCtr: 1).encode(
          msgType: SafrMsgType.otaPushBegin, payload: p, ackRequired: true);
      expect(frame.length, lessThanOrEqualTo(safrMaxFrame));
      expect(frame[4], 0x0F);
    });
  });

  group('OTA_PUSH_CHUNK', () {
    test('header layout', () {
      final p = const SafrOtaPushChunkPayload(
              seq: 0x00000102, len: 4096, crc32: 0xCBF43926)
          .build();
      expect(p, [0x00, 0x00, 0x01, 0x02, 0x10, 0x00, 0xCB, 0xF4, 0x39, 0x26]);
    });

    test('round trip and limits', () {
      final p = const SafrOtaPushChunkPayload(
              seq: 0x102, len: 4096, crc32: 0xCBF43926)
          .build();
      final back = SafrOtaPushChunkPayload.parse(p)!;
      expect(back.seq, 0x102);
      expect(back.len, 4096);
      expect(back.crc32, 0xCBF43926);

      expect(SafrOtaPushChunkPayload.parse(p.sublist(0, 9)), isNull);
      expect(
          SafrOtaPushChunkPayload.parse(Uint8List.fromList([...p, 0])), isNull);
      expect(
          SafrOtaPushChunkPayload.parse(Uint8List.fromList(p)
            ..[4] = 0x10
            ..[5] = 0x01),
          isNull,
          reason: '4097');
      expect(
          SafrOtaPushChunkPayload.parse(Uint8List.fromList(p)
            ..[4] = 0
            ..[5] = 0),
          isNull,
          reason: '0');
    });

    test('32-bit values keep their top bit', () {
      final p = const SafrOtaPushChunkPayload(
              seq: 0xFFFFFFFE, len: 1, crc32: 0x80000001)
          .build();
      final back = SafrOtaPushChunkPayload.parse(p)!;
      expect(back.seq, 0xFFFFFFFE);
      expect(back.crc32, 0x80000001);
    });
  });

  group('OTA_PUSH_END', () {
    test('has no payload', () {
      expect(SafrOtaPushEndPayload.build(), isEmpty);
      expect(SafrOtaPushEndPayload.parse(Uint8List(0)), isNotNull);
      expect(SafrOtaPushEndPayload.parse(Uint8List(1)), isNull);
    });
  });

  group('OTA_PUSH_RESULT', () {
    const result = SafrOtaPushResultPayload(
      phase: SafrOtaPushPhase.receiving,
      reasonRaw: 15,
      family: 0x01,
      nextSeq: 17,
      version: '0.2.0',
    );

    test('layout', () {
      final p = result.build();
      expect(p.length, 3 + 4 + 1 + 5);
      expect(p.sublist(0, 8), [0x00, 0x0F, 0x01, 0x00, 0x00, 0x00, 0x11, 0x05]);
      expect(ascii.decode(p.sublist(8)), '0.2.0');
    });

    test('round trip and limits', () {
      final p = result.build();
      final back = SafrOtaPushResultPayload.parse(p)!;
      expect(back.phase, SafrOtaPushPhase.receiving);
      expect(back.nextSeq, 17);
      expect(back.reason, SafrOtaReason.outOfOrder);
      expect(back.family, 0x01);
      expect(back.version, '0.2.0');

      expect(
          SafrOtaPushResultPayload.parse(p.sublist(0, p.length - 1)), isNull);
      expect(SafrOtaPushResultPayload.parse(Uint8List.fromList(p)..[0] = 3),
          isNull,
          reason: 'no such phase');
    });

    test('an empty version and family 0 are accepted', () {
      // What the board sends for a chunk when it holds no transfer.
      final p = const SafrOtaPushResultPayload(
        phase: SafrOtaPushPhase.failed,
        reasonRaw: 15,
        family: 0,
        nextSeq: 0,
        version: '',
      ).build();
      expect(p, [0x02, 0x0F, 0x00, 0, 0, 0, 0, 0x00]);
      final back = SafrOtaPushResultPayload.parse(p)!;
      expect(back.phase, SafrOtaPushPhase.failed);
      expect(back.version, '');
    });

    test('a reason this app does not know is kept as a number', () {
      final p = Uint8List.fromList(result.build())..[1] = 99;
      final back = SafrOtaPushResultPayload.parse(p)!;
      expect(back.reason, SafrOtaReason.unknown);
      expect(back.reasonRaw, 99);
    });

    test('comes out of a frame as a payload', () {
      final frame = SafrEncoder(
        srcMac: safrMacToBytes('7C:4F:AD:AE:85:90'),
        bootCtr: 9,
      ).encode(msgType: SafrMsgType.otaPushResult, payload: result.build());
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.error, isNull);
      expect(parsed.msgType, SafrMsgType.otaPushResult);
      expect(parsed.bootCtr, 9);
      expect((parsed.payload as SafrOtaPushResultPayload).nextSeq, 17);
    });
  });

  group('OTA_BAUD', () {
    test('COMMAND 0x1A, ARGS = BAUD u32', () {
      expect(SafrCommand.otaBaud.wire, 0x1A);
      expect(SafrOtaBaudArgs.build(921600), [0x00, 0x0E, 0x10, 0x00]);
      expect(SafrOtaBaudArgs.build(115200), [0x00, 0x01, 0xC2, 0x00]);
      expect(SafrOtaBaudArgs.parse(SafrOtaBaudArgs.build(921600)), 921600);
      expect(SafrOtaBaudArgs.parse(Uint8List(3)), isNull);

      final p = SafrCommandPayload.build(
          cmd: SafrCommand.otaBaud, args: SafrOtaBaudArgs.build(921600));
      expect(p, [0x1A, 0x04, 0x00, 0x0E, 0x10, 0x00]);
    });

    test('is answered by the board, never relayed', () {
      expect(SafrCommand.otaBaud.isBoardOnly, isTrue);
    });
  });

  group('names of §13', () {
    test('MSG_TYPE', () {
      expect(SafrMsgType.otaPushBegin.wire, 0x0F);
      expect(SafrMsgType.otaPushChunk.wire, 0x10);
      expect(SafrMsgType.otaPushEnd.wire, 0x11);
      expect(SafrMsgType.otaPushResult.wire, 0x12);
      expect(SafrMsgType.otaStatus.wire, 0x13);
      expect(SafrMsgType.otaResult.wire, 0x14);
      expect(SafrMsgType.otaRollout.wire, 0x15);
      expect(SafrMsgType.fromWire(0x12), SafrMsgType.otaPushResult);
    });

    test('COMMAND', () {
      expect(SafrCommand.otaOffer.wire, 0x1B);
      expect(SafrCommand.getRollout.wire, 0x1C);
      expect(SafrCommand.otaControl.wire, 0x1D);
    });
  });

  group('REASON (§13.7)', () {
    test('numbers never change', () {
      const want = {
        SafrOtaReason.none: 0,
        SafrOtaReason.notNewer: 1,
        SafrOtaReason.busyAlarm: 2,
        SafrOtaReason.lowBattery: 3,
        SafrOtaReason.sigFail: 4,
        SafrOtaReason.shaFail: 5,
        SafrOtaReason.wrongFamily: 6,
        SafrOtaReason.noSpace: 7,
        SafrOtaReason.httpErr: 8,
        SafrOtaReason.selftestFail: 9,
        SafrOtaReason.timedOut: 10,
        SafrOtaReason.aborted: 11,
        SafrOtaReason.badArgs: 12,
        SafrOtaReason.busy: 13,
        SafrOtaReason.badCrc: 14,
        SafrOtaReason.outOfOrder: 15,
        SafrOtaReason.badVersion: 16,
        SafrOtaReason.forceRefused: 17,
        SafrOtaReason.notValidated: 18,
        SafrOtaReason.notBooted: 19,
      };
      for (final e in want.entries) {
        expect(e.key.wire, e.value, reason: e.key.name);
        expect(SafrOtaReason.fromWire(e.value), e.key);
      }
      expect(SafrOtaReason.values.length, want.length + 1); // + unknown
      expect(SafrOtaReason.fromWire(20), SafrOtaReason.unknown);
      expect(SafrOtaReason.fromWire(0xFF), SafrOtaReason.unknown);
    });

    test('every reason has a text for the operator', () {
      for (final r in SafrOtaReason.values) {
        expect(r.label.trim(), isNotEmpty, reason: r.name);
        expect(r.label, isNot(contains('_')), reason: r.name);
      }
    });

    test('the DETAIL of an ACK ERROR carries it', () {
      final ack = SafrAckPayload.parse(SafrAckPayload.build(
        ackedMsgId: 0x1234,
        status: SafrAckStatus.error,
        detailRaw: 14,
      ))!;
      expect(ack.ackedMsgId, 0x1234);
      expect(ack.status, SafrAckStatus.error);
      expect(ack.detailRaw, 14);
      expect(ack.otaReason, SafrOtaReason.badCrc);
      // The v3.2 reading of the same byte has no such value.
      expect(ack.detail, SafrAckDetail.unknown);
    });

    test('an ACK of a v3.2 command still reads as before', () {
      final ack = SafrAckPayload.parse(SafrAckPayload.build(
        ackedMsgId: 7,
        status: SafrAckStatus.error,
        detail: SafrAckDetail.notRetired,
      ))!;
      expect(ack.detail, SafrAckDetail.notRetired);
      expect(ack.detailRaw, 0x03);
    });
  });
}
