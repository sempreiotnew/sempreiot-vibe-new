import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart';

/// Crypto for the setup-network HTTP contract (POC-BRIEF.md §5), mirrored in
/// `pocs/autoconnect/main/prov_crypto.c` and
/// `mocked-device-autoconnect/crypto-helpers.js`. Uses the same AES-128-CCM
/// primitive as `central/domain/safr/safr_crypto.dart` (pointycastle's
/// `CCMBlockCipher(AESEngine())`) but with provisioning's own nonce/AAD
/// (`nonce2` + device `id`, not a SAFR frame header) — that file's
/// `safrCcmEncrypt`/`safrCcmDecrypt` can't be called directly because their
/// nonce is derived from a parsed SAFR header, which doesn't exist here.
class ProvisioningCrypto {
  static const tagLen = 16;
  static const _kdfInfo = 'siot-prov-v1';
  static const _setupKdfInfo = 'siot-setinst-v1';

  /// Setup-channel key for the USB link (spec §3.1, v3.2):
  /// `HKDF-SHA256(ikm = utf8(pop), salt = utf8(id), info = "siot-setinst-v1", L = 16)`.
  /// The tablet derives it from the board's sticker to send SET_INSTALLATION
  /// (Case B) or GET_CODE under SYSTEM_ID 0x0000.
  static Uint8List deriveSetupKey({required String id, required String pop}) {
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        Uint8List.fromList(utf8.encode(pop)),
        16,
        Uint8List.fromList(utf8.encode(id)),
        Uint8List.fromList(utf8.encode(_setupKdfInfo)),
      ));
    final out = Uint8List(16);
    hkdf.deriveKey(null, 0, out, 0);
    return out;
  }

  /// `proof = hex(HMAC-SHA256(key = pop, msg = nonce))` — POST /identify.
  static String proof({required String pop, required Uint8List nonce}) {
    final hmac = crypto.Hmac(crypto.sha256, utf8.encode(pop));
    return hmac.convert(nonce).toString();
  }

  /// `key = HKDF-SHA256(ikm = pop, salt = nonce, info = "siot-prov-v1", L = 16)`.
  static Uint8List deriveKey({required String pop, required Uint8List nonce}) {
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        Uint8List.fromList(utf8.encode(pop)),
        16,
        nonce,
        Uint8List.fromList(utf8.encode(_kdfInfo)),
      ));
    final out = Uint8List(16);
    hkdf.deriveKey(null, 0, out, 0);
    return out;
  }

  /// `envelope = base64(nonce2(12) ‖ AES-128-CCM(key, nonce2, aad=id, code_json) ‖ tag16)`
  /// — POST /provision.
  /// [nonce2Override] is for deterministic tests only — production callers
  /// must never pass it (a fresh random nonce2 is required every call).
  static String buildEnvelope({
    required Uint8List key,
    required String id,
    required Map<String, dynamic> codeJson,
    @visibleForTesting Uint8List? nonce2Override,
  }) {
    final nonce2 = nonce2Override ?? _randomBytes(12);
    final plaintext =
        Uint8List.fromList(utf8.encode(jsonEncode(codeJson)));

    final ccm = CCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          tagLen * 8,
          nonce2,
          Uint8List.fromList(utf8.encode(id)),
        ),
      );
    final out = Uint8List(ccm.getOutputSize(plaintext.length));
    var len = ccm.processBytes(plaintext, 0, plaintext.length, out, 0);
    len += ccm.doFinal(out, len);
    final cipherWithTag = Uint8List.sublistView(out, 0, len);

    final envelope = Uint8List(nonce2.length + cipherWithTag.length)
      ..setRange(0, nonce2.length, nonce2)
      ..setRange(nonce2.length, nonce2.length + cipherWithTag.length, cipherWithTag);
    return base64.encode(envelope);
  }

  /// The reverse of [buildEnvelope] (lifecycle §11: the board's GET /code
  /// answer). Returns the decoded `code_json`, or null when the tag fails
  /// (wrong pop / nonce) or the content is not JSON.
  static Map<String, dynamic>? openEnvelope({
    required Uint8List key,
    required String id,
    required String envelopeB64,
  }) {
    Uint8List raw;
    try {
      raw = base64.decode(envelopeB64.trim());
    } on FormatException {
      return null;
    }
    if (raw.length < 12 + tagLen) return null;
    final nonce2 = Uint8List.sublistView(raw, 0, 12);
    final cipherWithTag = Uint8List.sublistView(raw, 12);
    final ccm = CCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          tagLen * 8,
          nonce2,
          Uint8List.fromList(utf8.encode(id)),
        ),
      );
    final out = Uint8List(ccm.getOutputSize(cipherWithTag.length));
    try {
      var len = ccm.processBytes(cipherWithTag, 0, cipherWithTag.length, out, 0);
      len += ccm.doFinal(out, len);
      final json = jsonDecode(utf8.decode(Uint8List.sublistView(out, 0, len)));
      return json is Map<String, dynamic> ? json : null;
    } on InvalidCipherTextException {
      return null;
    } on StateError {
      return null; // pointycastle's CCM reports a tag mismatch as StateError
    } on FormatException {
      return null;
    }
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }
}
