import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../access/application/central_access_provider.dart';
import '../../access/domain/entities/access_level.dart';
import '../../access/domain/entities/access_relation.dart';
import '../domain/system_test/system_test_run.dart';
import 'central_mirror_codec.dart';
import 'root_election_provider.dart';
import 'system_test_provider.dart';

/// A phone's "Testar tudo", carried out on the tablet
/// (docs/cloud/central-mirror.md §4.9). The same run as the tablet's own —
/// only the checks before it are the phone's:
///
/// 1. who asked is the Identity ID in the command's topic (AWS lets a user
///    publish only under its own), and that user must be an accepted
///    **Administrador** (or Master) of this central, as for an update;
/// 2. **one test at a time** (decided 2026-10-31): the controller refuses
///    while a run is current, whoever started it, so two tests never
///    overlap on the central, on the tablet or on any phone;
/// 3. the board must be on the link.
///
/// Cancelling is the tablet's, and the phone account that started the run.
/// Every start, cancel and refusal goes into the audit trail with who asked.
class RemoteSystemTest {
  RemoteSystemTest(this._ref);
  final Ref _ref;

  /// Run id → the Identity ID of the phone that started it: only that
  /// phone (and the tablet) may cancel it. RAM only: a run never outlives
  /// the app (a crash closes it on the next start).
  final _startedBy = <String, String>{};

  static const refusedNotAdmin =
      'Só um Administrador desta central pode testar pela internet.';
  static const refusedRunning = 'Já há um teste em andamento.';
  static const refusedNoLink = 'A central não está ligada à placa.';
  static const refusedNothingRuns = 'Nenhum teste em andamento.';
  static const refusedNotYours =
      'Só a central, ou quem iniciou o teste, pode cancelá-lo.';

  /// Null = done; otherwise why not, in words for the phone.
  Future<String?> handle(
      String userIdentityId, MirrorRemoteTest command) async {
    final user = _userOf(userIdentityId);
    final by = 'remote:${command.name ?? user?.userSubId ?? userIdentityId}';
    final refused = user == null
        ? refusedNotAdmin
        : command.cancel
            ? _cancel(userIdentityId)
            : await _start(userIdentityId, by);
    _audit(
      by,
      refused == null
          ? (command.cancel ? 'test_remote_cancelled' : 'test_remote_started')
          : 'test_remote_refused',
      {
        'user': userIdentityId,
        if (command.cancel) 'cancel': true,
        if (refused != null) 'reason': refused,
      },
    );
    return refused;
  }

  /// The accepted Administrador or Master relation of [userIdentityId].
  AccessRelation? _userOf(String userIdentityId) {
    for (final r in _ref.read(centralAccessRelationsProvider)) {
      if (r.userIdentityId == userIdentityId &&
          r.isAccepted &&
          (r.level == AccessLevel.level4 || r.level == AccessLevel.master)) {
        return r;
      }
    }
    return null;
  }

  Future<String?> _start(String userIdentityId, String by) async {
    final tests = _ref.read(systemTestControllerProvider.notifier);
    final running = _ref.read(systemTestControllerProvider).running;
    if (running != null) return _runningWords(running);
    if (!_ref.read(boardLinkUpProvider)) return refusedNoLink;
    // start() refuses when a run is current or another broadcast is on its
    // way; its result is the board's answer, which the record tells.
    await tests.start(by: by);
    final now = _ref.read(systemTestControllerProvider);
    final mine = now.running?.by == by
        ? now.running
        : now.recent.firstOrNull?.by == by
            ? now.recent.first // started and over at once (the board refused)
            : null;
    if (mine == null) {
      final other = now.running;
      return other == null ? refusedRunning : _runningWords(other);
    }
    _startedBy[mine.id] = userIdentityId;
    return null;
  }

  String? _cancel(String userIdentityId) {
    final running = _ref.read(systemTestControllerProvider).running;
    if (running == null) return refusedNothingRuns;
    if (_startedBy[running.id] != userIdentityId) return refusedNotYours;
    final ok = _ref.read(systemTestControllerProvider.notifier).cancel();
    return ok ? null : refusedNothingRuns;
  }

  static String _runningWords(SystemTestRun run) {
    final who = run.by;
    if (who == null) return '$refusedRunning Iniciado na central.';
    return '$refusedRunning Iniciado por ${who.replaceFirst('remote:', '')}.';
  }

  void _audit(String by, String action, Map<String, Object?> detail) {
    _ref
        .read(appDatabaseProvider)
        .addAudit(by, action, detail)
        .catchError((Object e) => debugPrint('[Teste] audit not written: $e'));
  }
}

final remoteSystemTestProvider =
    Provider<RemoteSystemTest>((ref) => RemoteSystemTest(ref));
