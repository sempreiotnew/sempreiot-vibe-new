import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../installation/domain/entities/installation.dart';
import '../../installation/domain/services/installation_backup_codec.dart';
import '../domain/safr/safr_identity.dart';

/// CENTRAL mode: the one installation this tablet belongs to (the code:
/// SYSTEM_ID + SAFR key + Wi-Fi). It reaches the tablet by importing an
/// installer's encrypted backup (lifecycle §2) or, once the board supports
/// it, by GET_CODE over USB (lifecycle §4.1). Stored encrypted at rest.
class CentralInstallationStore {
  CentralInstallationStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'siot_central_installation';

  Future<Installation?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return Installation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> save(Installation installation) =>
      _storage.write(key: _key, value: jsonEncode(installation.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}

final centralInstallationStoreProvider = Provider<CentralInstallationStore>(
  (ref) => CentralInstallationStore(),
);

/// What [parseInstallationBackup] found.
class ParsedBackup {
  const ParsedBackup(this.installation, {required this.legacyPlaintext});
  final Installation installation;

  /// True when the input was the pre-lifecycle plaintext JSON (keys in
  /// clear). Accepted, but the operator is warned.
  final bool legacyPlaintext;
}

/// Thrown by [parseInstallationBackup] when the input is a v2 envelope and
/// no [passphrase] was given: the caller must ask for one and retry.
class PassphraseRequired implements Exception {
  const PassphraseRequired();
}

/// Decodes an installation backup: the v2 encrypted envelope (needs
/// [passphrase]) or the legacy plaintext JSON. Throws [FormatException] with
/// an operator-readable message on anything that is not a complete
/// installation with a valid 16-byte SAFR key, [PassphraseRequired] when a
/// passphrase is needed and missing.
ParsedBackup parseInstallationBackup(String raw, {String? passphrase}) {
  final text = raw.trim();
  final format = InstallationBackupCodec.detectFormat(text);
  Installation installation;
  var legacy = false;
  switch (format) {
    case BackupFormat.encryptedV2:
      if (passphrase == null || passphrase.isEmpty) {
        throw const PassphraseRequired();
      }
      try {
        installation = InstallationBackupCodec.decode(text, passphrase);
      } on BackupDecodeException catch (e) {
        throw FormatException(e.message);
      }
    case BackupFormat.legacyPlaintext:
      legacy = true;
      try {
        installation = Installation.fromJson(
            jsonDecode(text) as Map<String, dynamic>);
      } on TypeError {
        throw const FormatException('JSON de instalação incompleto.');
      } on FormatException {
        throw const FormatException('JSON de instalação inválido.');
      }
    case BackupFormat.unknown:
      throw const FormatException(
          'QR inválido: use "Compartilhar" no app do instalador.');
  }
  if (installation.systemId <= 0 || installation.systemId > 0xFFFF) {
    throw const FormatException('SYSTEM_ID fora da faixa.');
  }
  if (SafrIdentity.keyFromHex(installation.safrPskHex) == null) {
    throw const FormatException('Chave SAFR inválida (esperado 32 hex).');
  }
  return ParsedBackup(installation, legacyPlaintext: legacy);
}

class CentralInstallationNotifier
    extends StateNotifier<AsyncValue<Installation?>> {
  CentralInstallationNotifier(this._store) : super(const AsyncValue.loading()) {
    _load();
  }

  final CentralInstallationStore _store;

  Future<void> _load() async {
    try {
      state = AsyncValue.data(await _store.load());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Imports a backup (QR or pasted text). Throws [FormatException] on bad
  /// input and [PassphraseRequired] when a v2 envelope needs a passphrase.
  Future<ParsedBackup> import(String raw, {String? passphrase}) async {
    final parsed = parseInstallationBackup(raw, passphrase: passphrase);
    // The tablet keeps the code and zones; the installer's work log is not
    // the roster (lifecycle §1) and is dropped here.
    final kept = parsed.installation.copyWith(devices: const []);
    await _store.save(kept);
    state = AsyncValue.data(kept);
    return ParsedBackup(kept, legacyPlaintext: parsed.legacyPlaintext);
  }

  /// Stores a code received from the board (lifecycle §4.1, GET_CODE) or
  /// generated here (Case B).
  Future<void> adopt(Installation installation) async {
    await _store.save(installation);
    state = AsyncValue.data(installation);
  }

  /// The encrypted envelope to show as a QR for a phone (lifecycle §5 D/I).
  String exportEncrypted(String passphrase) {
    final installation = state.valueOrNull;
    if (installation == null) {
      throw StateError('no installation to export');
    }
    return InstallationBackupCodec.encode(installation, passphrase);
  }

  Future<void> clear() async {
    await _store.clear();
    state = const AsyncValue.data(null);
  }
}

final centralInstallationProvider = StateNotifierProvider<
    CentralInstallationNotifier, AsyncValue<Installation?>>(
  (ref) =>
      CentralInstallationNotifier(ref.watch(centralInstallationStoreProvider)),
);

/// What the SAFR pipeline authenticates with right now: the imported
/// installation's identity, or the bench default until one is imported.
final safrIdentityProvider = Provider<SafrIdentity>((ref) {
  final installation = ref.watch(centralInstallationProvider).valueOrNull;
  if (installation == null) return SafrIdentity.dev;
  final key = SafrIdentity.keyFromHex(installation.safrPskHex);
  if (key == null) return SafrIdentity.dev;
  return SafrIdentity(systemId: installation.systemId, key: key);
});
