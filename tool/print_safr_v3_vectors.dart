// Prints the SAFR v3 Appendix-A golden frames (docs/safr/protocol-safr-v3.md).
// Run: dart run tool/print_safr_v3_vectors.dart
import 'dart:typed_data';

import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';

void main() {
  final enc = SafrEncoder(
    srcMac: safrMacToBytes('5A:46:52:00:00:01'),
    bootCtr: 0x0001,
  );
  final vectors = <(String, SafrMsgType, int, int, List<int>)>[
    (
      'V1 EVENT',
      SafrMsgType.event,
      1,
      1,
      [
        0x03, 0x01, 0x68, 0x6E, 0x2F, 0x00, 0x05, 0x55, //
        0x10, 0x68, 0x02, 0x26, 0x2A, 0x00, 0x00, 0x00, 0x01,
      ],
    ),
    (
      'V2 HEARTBEAT',
      SafrMsgType.heartbeat,
      2,
      2,
      [
        0x68, 0x6E, 0x2F, 0x01, 0x00, 0x00, 0x0E, 0x10, //
        0x01, 0x64, 0x00, 0xFA, 0x7F, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00,
      ],
    ),
    (
      'V3 TOPOLOGY',
      SafrMsgType.topology,
      3,
      3,
      [
        0x68, 0x6E, 0x2F, 0x02, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x01, 0x7F, 0x02,
        0x5A, 0x46, 0x52, 0x00, 0x00, 0x02, 0xBE,
        0x5A, 0x46, 0x52, 0x00, 0x00, 0x03, 0xC4,
      ],
    ),
  ];
  for (final (name, type, msgId, msgCtr, payload) in vectors) {
    final frame = enc.encode(
      msgType: type,
      payload: Uint8List.fromList(payload),
      msgId: msgId,
      msgCtr: msgCtr,
    );
    final hex = frame
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    // ignore: avoid_print
    print('$name (${frame.length} bytes):\n$hex\n');
  }
}
