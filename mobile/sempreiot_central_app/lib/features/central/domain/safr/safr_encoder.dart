import 'dart:math';
import 'dart:typed_data';

import 'crc16.dart';
import 'safr_crypto.dart';
import 'safr_v2_frame.dart';

/// Builds outgoing SAFR v3 frames (central → root: ACK, COMMAND, TIME_SYNC,
/// EVENT_LOG_REQ). Owns the sender's MSG_ID sequence and the
/// (BOOT_CTR, MSG_CTR) nonce counters — MSG_CTR is fresh for every emitted
/// frame, including retransmissions, so a CCM nonce is never reused (spec §9.1).
class SafrEncoder {
  SafrEncoder({
    Uint8List? srcMac,
    int? bootCtr,
    int systemId = safrDevSystemId,
    Uint8List? key,
  })  : _srcMac = srcMac ?? safrCentralMacBytes,
        _bootCtr = bootCtr ?? Random.secure().nextInt(0x10000),
        _systemId = systemId,
        _key = key;

  final Uint8List _srcMac;
  final int _bootCtr;
  final int _systemId;
  final Uint8List? _key;
  int _msgId = 0;
  int _msgCtr = 0;

  /// Next MSG_ID without consuming it — callers track pending ACKs by it.
  int get lastMsgId => _msgId;

  Uint8List encode({
    required SafrMsgType msgType,
    required Uint8List payload,
    Uint8List? dstMac,
    int ttl = 7,
    int hops = 0,
    bool encrypt = true,
    bool ackRequired = false,
    bool retx = false,
    int? msgId,
    int? msgCtr,
  }) {
    final id = msgId ?? (_msgId = (_msgId + 1) & 0xFFFF);
    final ctr = msgCtr ?? (_msgCtr = (_msgCtr + 1) & 0xFFFFFFFF);
    final dst = dstMac ?? safrBroadcastMacBytes;

    final bodyLen = payload.length + (encrypt ? safrTagLen : 0);
    final total = safrV3HeaderLen + bodyLen + safrCrcLen;
    assert(total <= safrMaxFrame, 'Frame too large: $total');

    final out = Uint8List(total);
    out[0] = safrSof;
    out[1] = safrVer3;
    out[2] = (total >> 8) & 0xFF;
    out[3] = total & 0xFF;
    out[4] = msgType.wire;
    out[5] = (id >> 8) & 0xFF;
    out[6] = id & 0xFF;
    out[7] = (_systemId >> 8) & 0xFF;
    out[8] = _systemId & 0xFF;
    out.setRange(9, 15, _srcMac);
    out.setRange(15, 21, dst);
    out[21] = ttl;
    out[22] = hops;
    out[23] = (encrypt ? safrFlagEnc : 0) |
        (ackRequired ? safrFlagAckReq : 0) |
        (retx ? safrFlagRetx : 0);
    out[24] = (_bootCtr >> 8) & 0xFF;
    out[25] = _bootCtr & 0xFF;
    out[26] = (ctr >> 24) & 0xFF;
    out[27] = (ctr >> 16) & 0xFF;
    out[28] = (ctr >> 8) & 0xFF;
    out[29] = ctr & 0xFF;

    final header = Uint8List.sublistView(out, 0, safrV3HeaderLen);
    if (encrypt) {
      final cipherWithTag = safrCcmEncrypt(
        header: header,
        plaintext: payload,
        key: _key,
      );
      out.setRange(safrV3HeaderLen, safrV3HeaderLen + cipherWithTag.length,
          cipherWithTag);
    } else {
      out.setRange(safrV3HeaderLen, safrV3HeaderLen + payload.length, payload);
    }

    final crc = safrCrc16(out, 0, total - 2);
    out[total - 2] = (crc >> 8) & 0xFF;
    out[total - 1] = crc & 0xFF;
    return out;
  }
}
