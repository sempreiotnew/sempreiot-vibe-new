import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../access/domain/entities/access_level.dart';

/// Role proven at a PIN gate. Master and Administrador (Nível 4) are the
/// only roles allowed to manage PINs; Master is additionally the only one
/// that can reset a forgotten PIN and edit root/senha.
enum EditorRole { master, admin }

extension EditorRoleLabel on EditorRole {
  String get label => this == EditorRole.master ? 'Master' : 'Administrador';
  String get auditName => this == EditorRole.master ? 'master' : 'admin';
}

/// Outcome of a guarded credential check. All gates share one persisted
/// attempt counter, so brute-forcing one PIN locks them all.
sealed class VerifyOutcome {
  const VerifyOutcome();
}

final class VerifyOk extends VerifyOutcome {
  const VerifyOk();
}

final class VerifyWrong extends VerifyOutcome {
  const VerifyWrong();
}

/// The credential being checked was never configured.
final class VerifyUnset extends VerifyOutcome {
  const VerifyUnset();
}

final class VerifyLocked extends VerifyOutcome {
  const VerifyLocked(this.remaining);
  final Duration remaining;

  String get message => 'Muitas tentativas. Aguarde ${remaining.inSeconds}s.';
}

/// Central point for every credential stored on this central: master PIN,
/// per-level PINs, root user and senha. Responsibilities:
///
///  * values are stored as salted SHA-256 hashes — plaintext only exists in
///    the FACTORY payload and is hashed in place on first access;
///  * all verifications go through a shared, persisted rate limiter
///    (3 consecutive failures → lockout with exponential backoff);
///  * every change and every failed attempt lands in the audit trail.
class CredentialsAdminService {
  CredentialsAdminService(this._db);

  final AppDatabase _db;

  static const _maxFailures = 3;
  static const _baseLock = Duration(seconds: 30);
  static const _maxLock = Duration(hours: 1);
  static const _guardKey = 'pin_guard';

  // ── Storage ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _load() async {
    final raw = await _db.getMeta('credentials');
    final map = raw != null && raw.isNotEmpty
        ? jsonDecode(raw) as Map<String, dynamic>
        : <String, dynamic>{};
    return _ensureUnlockPin(await _ensureHashed(map));
  }

  /// Units provisioned before the unlock PIN existed used the master PIN to
  /// unlock the central — carry that behavior over by copying its hash, so
  /// nobody gets locked out of a deployed device after the update.
  Future<Map<String, dynamic>> _ensureUnlockPin(
      Map<String, dynamic> map) async {
    if ((map['unlock_pin'] as String? ?? '').isNotEmpty) return map;
    final masterHash = map['pin'] as String? ?? '';
    if (masterHash.isEmpty) return map;
    map['unlock_pin'] = masterHash;
    await _save(map);
    await _db.addAudit('system', 'unlock_pin_initialized', {});
    return map;
  }

  Future<void> _save(Map<String, dynamic> map) async {
    await _db.setMeta('credentials', jsonEncode(map));
  }

  /// One-way migration: FACTORY provisions plaintext; the first read after
  /// this code ships hashes pin/password/level_pins in place and marks the
  /// row so it never runs twice. Empty strings stay empty ("not set").
  Future<Map<String, dynamic>> _ensureHashed(Map<String, dynamic> map) async {
    if (map['hashed'] == true) return map;

    final salt = _newSalt();
    map['salt'] = salt;

    String hashIfSet(String? v) =>
        (v == null || v.isEmpty) ? '' : _hash(salt, v);

    map['pin'] = hashIfSet(map['pin'] as String?);
    map['unlock_pin'] = hashIfSet(map['unlock_pin'] as String?);
    map['password'] = hashIfSet(map['password'] as String?);

    final levels = (map['level_pins'] as Map<String, dynamic>?) ?? {};
    map['level_pins'] = {
      for (final e in levels.entries) e.key: hashIfSet(e.value as String?),
    };
    map['hashed'] = true;

    await _save(map);
    await _db.addAudit('system', 'credentials_hashed', {});
    return map;
  }

  static String _newSalt() {
    final rnd = Random.secure();
    return List.generate(
        16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _hash(String salt, String value) =>
      sha256.convert(utf8.encode('$salt:$value')).toString();

  String _levelKey(AccessLevel level) => level.wireValue;

  // ── Rate limiting (shared across every gate) ──────────────────────────────

  Future<Map<String, dynamic>> _guardState() async {
    final raw = await _db.getMeta(_guardKey);
    if (raw == null || raw.isEmpty) return {'failures': 0, 'lockouts': 0};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {'failures': 0, 'lockouts': 0};
    }
  }

  Future<Duration?> lockRemaining() async {
    final g = await _guardState();
    final until = g['lockedUntil'] as String?;
    if (until == null) return null;
    final remaining = DateTime.parse(until).difference(DateTime.now());
    return remaining > Duration.zero ? remaining : null;
  }

  Future<void> _registerFailure(String gate) async {
    final g = await _guardState();
    final failures = (g['failures'] as int? ?? 0) + 1;
    if (failures >= _maxFailures) {
      final lockouts = (g['lockouts'] as int? ?? 0);
      var lock = _baseLock * pow(2, min(lockouts, 7)).toInt();
      if (lock > _maxLock) lock = _maxLock;
      await _db.setMeta(
          _guardKey,
          jsonEncode({
            'failures': 0,
            'lockouts': lockouts + 1,
            'lockedUntil': DateTime.now().add(lock).toIso8601String(),
          }));
      await _db.addAudit('system', 'gate_locked',
          {'gate': gate, 'lockSeconds': lock.inSeconds});
    } else {
      await _db.setMeta(
          _guardKey,
          jsonEncode({
            'failures': failures,
            'lockouts': g['lockouts'] ?? 0,
          }));
    }
  }

  Future<void> _registerSuccess() async {
    await _db.setMeta(_guardKey, jsonEncode({'failures': 0, 'lockouts': 0}));
  }

  /// Compares [entered] against the stored hash under the shared guard.
  Future<VerifyOutcome> _guardedCheck({
    required String gate,
    required String? storedHash,
    required String entered,
    required String salt,
  }) async {
    final locked = await lockRemaining();
    if (locked != null) return VerifyLocked(locked);

    if (storedHash == null || storedHash.isEmpty) return const VerifyUnset();

    if (_hash(salt, entered) == storedHash) {
      await _registerSuccess();
      return const VerifyOk();
    }
    await _registerFailure(gate);
    await _db.addAudit('system', 'auth_failed', {'gate': gate});
    final nowLocked = await lockRemaining();
    return nowLocked != null ? VerifyLocked(nowLocked) : const VerifyWrong();
  }

  // ── Verification API ──────────────────────────────────────────────────────

  Future<VerifyOutcome> verifyMasterPin(String pin) async {
    final map = await _load();
    return _guardedCheck(
      gate: 'master_pin',
      storedHash: map['pin'] as String?,
      entered: pin,
      salt: map['salt'] as String,
    );
  }

  /// The unlock PIN's only job is unlocking the central's screen — it is a
  /// separate secret from the master role PIN.
  Future<VerifyOutcome> verifyUnlockPin(String pin) async {
    final map = await _load();
    return _guardedCheck(
      gate: 'unlock_pin',
      storedHash: map['unlock_pin'] as String?,
      entered: pin,
      salt: map['salt'] as String,
    );
  }

  Future<VerifyOutcome> verifyLevelPin(AccessLevel level, String pin) async {
    assert(level != AccessLevel.master);
    final map = await _load();
    final levels = (map['level_pins'] as Map<String, dynamic>?) ?? {};
    return _guardedCheck(
      gate: 'level_pin_${level.wireValue}',
      storedHash: levels[_levelKey(level)] as String?,
      entered: pin,
      salt: map['salt'] as String,
    );
  }

  /// Gate for the PIN-management area: the typed PIN identifies the editor.
  /// Master PIN → [EditorRole.master]; Nível 4 PIN → [EditorRole.admin].
  Future<(VerifyOutcome, EditorRole?)> identifyEditor(String pin) async {
    final map = await _load();
    final salt = map['salt'] as String;
    final locked = await lockRemaining();
    if (locked != null) return (VerifyLocked(locked), null);

    final masterHash = map['pin'] as String? ?? '';
    if (masterHash.isNotEmpty && _hash(salt, pin) == masterHash) {
      await _registerSuccess();
      await _db.addAudit('master', 'editor_unlocked', {});
      return (const VerifyOk(), EditorRole.master);
    }

    final levels = (map['level_pins'] as Map<String, dynamic>?) ?? {};
    final adminHash = levels[_levelKey(AccessLevel.level4)] as String? ?? '';
    if (adminHash.isNotEmpty && _hash(salt, pin) == adminHash) {
      await _registerSuccess();
      await _db.addAudit('admin', 'editor_unlocked', {});
      return (const VerifyOk(), EditorRole.admin);
    }

    await _registerFailure('pin_editor');
    await _db.addAudit('system', 'auth_failed', {'gate': 'pin_editor'});
    final nowLocked = await lockRemaining();
    return (
      nowLocked != null ? VerifyLocked(nowLocked) : const VerifyWrong(),
      null,
    );
  }

  /// Root + senha — the device-ownership credential. Required to add or
  /// remove the (unique) MASTER user.
  Future<VerifyOutcome> verifyRootCredentials(String root, String senha) async {
    final map = await _load();
    final storedRoot = map['root'] as String? ?? '';
    final locked = await lockRemaining();
    if (locked != null) return VerifyLocked(locked);

    if (storedRoot.isEmpty || (map['password'] as String? ?? '').isEmpty) {
      return const VerifyUnset();
    }
    if (root != storedRoot) {
      await _registerFailure('root');
      await _db.addAudit('system', 'auth_failed', {'gate': 'root'});
      final nowLocked = await lockRemaining();
      return nowLocked != null ? VerifyLocked(nowLocked) : const VerifyWrong();
    }
    return _guardedCheck(
      gate: 'root',
      storedHash: map['password'] as String?,
      entered: senha,
      salt: map['salt'] as String,
    );
  }

  // ── Status queries ────────────────────────────────────────────────────────

  Future<bool> isMasterPinConfigured() async {
    final map = await _load();
    return (map['pin'] as String? ?? '').isNotEmpty;
  }

  Future<Map<AccessLevel, bool>> configuredLevelPins() async {
    final map = await _load();
    final levels = (map['level_pins'] as Map<String, dynamic>?) ?? {};
    return {
      for (final l in AccessLevel.values)
        if (l != AccessLevel.master)
          l: ((levels[_levelKey(l)] as String? ?? '').isNotEmpty),
    };
  }

  Future<String> rootUser() async {
    final map = await _load();
    return map['root'] as String? ?? '';
  }

  // ── Mutation API — all return null on success or a user-facing error ──────

  static String? _validateNewPin(String pin) {
    if (pin.length != 6 || int.tryParse(pin) == null) {
      return 'O PIN deve ter 6 dígitos.';
    }
    return null;
  }

  /// Every tier must have a distinct PIN: gates identify the role by which
  /// PIN matched, so a collision would make the roles ambiguous.
  String? _checkUnique(
      Map<String, dynamic> map, String newHash, String selfKey) {
    if ((map['pin'] as String? ?? '') == newHash && selfKey != 'pin') {
      return 'PIN já utilizado (Master).';
    }
    final levels = (map['level_pins'] as Map<String, dynamic>?) ?? {};
    for (final e in levels.entries) {
      if (e.key != selfKey &&
          e.value == newHash &&
          (e.value as String).isNotEmpty) {
        return 'PIN já utilizado em outro nível.';
      }
    }
    return null;
  }

  /// Changes a level PIN. [currentPin] is the level's own current PIN;
  /// pass null to reset without it — allowed only for [EditorRole.master]
  /// (forgotten-PIN path and first-time setup).
  Future<String?> changeLevelPin({
    required AccessLevel level,
    required String? currentPin,
    required String newPin,
    required EditorRole by,
  }) async {
    assert(level != AccessLevel.master);
    final invalid = _validateNewPin(newPin);
    if (invalid != null) return invalid;

    if (currentPin == null && by != EditorRole.master) {
      return 'Apenas o Master pode redefinir um PIN sem o atual.';
    }

    if (currentPin != null) {
      final outcome = await verifyLevelPin(level, currentPin);
      if (outcome is VerifyLocked) return outcome.message;
      if (outcome is VerifyUnset) return 'PIN atual não configurado.';
      if (outcome is! VerifyOk) return 'PIN atual incorreto.';
    }

    final map = await _load();
    final salt = map['salt'] as String;
    final newHash = _hash(salt, newPin);
    final dup = _checkUnique(map, newHash, _levelKey(level));
    if (dup != null) return dup;

    final levels = Map<String, dynamic>.from(
        (map['level_pins'] as Map<String, dynamic>?) ?? {});
    levels[_levelKey(level)] = newHash;
    map['level_pins'] = levels;
    await _save(map);

    await _db.addAudit(
        by.auditName,
        currentPin == null ? 'pin_reset' : 'pin_changed',
        {'level': level.wireValue});
    return null;
  }

  /// Changes the unlock PIN — restricted to the gated editor area, so only
  /// Master/Administrador reach this. No uniqueness check against the role
  /// PINs: the unlock gate is a separate context (and migration seeds it
  /// with the master PIN's value).
  Future<String?> changeUnlockPin({
    required String? currentPin,
    required String newPin,
    required EditorRole by,
  }) async {
    final invalid = _validateNewPin(newPin);
    if (invalid != null) return invalid;

    if (currentPin == null && by != EditorRole.master) {
      return 'Apenas o Master pode redefinir um PIN sem o atual.';
    }

    if (currentPin != null) {
      final outcome = await verifyUnlockPin(currentPin);
      if (outcome is VerifyLocked) return outcome.message;
      if (outcome is VerifyUnset) return 'PIN atual não configurado.';
      if (outcome is! VerifyOk) return 'PIN atual incorreto.';
    }

    final map = await _load();
    map['unlock_pin'] = _hash(map['salt'] as String, newPin);
    await _save(map);
    await _db.addAudit(by.auditName,
        currentPin == null ? 'unlock_pin_reset' : 'unlock_pin_changed', {});
    return null;
  }

  Future<bool> isUnlockPinConfigured() async {
    final map = await _load();
    return (map['unlock_pin'] as String? ?? '').isNotEmpty;
  }

  Future<String?> changeMasterPin({
    required String currentPin,
    required String newPin,
  }) async {
    final invalid = _validateNewPin(newPin);
    if (invalid != null) return invalid;

    final outcome = await verifyMasterPin(currentPin);
    if (outcome is VerifyLocked) return outcome.message;
    if (outcome is VerifyUnset) return 'PIN não configurado.';
    if (outcome is! VerifyOk) return 'PIN atual incorreto.';

    final map = await _load();
    final salt = map['salt'] as String;
    final newHash = _hash(salt, newPin);
    final dup = _checkUnique(map, newHash, 'pin');
    if (dup != null) return dup;

    map['pin'] = newHash;
    await _save(map);
    await _db.addAudit('master', 'pin_changed', {'level': 'MASTER_PIN'});
    return null;
  }

  /// Root/senha are Master-only (enforced by the caller's gate) and always
  /// require the current senha — otherwise the ownership credential could
  /// be rotated by whoever reaches an unlocked screen.
  Future<String?> changeRoot({
    required String currentSenha,
    required String newRoot,
  }) async {
    if (newRoot.trim().isEmpty) return 'Root não pode ser vazio.';
    final outcome = await verifyRootCredentials(await rootUser(), currentSenha);
    if (outcome is VerifyLocked) return outcome.message;
    if (outcome is VerifyUnset) return 'Credenciais root não configuradas.';
    if (outcome is! VerifyOk) return 'Senha incorreta.';

    final map = await _load();
    map['root'] = newRoot.trim();
    await _save(map);
    await _db.addAudit('master', 'root_changed', {});
    return null;
  }

  Future<String?> changeSenha({
    required String currentSenha,
    required String newSenha,
  }) async {
    if (newSenha.length < 6) return 'A senha deve ter no mínimo 6 caracteres.';
    final outcome = await verifyRootCredentials(await rootUser(), currentSenha);
    if (outcome is VerifyLocked) return outcome.message;
    if (outcome is VerifyUnset) return 'Credenciais root não configuradas.';
    if (outcome is! VerifyOk) return 'Senha atual incorreta.';

    final map = await _load();
    map['password'] = _hash(map['salt'] as String, newSenha);
    await _save(map);
    await _db.addAudit('master', 'senha_changed', {});
    return null;
  }

  /// For features outside this service (grant flow, block/unblock) to leave
  /// their trace in the same trail.
  Future<void> audit(
          String actor, String action, Map<String, Object?> detail) =>
      _db.addAudit(actor, action, detail);
}

final credentialsAdminProvider = Provider<CredentialsAdminService>((ref) {
  return CredentialsAdminService(ref.watch(appDatabaseProvider));
});

/// Recent audit trail, newest first.
final auditTrailProvider = FutureProvider<List<AuditEvent>>((ref) {
  return ref.watch(appDatabaseProvider).recentAudit();
});

/// Which level PINs are configured — drives the PINs de Acesso list and
/// disables granting levels whose PIN was never set.
final configuredLevelPinsProvider =
    FutureProvider<Map<AccessLevel, bool>>((ref) {
  return ref.watch(credentialsAdminProvider).configuredLevelPins();
});

final rootUserProvider = FutureProvider<String>((ref) {
  return ref.watch(credentialsAdminProvider).rootUser();
});

final unlockPinConfiguredProvider = FutureProvider<bool>((ref) {
  return ref.watch(credentialsAdminProvider).isUnlockPinConfigured();
});
