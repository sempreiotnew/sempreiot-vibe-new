import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../access/application/central_access_provider.dart';
import '../../access/domain/entities/access_relation.dart';
import '../domain/system_test/system_test_run.dart';
import 'central_mirror_codec.dart';
import 'device_command_provider.dart';
import 'device_update_controller.dart';
import 'root_election_provider.dart';
import 'system_test_provider.dart';
import 'topology_provider.dart';

/// A phone's "Testar tudo", a phone's "Testar" of one unit and a phone's
/// "Reiniciar" of one unit, carried out on the tablet
/// (docs/cloud/central-mirror.md §4.9, §4.10, §4.11). The same run
/// as the tablet's own — only the checks before it are the phone's:
///
/// 1. who asked is the Identity ID in the command's topic (AWS lets a user
///    publish only under its own), and that user must be an accepted
///    **Administrador** (or Master) of this central, as for an update;
/// 2. **one test at a time** (decided 2026-10-31): the controller refuses
///    while a run is current, whoever started it, so two tests never
///    overlap on the central, on the tablet or on any phone — and one
///    unit is not tested while the system test runs;
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

  // One unit (§4.10). Short, no full stop: the phone writes them beside
  // the unit, after "Testar ·".
  static const unitNotAdmin = 'Só para Administrador';
  static const unitTestRunning = 'Teste do sistema em andamento';
  static const unitNoLink = 'Central sem a placa';
  static const unitUnreachable = 'Sem comunicação';
  static const unitIsBattery = 'Não disponível para detector a bateria';
  static const unitBusy = 'Outro comando em andamento';
  static const unitUpdateRunning = 'Atualização em andamento';
  static const unitNoBoardAck = 'A placa não confirmou';

  /// Null = done; otherwise why not, in words for the phone.
  Future<String?> handle(
      String userIdentityId, MirrorRemoteTest command) async {
    final user = await _userOf(userIdentityId);
    final by = 'remote:${command.name ?? user?.userSubId ?? userIdentityId}';
    final mac = command.mac;
    if (mac != null) {
      final refused = user == null
          ? unitNotAdmin
          : command.restart
              ? await _restart(mac, _whoOf(by))
              : await _unit(mac, _whoOf(by));
      final what = command.restart ? 'unit_restart' : 'unit_test';
      _audit(
        by,
        refused == null ? '${what}_remote_started' : '${what}_remote_refused',
        {
          'user': userIdentityId,
          'mac': mac,
          if (refused != null) 'reason': refused,
        },
      );
      return refused;
    }
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

  /// The accepted Administrador or Master relation of [userIdentityId],
  /// once the central's list of users has been read.
  Future<AccessRelation?> _userOf(String userIdentityId) => _ref
      .read(centralAccessRelationsProvider.notifier)
      .adminOf(userIdentityId);

  /// TESTAR to one unit, through the same door as the tablet's own popover
  /// (device_command_provider): the command goes down, its steps go to
  /// every phone as `command` events. Null = the board took it.
  Future<String?> _unit(String mac, String who) async {
    if (_ref.read(systemTestControllerProvider).running != null) {
      return unitTestRunning;
    }
    if (!_ref.read(boardLinkUpProvider)) return unitNoLink;
    final node =
        _ref.read(topologyProvider).where((n) => n.mac == mac).firstOrNull;
    if (node == null || node.layer <= 0 || !node.online) {
      return unitUnreachable;
    }
    // The tablet's own popover does not offer it for a battery detector
    // either: its firmware takes TEST and raises no test event yet.
    if (node.isLeaf) return unitIsBattery;
    final commands = _ref.read(deviceCommandProvider);
    if (commands[mac]?.inFlight == true ||
        commands[safrBroadcastMac]?.broadcastRunning == true) {
      return unitBusy;
    }
    final ok = await _ref
        .read(deviceCommandProvider.notifier)
        .run(mac, DeviceCommandKind.test, by: who);
    return ok ? null : unitNoBoardAck;
  }

  /// REINICIAR one unit (§4.11) — the board, a mains unit or a battery
  /// unit — through the same door as the tablet's own popover. Not while
  /// the system test or an update runs: both need every unit where it is.
  /// Null = the board took it.
  Future<String?> _restart(String mac, String who) async {
    if (_ref.read(systemTestControllerProvider).running != null) {
      return unitTestRunning;
    }
    if (_ref.read(deviceUpdateProvider)?.running == true) {
      return unitUpdateRunning;
    }
    if (!_ref.read(boardLinkUpProvider)) return unitNoLink;
    final node =
        _ref.read(topologyProvider).where((n) => n.mac == mac).firstOrNull;
    // The board is on the link (checked above); a unit must be heard.
    if (node == null || (node.layer > 0 && !node.online)) {
      return unitUnreachable;
    }
    final commands = _ref.read(deviceCommandProvider);
    if (commands[mac]?.inFlight == true ||
        commands[safrBroadcastMac]?.broadcastRunning == true) {
      return unitBusy;
    }
    final ok = await _ref.read(deviceCommandProvider.notifier).run(
        mac, DeviceCommandKind.restart,
        waitsForWake: node.sleeping, by: who);
    return ok ? null : unitNoBoardAck;
  }

  static String _whoOf(String by) => by.replaceFirst('remote:', '');

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
