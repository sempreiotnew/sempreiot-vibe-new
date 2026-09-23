import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../installation/domain/entities/installation.dart';
import '../domain/safr/safr_identity.dart';

/// CENTRAL mode: the one installation this tablet belongs to. Imported from
/// the phone's "Backup da instalação" QR (the JSON of [Installation]), which
/// is the only way the SYSTEM_ID and SAFR_PSK reach the central — the board
/// never sends keys over USB (POC-BRIEF §4.2). Stored encrypted at rest like
/// the phone side does (POC-BRIEF §6.1).
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

/// Decodes the phone's installation QR / pasted JSON. Throws
/// [FormatException] with an operator-readable message on anything that is
/// not a complete installation with a valid 16-byte SAFR key.
Installation parseInstallationBackup(String raw) {
  final text = raw.trim();
  Map<String, dynamic> map;
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('não é um JSON de instalação');
    }
    map = decoded;
  } on FormatException {
    throw const FormatException(
        'QR inválido: use o "Backup da instalação" do app do instalador.');
  }
  Installation installation;
  try {
    installation = Installation.fromJson(map);
  } on TypeError {
    throw const FormatException('JSON de instalação incompleto.');
  }
  if (installation.systemId <= 0 || installation.systemId > 0xFFFF) {
    throw const FormatException('SYSTEM_ID fora da faixa.');
  }
  if (SafrIdentity.keyFromHex(installation.safrPskHex) == null) {
    throw const FormatException('Chave SAFR inválida (esperado 32 hex).');
  }
  return installation;
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

  /// Imports from the phone's backup QR / pasted JSON. Returns the parsed
  /// installation; throws [FormatException] on bad input.
  Future<Installation> import(String raw) async {
    final installation = parseInstallationBackup(raw);
    await _store.save(installation);
    state = AsyncValue.data(installation);
    return installation;
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
