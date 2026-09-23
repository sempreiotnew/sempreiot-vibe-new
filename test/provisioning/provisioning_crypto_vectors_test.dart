import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/services/provisioning_crypto.dart';

/// Deterministic vectors cross-checked against an independent Python
/// (`cryptography` package) implementation of the same HMAC-SHA256 +
/// HKDF-SHA256 + AES-128-CCM construction (POC-BRIEF.md §5), so this isn't
/// just "the Dart code agrees with itself" — it's checked against a second,
/// unrelated implementation of the same primitives.
///
/// Python reference (run once, values pinned below):
///   pop = b"abc123POP0000"; id_ = b"dev-001"
///   nonce = bytes(range(16))              # 000102...0f
///   proof = hmac.new(pop, nonce, hashlib.sha256).hexdigest()
///   key = HKDF(hashes.SHA256(), 16, salt=nonce, info=b"siot-prov-v1").derive(pop)
///   nonce2 = bytes(range(100, 112))
///   envelope = base64(nonce2 + AESCCM(key, tag_length=16).encrypt(nonce2, plaintext, aad=id_))
void main() {
  const pop = 'abc123POP0000';
  const id = 'dev-001';
  final nonce = Uint8List.fromList(List.generate(16, (i) => i));
  final nonce2 = Uint8List.fromList(List.generate(12, (i) => i + 100));

  const codeJson = {
    'system_id': 4660,
    'net_ssid': 'SIOT-TEST',
    'net_psk': 'testpassword1234',
    'safr_psk_hex': '00000000000000000000000000000000',
    'channel': 6,
    'mesh_id': 1,
  };

  test('HMAC-SHA256 proof matches the independent Python vector', () {
    final proof = ProvisioningCrypto.proof(pop: pop, nonce: nonce);
    expect(
      proof,
      'e8f237ab91926a890eb12815d34f8edc10de0920bb1be5d74a50df462a034a6f',
    );
  });

  test('HKDF-SHA256 derived key matches the independent Python vector', () {
    final key = ProvisioningCrypto.deriveKey(pop: pop, nonce: nonce);
    expect(
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'b851ff6f8b7c6b64ec3570e153283df2',
    );
  });

  test('AES-128-CCM envelope matches the independent Python vector', () {
    final key = ProvisioningCrypto.deriveKey(pop: pop, nonce: nonce);
    final envelope = ProvisioningCrypto.buildEnvelope(
      key: key,
      id: id,
      codeJson: codeJson,
      nonce2Override: nonce2,
    );
    expect(
      envelope,
      'ZGVmZ2hpamtsbW5vZA6SMAVjBCA5knF0hb/mDDICrihN0fQs3Qb7mzLMGNLTlSy6'
      'TlhPpZv4gHcT1snedBiE+3StIAXuSyi+bRL/NZgmOtg7AOFntfpbNKMZfMHbhsf8'
      '4xkKhmkoEpUi16k3YOhcxd4jEVpL75qgbb8RLnkNs2jCPWsjmFLbx/EMxL001UgA'
      'zn97o6i/FXSKuU7I9hhCAvUVhtsV2zR/BUVQLQ==',
    );
  });

  test('envelope round-trips: nonce2 + ciphertext + tag decode from base64',
      () {
    final key = ProvisioningCrypto.deriveKey(pop: pop, nonce: nonce);
    final envelope = ProvisioningCrypto.buildEnvelope(
      key: key,
      id: id,
      codeJson: codeJson,
    );
    final raw = base64.decode(envelope);
    expect(raw.length, greaterThan(12 + ProvisioningCrypto.tagLen));
  });
}
