import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// Deterministic test vectors — docs/safr/protocol-safr-v3.md Appendix A.
/// The mock firmware emits these exact frames on boot; the captured-fixture
/// test (safr_v3_captured_test.dart) asserts the firmware bytes match.
///
/// Inputs: PSK = dev key, SYSTEM_ID = 0x5346, SRC = 5A:46:52:00:00:01,
/// DST = broadcast, TTL 7, HOPS 0, FLAGS 0x01 (F_ENC), BOOT_CTR 0x0001.

final _payloads = <(String, SafrMsgType, int, int, List<int>)>[
  (
    'V1 EVENT',
    SafrMsgType.event,
    0x0001,
    0x00000001,
    [
      0x03, 0x01, 0x68, 0x6E, 0x2F, 0x00, 0x05, 0x55, //
      0x10, 0x68, 0x02, 0x26, 0x2A, 0x00, 0x00, 0x00, 0x01, // DEV_SEQ 1
    ],
  ),
  (
    'V2 HEARTBEAT',
    SafrMsgType.heartbeat,
    0x0002,
    0x00000002,
    [
      0x68, 0x6E, 0x2F, 0x01, 0x00, 0x00, 0x0E, 0x10, //
      0x01, 0x64, 0x00, 0xFA, 0x7F, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x01, 0x00,
    ],
  ),
  (
    'V3 TOPOLOGY',
    SafrMsgType.topology,
    0x0003,
    0x00000003,
    [
      0x68, 0x6E, 0x2F, 0x02, 0x00, 0x00, 0x00, 0x00, //
      0x00, 0x00, 0x00, 0x01, 0x7F, 0x02,
      0x5A, 0x46, 0x52, 0x00, 0x00, 0x02, 0xBE,
      0x5A, 0x46, 0x52, 0x00, 0x00, 0x03, 0xC4,
    ],
  ),
];

List<Uint8List> buildSpecVectors() {
  final enc = SafrEncoder(
    srcMac: safrMacToBytes('5A:46:52:00:00:01'),
    bootCtr: 0x0001,
  );
  return [
    for (final (_, type, msgId, msgCtr, payload) in _payloads)
      enc.encode(
        msgType: type,
        payload: Uint8List.fromList(payload),
        msgId: msgId,
        msgCtr: msgCtr,
      ),
  ];
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

/// Golden full-frame hex — must never change without a spec version bump.
/// These exact bytes are in docs/safr/protocol-safr-v3.md Appendix A and must be
/// reproduced bit-for-bit by the firmware's boot-time vector mode.
const _goldenHex = [
  'A503004101000153465A4652000001FFFFFFFFFFFF0700010001000000014'
      '1AF9429BA4D87A82CC6B4BE0C598D6A9244EE915438245C31277D89868FA4723F5820',
  'A503004402000253465A4652000001FFFFFFFFFFFF07000100010000000212D0A08D3'
      '3693CEA467B1F3810E79100A6AEEB92C38A0DFC61192C6FD3A987FA85DFF5C9E9ED',
  'A503004C03000353465A4652000001FFFFFFFFFFFF070001000100000003D92DFFDAFE51A2120'
      '096E2C02AA08E7655180495E70530D730B37389B0278118BAD4AE559B6C5FDE8530F8D233A1',
];

/// SAFR v2 golden frames (docs/safr/protocol-safr-v3.md Appendix A) — the previous
/// protocol. Kept as a decode-only regression: packets stored in the DB before
/// the v3 upgrade must keep rendering forever.
const _v2GoldenHex = [
  'A502003D0100015A4652000001FFFFFFFFFFFF0700010001000000014'
      '1AF9429BA4D87A82CC6B4BE0C598DD840728F462E98B534558B9F3A208B3EBA10',
  'A50200420200025A4652000001FFFFFFFFFFFF07000100010000000212D0A08D3'
      '3693CEA467B1F3810E79100A6AEEB9237AF9BB71A3F89FEFE39EF5A7B623BDDCDCB',
  'A502004A0300035A4652000001FFFFFFFFFFFF070001000100000003D92DFFDAFE51A2120'
      '096E2C02AA08E7655180495E70530D730B37389E9C88234E968BD9D9193D9A5B92799A76A02',
];

Uint8List _fromHex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  test('deterministic v3 spec vectors decrypt and stay stable', () {
    final frames = buildSpecVectors();

    for (var i = 0; i < frames.length; i++) {
      final (name, type, msgId, _, payload) = _payloads[i];
      final parsed = parseSafrWireFrame(frames[i]);
      expect(parsed.isValid, isTrue, reason: '$name: ${parsed.error}');
      expect(parsed.ver, safrVer3, reason: name);
      expect(parsed.systemId, safrDevSystemId, reason: name);
      expect(parsed.msgType, type, reason: name);
      expect(parsed.msgId, msgId, reason: name);
      expect(parsed.plaintext, payload, reason: name);
      expect(_hex(frames[i]), _goldenHex[i], reason: '$name golden');
    }
  });

  test('V1 EVENT vector carries DEV_SEQ 1 (spec §6)', () {
    final parsed = parseSafrWireFrame(buildSpecVectors()[0]);
    final event = parsed.payload as SafrEventPayload;
    expect(event.devSeq, 1);
    expect(event.eventType, SafrEventType.alarm);
  });

  test('v2 golden frames still decode (decode-only regression)', () {
    for (final hex in _v2GoldenHex) {
      final parsed = parseSafrWireFrame(_fromHex(hex));
      expect(parsed.isValid, isTrue, reason: '${parsed.error}');
      expect(parsed.ver, safrVer2);
      expect(parsed.systemId, isNull, reason: 'v2 predates SYSTEM_ID');
      expect(parsed.srcMac, '5A:46:52:00:00:01');
    }
    // v2 EVENT has no DEV_SEQ — must parse with devSeq null.
    final event =
        parseSafrWireFrame(_fromHex(_v2GoldenHex[0])).payload as SafrEventPayload;
    expect(event.devSeq, isNull);
  });

  test('foreign SYSTEM_ID is rejected before decryption (spec §3.1)', () {
    final frame = buildSpecVectors()[0];
    final parsed =
        parseSafrWireFrame(frame, expectedSystemId: 0x1111 /* not ours */);
    expect(parsed.error, SafrWireError.foreignSystem);
    expect(parsed.systemId, safrDevSystemId,
        reason: 'header fields stay readable for diagnostics');
  });
}
