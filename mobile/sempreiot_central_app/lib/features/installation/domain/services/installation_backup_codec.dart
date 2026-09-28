import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart';

import '../entities/installation.dart';

/// Thrown by [InstallationBackupCodec.decode] with an operator-readable
/// message.
class BackupDecodeException implements Exception {
  const BackupDecodeException(this.message, {this.wrongPassphrase = false});
  final String message;

  /// True when the envelope is well formed but the passphrase does not open
  /// it (AES-GCM tag mismatch).
  final bool wrongPassphrase;

  @override
  String toString() => message;
}

/// Backup format detected by [InstallationBackupCodec.detectFormat].
enum BackupFormat {
  /// Pre-lifecycle plaintext JSON of [Installation] (keys in clear).
  legacyPlaintext,

  /// Lifecycle v2: passphrase-encrypted envelope.
  encryptedV2,

  /// Neither — not an installation backup.
  unknown,
}

/// The passphrase-encrypted installation backup (lifecycle §2, "Encrypted
/// backup (v2)"). This is the ONLY form in which the code leaves a phone or a
/// tablet: shown as a QR, copied as text.
///
/// Envelope (JSON):
/// ```
/// {"v":2,"kdf":"pbkdf2-sha256","iter":200000,"salt":b64(16),"nonce":b64(12),"ct":b64}
/// ```
/// `ct` = AES-128-GCM(key, nonce, aad = "siot-backup-v2", plaintext) ‖ tag16,
/// where `key = PBKDF2-HMAC-SHA256(passphrase, salt, iter, 16 bytes)` and
/// plaintext = UTF-8 JSON of [Installation.toShareJson].
class InstallationBackupCodec {
  static const version = 2;
  static const kdfName = 'pbkdf2-sha256';
  static const defaultIterations = 200000;
  static const minPassphraseLength = 8;
  static const _aad = 'siot-backup-v2';
  static const _tagBits = 128;

  static BackupFormat detectFormat(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return BackupFormat.unknown;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return BackupFormat.unknown;
    }
    if (decoded is! Map<String, dynamic>) return BackupFormat.unknown;
    if (decoded['v'] == version &&
        decoded['kdf'] == kdfName &&
        decoded['ct'] is String) {
      return BackupFormat.encryptedV2;
    }
    if (decoded['safrPskHex'] is String && decoded['systemId'] is int) {
      return BackupFormat.legacyPlaintext;
    }
    return BackupFormat.unknown;
  }

  /// Encrypts [installation] (share view: no work log) under [passphrase].
  /// [saltOverride]/[nonceOverride] exist for deterministic tests only.
  static String encode(
    Installation installation,
    String passphrase, {
    int iterations = defaultIterations,
    @visibleForTesting Uint8List? saltOverride,
    @visibleForTesting Uint8List? nonceOverride,
  }) {
    if (passphrase.length < minPassphraseLength) {
      throw ArgumentError(
          'passphrase must have at least $minPassphraseLength characters');
    }
    final salt = saltOverride ?? _randomBytes(16);
    final nonce = nonceOverride ?? _randomBytes(12);
    final key = _deriveKey(passphrase, salt, iterations);
    final plaintext =
        Uint8List.fromList(utf8.encode(jsonEncode(installation.toShareJson())));

    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          _tagBits,
          nonce,
          Uint8List.fromList(utf8.encode(_aad)),
        ),
      );
    final out = Uint8List(gcm.getOutputSize(plaintext.length));
    var len = gcm.processBytes(plaintext, 0, plaintext.length, out, 0);
    len += gcm.doFinal(out, len);

    return jsonEncode({
      'v': version,
      'kdf': kdfName,
      'iter': iterations,
      'salt': base64.encode(salt),
      'nonce': base64.encode(nonce),
      'ct': base64.encode(Uint8List.sublistView(out, 0, len)),
    });
  }

  /// Decrypts a v2 envelope. Throws [BackupDecodeException].
  static Installation decode(String raw, String passphrase) {
    Map<String, dynamic> env;
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is! Map<String, dynamic>) {
        throw const BackupDecodeException('Não é um backup de instalação.');
      }
      env = decoded;
    } on FormatException {
      throw const BackupDecodeException('Não é um backup de instalação.');
    }
    if (env['v'] != version || env['kdf'] != kdfName) {
      throw const BackupDecodeException(
          'Formato de backup não reconhecido (esperado v2).');
    }
    final iterations = env['iter'];
    final saltB64 = env['salt'];
    final nonceB64 = env['nonce'];
    final ctB64 = env['ct'];
    if (iterations is! int ||
        iterations < 1000 ||
        saltB64 is! String ||
        nonceB64 is! String ||
        ctB64 is! String) {
      throw const BackupDecodeException('Backup de instalação incompleto.');
    }
    Uint8List salt, nonce, ct;
    try {
      salt = base64.decode(saltB64);
      nonce = base64.decode(nonceB64);
      ct = base64.decode(ctB64);
    } on FormatException {
      throw const BackupDecodeException('Backup de instalação corrompido.');
    }
    if (nonce.length != 12 || ct.length <= _tagBits ~/ 8) {
      throw const BackupDecodeException('Backup de instalação corrompido.');
    }

    final key = _deriveKey(passphrase, salt, iterations);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          _tagBits,
          nonce,
          Uint8List.fromList(utf8.encode(_aad)),
        ),
      );
    final out = Uint8List(gcm.getOutputSize(ct.length));
    Uint8List plaintext;
    try {
      var len = gcm.processBytes(ct, 0, ct.length, out, 0);
      len += gcm.doFinal(out, len);
      plaintext = Uint8List.sublistView(out, 0, len);
    } on InvalidCipherTextException {
      throw const BackupDecodeException('Senha incorreta.',
          wrongPassphrase: true);
    }

    try {
      final json = jsonDecode(utf8.decode(plaintext));
      if (json is! Map<String, dynamic>) {
        throw const BackupDecodeException('Conteúdo do backup inválido.');
      }
      return Installation.fromJson(json);
    } on FormatException {
      throw const BackupDecodeException('Conteúdo do backup inválido.');
    } on TypeError {
      throw const BackupDecodeException('Conteúdo do backup incompleto.');
    }
  }

  static Uint8List _deriveKey(String passphrase, Uint8List salt, int iter) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iter, 16));
    return kdf.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }
}
