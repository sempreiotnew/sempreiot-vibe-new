part of 'safr_v2_payloads.dart';

// ── v3.5 firmware update (docs/safr/protocol-safr-v3.md §13) ────────────────
//
// The push to the board (§13.3) and the REASON list (§13.7). Byte layouts
// mirror firmware/components/core/siot_ota_proto and are asserted against
// its host-test vectors in test/safr/safr_ota_codec_test.dart. All integers
// big-endian; a version is `LEN u8 ‖ ASCII`, at most [safrFwVersionMaxLen].

/// Bytes per chunk of a push: the design value and the upper bound (§13.3).
const safrOtaChunkMax = 4096;

/// `SHA256` length in OTA_PUSH_BEGIN.
const safrOtaShaLen = 32;

/// FLAGS bit 0 of OTA_PUSH_BEGIN: install whatever the version (§13.2).
/// Bench builds only; a production build answers `FORCE_REFUSED`.
const safrOtaFlagForce = 0x01;

/// Line speeds of the tablet link (§13.3 OTA_BAUD).
const safrOtaDefaultBaud = 115200;
const safrOtaPushBaud = 921600;

/// `REASON` (§13.7): one list for every firmware-update message, also the
/// `DETAIL` byte of an ACK `ERROR` to one of them. Never renumbered.
enum SafrOtaReason {
  none(0),
  notNewer(1),
  busyAlarm(2),
  lowBattery(3),
  sigFail(4),
  shaFail(5),
  wrongFamily(6),
  noSpace(7),
  httpErr(8),
  selftestFail(9),
  timedOut(10),
  aborted(11),
  badArgs(12),
  busy(13),
  badCrc(14),
  outOfOrder(15),
  badVersion(16),
  forceRefused(17),

  /// A value this app does not know (a newer board).
  unknown(0xFF);

  const SafrOtaReason(this.wire);
  final int wire;

  static SafrOtaReason fromWire(int v) => values.firstWhere(
        (e) => e.wire == v && e != SafrOtaReason.unknown,
        orElse: () => SafrOtaReason.unknown,
      );

  /// What happened, for the operator.
  String get label => switch (this) {
        SafrOtaReason.none => 'Sem motivo informado.',
        SafrOtaReason.notNewer =>
          'A versão do arquivo não é mais nova que a instalada.',
        SafrOtaReason.busyAlarm =>
          'Há alarme ou falha ativa. Resolva antes de atualizar.',
        SafrOtaReason.lowBattery => 'Bateria fraca demais para atualizar.',
        SafrOtaReason.sigFail =>
          'O arquivo não tem a assinatura da SempreIoT.',
        SafrOtaReason.shaFail =>
          'O arquivo chegou corrompido (a soma de verificação não confere).',
        SafrOtaReason.wrongFamily => 'O firmware é de outro tipo de produto.',
        SafrOtaReason.noSpace => 'Não há espaço na placa para este arquivo.',
        SafrOtaReason.httpErr => 'A unidade não conseguiu baixar o arquivo.',
        SafrOtaReason.selftestFail =>
          'O novo firmware falhou no autoteste e a versão anterior foi '
              'restaurada.',
        SafrOtaReason.timedOut => 'O tempo esgotou sem resposta.',
        SafrOtaReason.aborted => 'A atualização foi cancelada.',
        SafrOtaReason.badArgs =>
          'A placa recusou o pedido. Confira se o arquivo é o firmware '
              'assinado.',
        SafrOtaReason.busy => 'A placa já está ocupada com outra atualização.',
        SafrOtaReason.badCrc => 'Os dados chegaram corrompidos pelo cabo.',
        SafrOtaReason.outOfOrder => 'A placa recebeu os dados fora de ordem.',
        SafrOtaReason.badVersion =>
          'A versão do arquivo não tem um formato válido.',
        SafrOtaReason.forceRefused =>
          'Esta placa não aceita instalação forçada.',
        SafrOtaReason.unknown => 'Motivo desconhecido.',
      };
}

/// `PHASE` of OTA_PUSH_RESULT (§13.3).
enum SafrOtaPushPhase {
  /// The transfer is open; `NEXT_SEQ` = the chunk the board wants next.
  receiving(0),

  /// Verified. A board image: the board reboots into it now. A node or leaf
  /// image: stored on the board.
  ok(1),
  failed(2);

  const SafrOtaPushPhase(this.wire);
  final int wire;

  static SafrOtaPushPhase? fromWire(int v) {
    for (final p in values) {
      if (p.wire == v) return p;
    }
    return null;
  }
}

void _putU32(List<int> out, int v) => out
  ..add((v >> 24) & 0xFF)
  ..add((v >> 16) & 0xFF)
  ..add((v >> 8) & 0xFF)
  ..add(v & 0xFF);

int _getU32(Uint8List p, int off) =>
    ((p[off] << 24) | (p[off + 1] << 16) | (p[off + 2] << 8) | p[off + 3]) &
    0xFFFFFFFF;

/// `VER_LEN u8 ‖ VERSION`: ASCII, at most [safrFwVersionMaxLen] bytes.
List<int> _otaVersion(String version) {
  final b = ascii.encode(version);
  if (b.length > safrFwVersionMaxLen) {
    throw ArgumentError(
        'version longer than $safrFwVersionMaxLen bytes: "$version"');
  }
  return [b.length, ...b];
}

/// Reads `VER_LEN ‖ VERSION` at [off], which must end the payload. Null =
/// past the end, too long, trailing bytes or not ASCII.
String? _readOtaVersion(Uint8List p, int off) {
  if (off >= p.length) return null;
  final n = p[off];
  if (n > safrFwVersionMaxLen || off + 1 + n != p.length) return null;
  final bytes = p.sublist(off + 1, off + 1 + n);
  if (bytes.any((c) => c < 0x20 || c > 0x7E)) return null;
  return ascii.decode(bytes);
}

bool _otaFamilyOk(int family) =>
    SafrProductFamily.fromWire(family) != SafrProductFamily.unknown;

/// OTA_PUSH_BEGIN — `MSG_TYPE 0x0F`, tablet → board, `F_ACK_REQ`:
/// `FAMILY u8 ‖ SIZE u32 ‖ SHA256[32] ‖ CHUNK u16 ‖ FLAGS u8 ‖ VER_LEN u8 ‖
/// VERSION` (§13.3).
class SafrOtaPushBeginPayload extends SafrV2Payload {
  const SafrOtaPushBeginPayload({
    required this.family,
    required this.size,
    required this.sha256,
    required this.version,
    this.chunk = safrOtaChunkMax,
    this.flags = 0,
  });

  /// 0x01 board · 0x02 node · 0x03 leaf.
  final int family;

  /// The signed `.bin`, bytes.
  final int size;
  final Uint8List sha256;

  /// Bytes per chunk, 1…[safrOtaChunkMax]; the last chunk is shorter.
  final int chunk;
  final int flags;
  final String version;

  bool get force => flags & safrOtaFlagForce != 0;

  static const minLength = 1 + 4 + safrOtaShaLen + 2 + 1 + 1;

  Uint8List build() {
    if (sha256.length != safrOtaShaLen) {
      throw ArgumentError('SHA-256 must be $safrOtaShaLen bytes');
    }
    final out = <int>[family & 0xFF];
    _putU32(out, size);
    out.addAll(sha256);
    out
      ..add((chunk >> 8) & 0xFF)
      ..add(chunk & 0xFF)
      ..add(flags & 0xFF)
      ..addAll(_otaVersion(version));
    return Uint8List.fromList(out);
  }

  static SafrOtaPushBeginPayload? parse(Uint8List p) {
    if (p.length < minLength) return null;
    final family = p[0];
    final size = _getU32(p, 1);
    final sha = p.sublist(5, 5 + safrOtaShaLen);
    final chunk = (p[37] << 8) | p[38];
    final flags = p[39];
    final version = _readOtaVersion(p, 40);
    if (version == null || version.isEmpty) return null;
    if (!_otaFamilyOk(family) || size == 0) return null;
    if (chunk == 0 || chunk > safrOtaChunkMax) return null;
    return SafrOtaPushBeginPayload(
      family: family,
      size: size,
      sha256: sha,
      chunk: chunk,
      flags: flags,
      version: version,
    );
  }
}

/// OTA_PUSH_CHUNK — `MSG_TYPE 0x10`, tablet → board, `F_ACK_REQ`:
/// `SEQ u32 ‖ LEN u16 ‖ CRC32 u32`, and then `LEN` raw bytes of the image on
/// the wire right after the frame: not encrypted, not framed, covered by
/// `CRC32` ([otaCrc32]) (§13.3).
class SafrOtaPushChunkPayload extends SafrV2Payload {
  const SafrOtaPushChunkPayload({
    required this.seq,
    required this.len,
    required this.crc32,
  });

  /// Counts from 0.
  final int seq;

  /// Raw bytes that follow the frame, 1…[safrOtaChunkMax].
  final int len;
  final int crc32;

  static const wireLength = 10;

  Uint8List build() {
    final out = <int>[];
    _putU32(out, seq);
    out
      ..add((len >> 8) & 0xFF)
      ..add(len & 0xFF);
    _putU32(out, crc32);
    return Uint8List.fromList(out);
  }

  static SafrOtaPushChunkPayload? parse(Uint8List p) {
    if (p.length != wireLength) return null;
    final len = (p[4] << 8) | p[5];
    if (len == 0 || len > safrOtaChunkMax) return null;
    return SafrOtaPushChunkPayload(
      seq: _getU32(p, 0),
      len: len,
      crc32: _getU32(p, 6),
    );
  }
}

/// OTA_PUSH_END — `MSG_TYPE 0x11`, tablet → board, `F_ACK_REQ`, no payload.
class SafrOtaPushEndPayload extends SafrV2Payload {
  const SafrOtaPushEndPayload();

  static Uint8List build() => Uint8List(0);

  static SafrOtaPushEndPayload? parse(Uint8List p) =>
      p.isEmpty ? const SafrOtaPushEndPayload() : null;
}

/// OTA_PUSH_RESULT — `MSG_TYPE 0x12`, board → tablet:
/// `PHASE u8 ‖ REASON u8 ‖ FAMILY u8 ‖ NEXT_SEQ u32 ‖ VER_LEN u8 ‖ VERSION`
/// (§13.3).
class SafrOtaPushResultPayload extends SafrV2Payload {
  const SafrOtaPushResultPayload({
    required this.phase,
    required this.reasonRaw,
    required this.family,
    required this.nextSeq,
    required this.version,
  });

  final SafrOtaPushPhase phase;
  final int reasonRaw;
  final int family;

  /// The chunk the board wants next (resume).
  final int nextSeq;

  /// The version of the image the result is about; may be empty.
  final String version;

  SafrOtaReason get reason => SafrOtaReason.fromWire(reasonRaw);

  static const minLength = 3 + 4 + 1;

  Uint8List build() {
    final out = <int>[phase.wire, reasonRaw & 0xFF, family & 0xFF];
    _putU32(out, nextSeq);
    out.addAll(_otaVersion(version));
    return Uint8List.fromList(out);
  }

  static SafrOtaPushResultPayload? parse(Uint8List p) {
    if (p.length < minLength) return null;
    final phase = SafrOtaPushPhase.fromWire(p[0]);
    final version = _readOtaVersion(p, 7);
    if (phase == null || version == null) return null;
    return SafrOtaPushResultPayload(
      phase: phase,
      reasonRaw: p[1],
      family: p[2],
      nextSeq: _getU32(p, 3),
      version: version,
    );
  }
}

/// ARGS of `COMMAND 0x1A` OTA_BAUD: `BAUD u32` (§13.3).
abstract final class SafrOtaBaudArgs {
  static Uint8List build(int baud) {
    final out = <int>[];
    _putU32(out, baud);
    return Uint8List.fromList(out);
  }

  static int? parse(Uint8List args) =>
      args.length == 4 ? _getU32(args, 0) : null;
}
