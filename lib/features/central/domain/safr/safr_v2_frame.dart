import 'dart:typed_data';

import 'crc16.dart';
import 'safr_crypto.dart';
import 'safr_v2_payloads.dart';

/// SAFR wire frame — docs/safr/protocol-safr-v3.md §3.
/// v3 (0x03) is the current protocol: 30-byte header with SYSTEM_ID.
/// v2 (0x02) is decode-only for packets stored before the upgrade: 28-byte
/// header, no SYSTEM_ID. All multi-byte fields are big-endian.

const safrSof = 0xA5;
const safrVer1 = 0x01;
const safrVer2 = 0x02;
const safrVer3 = 0x03;
const safrV2HeaderLen = 28; // v2 AAD = bytes 0..27
const safrV3HeaderLen = 30; // v3 AAD = bytes 0..29
const safrCrcLen = 2;
const safrV2MinFrame = 32;
const safrV3MinFrame = 34;
const safrMaxFrame = 256;

/// Development SYSTEM_ID (ASCII "SF") — spec §3.1. Production installations
/// receive a unique SYSTEM_ID during provisioning; 0x0000 = unprovisioned.
const safrDevSystemId = 0x5346;

// FLAGS bits (§3.2)
const safrFlagEnc = 0x01;
const safrFlagAckReq = 0x02;
const safrFlagRetx = 0x04; // periodic re-announcement (NFPA 72 ≤60 s repeat)

/// Reserved MAC identifying the central on the serial link.
const safrCentralMac = '00:00:00:00:00:01';
final safrCentralMacBytes = Uint8List.fromList(const [0, 0, 0, 0, 0, 1]);
final safrBroadcastMacBytes =
    Uint8List.fromList(const [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);

enum SafrMsgType {
  event(0x01),
  heartbeat(0x02),
  topology(0x03),
  ack(0x04),
  command(0x05),
  timeSync(0x06),
  eventLogReq(0x07),
  eventLogData(0x08),
  installation(0x09),
  nameAnnounce(0x0A),
  unknown(0x00);

  const SafrMsgType(this.wire);
  final int wire;

  static SafrMsgType fromWire(int v) => values.firstWhere(
        (e) => e.wire == v,
        orElse: () => SafrMsgType.unknown,
      );
}

/// Why a frame could not be (fully) accepted — drives the humanized
/// diagnostics: CRC ⇒ link corruption, auth ⇒ key/nonce mismatch,
/// foreignSystem ⇒ frame from a neighboring installation (§3.1).
enum SafrWireError {
  truncated,
  badVersion,
  crcFailed,
  foreignSystem,
  authFailed,
  payloadParseError,
}

/// Per-version header offsets: v3 inserts SYSTEM_ID at bytes 7..8, shifting
/// everything after MSG_ID by +2 relative to v2.
class _Layout {
  const _Layout(this.headerLen, this.srcMac, this.minFrame);
  final int headerLen;
  final int srcMac; // SRC_MAC offset; DST/TTL/HOPS/FLAGS/CTRs follow in order
  final int minFrame;

  int get dstMac => srcMac + 6;
  int get ttl => srcMac + 12;
  int get hops => srcMac + 13;
  int get flags => srcMac + 14;
  int get bootCtr => srcMac + 15;
  int get msgCtr => srcMac + 17;
}

const _v2Layout = _Layout(safrV2HeaderLen, 7, safrV2MinFrame);
const _v3Layout = _Layout(safrV3HeaderLen, 9, safrV3MinFrame);

class SafrWireFrame {
  const SafrWireFrame({
    required this.raw,
    required this.ver,
    required this.msgType,
    required this.msgTypeRaw,
    required this.msgId,
    required this.srcMac,
    required this.dstMac,
    required this.ttl,
    required this.hops,
    required this.flags,
    required this.bootCtr,
    required this.msgCtr,
    required this.lenField,
    this.systemId,
    this.payload,
    this.plaintext,
    this.error,
  });

  final Uint8List raw;
  final int ver;
  final SafrMsgType msgType;
  final int msgTypeRaw;
  final int msgId;

  /// Site identity (§3.1) — null on v2 frames, which predate it.
  final int? systemId;
  final String srcMac;
  final String dstMac;
  final int ttl;
  final int hops;
  final int flags;
  final int bootCtr;
  final int msgCtr;
  final int lenField;
  final SafrV2Payload? payload;
  final Uint8List? plaintext;
  final SafrWireError? error;

  bool get isEncrypted => (flags & safrFlagEnc) != 0;
  bool get ackRequired => (flags & safrFlagAckReq) != 0;

  /// Re-announcement of an already-reported event (spec §3.2 F_RETX).
  bool get isRetx => (flags & safrFlagRetx) != 0;
  bool get isValid => error == null;
  bool get isDstBroadcast => dstMac == 'FF:FF:FF:FF:FF:FF';
}

String safrMacToString(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

Uint8List safrMacToBytes(String mac) {
  final parts = mac.split(':');
  assert(parts.length == 6, 'Invalid MAC: $mac');
  return Uint8List.fromList(
    parts.map((p) => int.parse(p, radix: 16)).toList(),
  );
}

/// Verifies structure + CRC of a candidate v2/v3 frame without decrypting.
/// Used by the serial reframer to resync cheaply on false SOF bytes.
bool safrCrcOk(Uint8List bytes) {
  if (bytes.length < safrV2MinFrame) return false;
  final len = (bytes[2] << 8) | bytes[3];
  if (len != bytes.length || len > safrMaxFrame) return false;
  final minFrame = bytes[1] == safrVer3 ? safrV3MinFrame : safrV2MinFrame;
  if (len < minFrame) return false;
  final crc = (bytes[len - 2] << 8) | bytes[len - 1];
  return safrCrc16(bytes, 0, len - 2) == crc;
}

/// Parses (and, when needed, decrypts) a complete SAFR v2/v3 frame.
/// Always returns a frame object; header fields are best-effort populated so
/// diagnostics can name the sender even when validation fails.
///
/// [expectedSystemId]: when given, v3 frames from another installation are
/// rejected with [SafrWireError.foreignSystem] BEFORE decryption (spec §3.1 —
/// EN 54-25 site separation). Pass null to decode regardless (log viewers).
SafrWireFrame parseSafrWireFrame(
  Uint8List bytes, {
  Uint8List? key,
  int? expectedSystemId,
}) {
  final ver = bytes.length > 1 ? bytes[1] : 0;
  final layout = ver == safrVer3 ? _v3Layout : _v2Layout;

  int u16(int off) =>
      bytes.length > off + 1 ? (bytes[off] << 8) | bytes[off + 1] : 0;
  int u32(int off) => bytes.length > off + 3
      ? (bytes[off] << 24) |
          (bytes[off + 1] << 16) |
          (bytes[off + 2] << 8) |
          bytes[off + 3]
      : 0;
  String mac(int off) => bytes.length > off + 5
      ? safrMacToString(bytes.sublist(off, off + 6))
      : '';
  int u8(int off) => bytes.length > off ? bytes[off] : 0;

  SafrWireFrame fail(SafrWireError error) => SafrWireFrame(
        raw: bytes,
        ver: ver,
        msgType: SafrMsgType.fromWire(u8(4)),
        msgTypeRaw: u8(4),
        msgId: u16(5),
        systemId: ver == safrVer3 ? u16(7) : null,
        srcMac: mac(layout.srcMac),
        dstMac: mac(layout.dstMac),
        ttl: u8(layout.ttl),
        hops: u8(layout.hops),
        flags: u8(layout.flags),
        bootCtr: u16(layout.bootCtr),
        msgCtr: u32(layout.msgCtr),
        lenField: u16(2),
        error: error,
      );

  if (bytes.length < layout.minFrame || bytes[0] != safrSof) {
    return fail(SafrWireError.truncated);
  }
  if (ver != safrVer2 && ver != safrVer3) {
    return fail(SafrWireError.badVersion);
  }

  final lenField = u16(2);
  if (lenField != bytes.length) return fail(SafrWireError.truncated);
  if (!safrCrcOk(bytes)) return fail(SafrWireError.crcFailed);

  final systemId = ver == safrVer3 ? u16(7) : null;
  if (expectedSystemId != null &&
      systemId != null &&
      systemId != expectedSystemId) {
    return fail(SafrWireError.foreignSystem);
  }

  final header = Uint8List.sublistView(bytes, 0, layout.headerLen);
  final flags = bytes[layout.flags];
  final encrypted = (flags & safrFlagEnc) != 0;

  final bodyEnd = bytes.length - safrCrcLen;
  final tagLenIfEnc = encrypted ? safrTagLen : 0;
  if (bodyEnd - layout.headerLen - tagLenIfEnc < 0) {
    return fail(SafrWireError.truncated);
  }

  Uint8List plaintext;
  if (encrypted) {
    final cipherWithTag =
        Uint8List.sublistView(bytes, layout.headerLen, bodyEnd);
    final plain =
        safrCcmDecrypt(header: header, cipherWithTag: cipherWithTag, key: key);
    if (plain == null) return fail(SafrWireError.authFailed);
    plaintext = plain;
  } else {
    plaintext = Uint8List.sublistView(bytes, layout.headerLen, bodyEnd);
  }

  final msgType = SafrMsgType.fromWire(bytes[4]);
  final payload = switch (msgType) {
    SafrMsgType.event => SafrEventPayload.parse(plaintext),
    SafrMsgType.heartbeat => SafrHeartbeatPayload.parse(plaintext),
    SafrMsgType.topology => SafrTopologyPayload.parse(plaintext),
    SafrMsgType.ack => SafrAckPayload.parse(plaintext),
    SafrMsgType.command => SafrCommandPayload.parse(plaintext),
    SafrMsgType.timeSync => SafrTimeSyncPayload.parse(plaintext),
    SafrMsgType.eventLogReq => SafrEventLogReqPayload.parse(plaintext),
    SafrMsgType.eventLogData => SafrEventLogDataPayload.parse(plaintext),
    SafrMsgType.installation => SafrInstallationPayload.parse(plaintext),
    SafrMsgType.nameAnnounce => SafrNameAnnouncePayload.parse(plaintext),
    SafrMsgType.unknown => SafrUnknownPayload(plaintext),
  };

  return SafrWireFrame(
    raw: bytes,
    ver: ver,
    msgType: msgType,
    msgTypeRaw: bytes[4],
    msgId: u16(5),
    systemId: systemId,
    srcMac: mac(layout.srcMac),
    dstMac: mac(layout.dstMac),
    ttl: bytes[layout.ttl],
    hops: bytes[layout.hops],
    flags: flags,
    bootCtr: u16(layout.bootCtr),
    msgCtr: u32(layout.msgCtr),
    lenField: lenField,
    payload: payload ?? SafrUnknownPayload(plaintext),
    plaintext: plaintext,
    error: payload == null ? SafrWireError.payloadParseError : null,
  );
}
