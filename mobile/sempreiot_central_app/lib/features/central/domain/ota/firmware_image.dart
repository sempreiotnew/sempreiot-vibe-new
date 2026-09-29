import 'dart:typed_data';

import '../safr/safr_product.dart';

/// What a firmware file says about itself.
///
/// An ESP-IDF application image carries an `esp_app_desc_t` at byte offset 32
/// (after the 24-byte image header and the 8-byte header of its first
/// segment):
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 32 | 4 | `magic_word` = `0xABCD5432`, little-endian |
/// | 36 | 4 | `secure_version` |
/// | 40 | 8 | `reserv1[2]` |
/// | 48 | 32 | `version`, NUL-terminated ASCII |
/// | 80 | 32 | `project_name`, NUL-terminated ASCII |
///
/// `project_name` names the family (protocol §13.1): `sempreiot-board`,
/// `sempreiot-node`, `sempreiot-leaf`. The operator is never asked which
/// image a file is: the file says it, or it is refused.
class FirmwareImageHeader {
  const FirmwareImageHeader({
    required this.family,
    required this.version,
    required this.projectName,
  });

  final SafrProductFamily family;

  /// As written in the image, e.g. `0.2.0`; at most [safrFwVersionMaxLen]
  /// bytes of printable ASCII.
  final String version;
  final String projectName;

  static const appDescOffset = 32;
  static const appDescMagic = 0xABCD5432;
  static const versionOffset = 48;
  static const projectNameOffset = 80;
  static const fieldLen = 32;

  /// Bytes a file needs for the fields above to be there.
  static const minLength = projectNameOffset + fieldLen;

  static const projectNames = <String, SafrProductFamily>{
    'sempreiot-board': SafrProductFamily.board,
    'sempreiot-node': SafrProductFamily.node,
    'sempreiot-leaf': SafrProductFamily.leaf,
  };

  /// Reads the header of [image]. Throws [FirmwareImageException], with a
  /// text for the operator, when the file is not one of the three images.
  static FirmwareImageHeader parse(Uint8List image) {
    if (image.length < minLength) {
      throw const FirmwareImageException(
          'O arquivo é pequeno demais para ser um firmware.');
    }
    final magic = image[appDescOffset] |
        (image[appDescOffset + 1] << 8) |
        (image[appDescOffset + 2] << 16) |
        (image[appDescOffset + 3] << 24);
    if (magic != appDescMagic) {
      throw const FirmwareImageException(
          'Este arquivo não é um firmware SempreIoT.');
    }
    final projectName = _cString(image, projectNameOffset);
    final family = projectNames[projectName];
    if (family == null) {
      throw FirmwareImageException(projectName.isEmpty
          ? 'O firmware não diz de que produto é.'
          : 'Firmware de outro produto ("$projectName").');
    }
    final version = _cString(image, versionOffset);
    if (version.isEmpty) {
      throw const FirmwareImageException('O firmware não tem versão.');
    }
    if (version.length > safrFwVersionMaxLen) {
      throw FirmwareImageException(
          'A versão do firmware ("$version") passa de '
          '$safrFwVersionMaxLen caracteres.');
    }
    return FirmwareImageHeader(
      family: family,
      version: version,
      projectName: projectName,
    );
  }

  /// A `char[32]` field: up to the first NUL. Anything that is not printable
  /// ASCII makes the field unreadable (empty) rather than garbled.
  static String _cString(Uint8List image, int offset) {
    final out = StringBuffer();
    for (var i = offset; i < offset + fieldLen; i++) {
      final c = image[i];
      if (c == 0) break;
      if (c < 0x20 || c > 0x7E) return '';
      out.writeCharCode(c);
    }
    return out.toString();
  }
}

/// A firmware file ready to be pushed: what it says it is, and what the
/// board is told about it in OTA_PUSH_BEGIN (protocol §13.3).
class FirmwareFile {
  const FirmwareFile({
    required this.name,
    required this.bytes,
    required this.header,
    required this.sha256,
    this.chunkSize = 4096,
  });

  /// The file name the operator picked.
  final String name;
  final Uint8List bytes;
  final FirmwareImageHeader header;

  /// SHA-256 of the whole file, 32 bytes.
  final Uint8List sha256;

  /// Bytes per chunk; the last chunk is what is left.
  final int chunkSize;

  int get size => bytes.length;
  SafrProductFamily get family => header.family;
  String get version => header.version;

  int get chunkCount => (size + chunkSize - 1) ~/ chunkSize;

  /// The raw bytes of chunk [seq] (0-based): a view, not a copy.
  Uint8List chunk(int seq) {
    final start = seq * chunkSize;
    final end = start + chunkSize > size ? size : start + chunkSize;
    return Uint8List.sublistView(bytes, start, end);
  }

  /// Bytes the board holds once chunks `0..seq-1` are written.
  int bytesBefore(int seq) {
    final n = seq * chunkSize;
    return n > size ? size : n;
  }

  String get sha256Hex =>
      sha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// First and last 8 hex digits: enough to compare with the build's log.
  String get sha256Short {
    final hex = sha256Hex;
    return hex.length < 16
        ? hex
        : '${hex.substring(0, 8)}…${hex.substring(hex.length - 8)}';
  }
}

/// The file cannot be pushed; [message] says why, in pt-BR.
class FirmwareImageException implements Exception {
  const FirmwareImageException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// "placa", "unidade de rede elétrica", "detector a bateria": the family as
/// the firmware update screen names it.
String firmwareFamilyLabel(SafrProductFamily family) => switch (family) {
      SafrProductFamily.board => 'placa',
      SafrProductFamily.node => 'unidades de rede elétrica',
      SafrProductFamily.leaf => 'unidades a bateria',
      SafrProductFamily.unknown => 'desconhecido',
    };
