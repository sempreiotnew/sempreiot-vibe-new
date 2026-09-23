import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'safr_v2_frame.dart' show safrVer3;

/// AES-128-CCM per docs/safr/protocol-safr-v3.md §4.
/// Nonce (12 B) = SRC_MAC(6) ‖ BOOT_CTR(2) ‖ MSG_CTR(4) — all header fields.
/// AAD = the full header (30 bytes on v3, 28 on decode-only v2).
/// Tag = 16 bytes.

/// Development pre-shared key — must match `SAFR_PSK` in the firmware.
/// ⚠ DEV ONLY: per-installation keys via provisioning are a production
/// launch prerequisite (spec §4 — EN 54-25 site separation).
final safrDevPsk = Uint8List.fromList(const [
  0x25, 0x11, 0x8B, 0xA1, 0xDD, 0x19, 0xB8, 0x45,
  0x09, 0xDF, 0x36, 0xE9, 0x41, 0x6B, 0x8D, 0xBE,
]);

const safrTagLen = 16;

/// Builds the 12-byte CCM nonce from an already-parsed header (28 or 30 B).
/// v3 header: SRC_MAC at 9..14, BOOT_CTR‖MSG_CTR at 24..29.
/// v2 header: SRC_MAC at 7..12, BOOT_CTR‖MSG_CTR at 22..27.
Uint8List safrNonceFromHeader(Uint8List header) {
  final srcOff = header[1] == safrVer3 ? 9 : 7;
  final nonce = Uint8List(12);
  nonce.setRange(0, 6, header, srcOff); // SRC_MAC
  nonce.setRange(6, 12, header, srcOff + 15); // BOOT_CTR ‖ MSG_CTR
  return nonce;
}

/// Decrypts `cipherWithTag` (ciphertext ‖ 16-byte tag). Returns the plaintext
/// or null when authentication fails (wrong key / nonce / tampered data).
Uint8List? safrCcmDecrypt({
  required Uint8List header,
  required Uint8List cipherWithTag,
  Uint8List? key,
}) {
  try {
    final params = AEADParameters(
      KeyParameter(key ?? safrDevPsk),
      safrTagLen * 8,
      safrNonceFromHeader(header),
      header,
    );
    final ccm = CCMBlockCipher(AESEngine())..init(false, params);
    final out = Uint8List(ccm.getOutputSize(cipherWithTag.length));
    var len = ccm.processBytes(cipherWithTag, 0, cipherWithTag.length, out, 0);
    len += ccm.doFinal(out, len);
    return Uint8List.sublistView(out, 0, len);
  } catch (_) {
    return null;
  }
}

/// Encrypts `plaintext`, returning ciphertext ‖ 16-byte tag.
Uint8List safrCcmEncrypt({
  required Uint8List header,
  required Uint8List plaintext,
  Uint8List? key,
}) {
  final params = AEADParameters(
    KeyParameter(key ?? safrDevPsk),
    safrTagLen * 8,
    safrNonceFromHeader(header),
    header,
  );
  final ccm = CCMBlockCipher(AESEngine())..init(true, params);
  final out = Uint8List(ccm.getOutputSize(plaintext.length));
  var len = ccm.processBytes(plaintext, 0, plaintext.length, out, 0);
  len += ccm.doFinal(out, len);
  return Uint8List.sublistView(out, 0, len);
}
