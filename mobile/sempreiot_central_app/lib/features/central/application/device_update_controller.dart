import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/ota/firmware_version.dart';
import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'alarm_latch_provider.dart';
import 'device_update_state.dart';
import 'firmware_library_provider.dart';
import 'ota_push_controller.dart';
import 'ota_push_report.dart' show unitFamily;
import 'ota_push_state.dart';
import 'ota_rollout_controller.dart';
import 'ota_rollout_report.dart' show otaHeldOnBoardProvider;
import 'ota_rollout_state.dart';
import 'root_election_provider.dart';
import 'topology_provider.dart';

/// How long the run waits for the board to say a unit's outcome before it
/// calls it failed. Beyond the board's own deadline (300 s for a node, 600 s
/// for a detector, protocol §13.4 / §13.5): only a board that went silent
/// gets here.
class DeviceUpdateTimings {
  const DeviceUpdateTimings({
    this.nodeUnit = const Duration(minutes: 8),
    this.leafUnit = const Duration(minutes: 15),
    this.heldWait = const Duration(seconds: 6),
    this.heldPoll = const Duration(milliseconds: 250),
    this.meshBack = const Duration(minutes: 5),
    this.meshPoll = const Duration(seconds: 1),
  });

  final Duration nodeUnit;
  final Duration leafUnit;

  /// After an image was stored: how long the board's table may take to say
  /// it holds it (the rollout refuses a start before that).
  final Duration heldWait;
  final Duration heldPoll;

  /// After the board restarted: the longest wait for the units of the run
  /// to be heard again before anything is offered to them (the mesh joins
  /// the board's access point again: seconds to a couple of minutes).
  final Duration meshBack;
  final Duration meshPoll;

  Duration perUnit(SafrProductFamily f) =>
      f == SafrProductFamily.leaf ? leafUnit : nodeUnit;
}

/// One update from "Atualizar dispositivos", on top of the two controllers
/// that already talk to the board:
///
///   the image → the board ([OtaPushController], skipped when the board
///   already holds that version) → the units ([OtaRolloutController]).
///
/// The board's rollout filter takes every unit of a family, or ONE unit
/// (protocol §13.6): when the operator chose some of them, the run starts
/// one rollout per unit, the root last. The board replaces its table with
/// every rollout it starts, so the run keeps its own record of each unit.
///
/// "Atualizar tudo" is three phases — board, nodes, detectors — with the
/// rules between them: the board failed → nothing else is touched; a node
/// failed → the operator decides before the detectors.
///
/// Kept in memory only: after an app restart the board goes on with the
/// rollout it runs, and the run is not resumed by itself.
class DeviceUpdateController extends StateNotifier<DeviceUpdateRun?> {
  DeviceUpdateController(
    this._ref, {
    DeviceUpdateTimings? timings,
    DateTime Function()? clock,
  })  : _t = timings ?? const DeviceUpdateTimings(),
        _clock = clock ?? DateTime.now,
        super(null);

  /// The push and the rollout are listened to from the first run on: a
  /// screen that only shows whether a run exists (the Rede line) does not
  /// bring the two controllers to life.
  bool _listening = false;
  void _listen() {
    if (_listening) return;
    _listening = true;
    _ref.listen<OtaPushState>(otaPushProvider, (_, s) => _onPush(s));
    _ref.listen<OtaRolloutState>(otaRolloutProvider, (_, s) => _onRollout(s));
  }

  final Ref _ref;
  final DeviceUpdateTimings _t;
  final DateTime Function() _clock;

  final _images = <SafrProductFamily, FirmwareLibraryEntry>{};
  Completer<OtaPushPhase>? _pushWait;
  _RolloutWait? _rolloutWait;
  Completer<void>? _resumeWait;
  bool _aborted = false;

  /// Moves on every new run: a loop of an older run stops at its next step.
  int _generation = 0;

  /// When the board last restarted into a new image (kept across runs: a
  /// run started right after "Placa" waits for the mesh too).
  DateTime? _boardRestartedAt;

  /// The push whose restart was taken (its `startedAt`).
  DateTime? _restartSeenFor;

  // ── Starting ─────────────────────────────────────────────────────────────

  /// Updates the units [keys] of [family] (the board:
  /// [deviceUpdateBoardKey]) to [image]. Returns why not, or null when the
  /// run started.
  Future<String?> start({
    required SafrProductFamily family,
    required Iterable<String> keys,
    required FirmwareLibraryEntry image,
    bool reinstall = false,
  }) async {
    final blocker = _startBlocker();
    if (blocker != null) return blocker;
    if (image.family != family) {
      return 'Este firmware não é para estes dispositivos.';
    }
    final queue = family == SafrProductFamily.board
        ? const [deviceUpdateBoardKey]
        : _rootLast(keys);
    if (queue.isEmpty) return 'Escolha ao menos um dispositivo.';
    _images
      ..clear()
      ..[family] = image;
    _begin(
      all: false,
      phases: [family],
      target: image.version,
      queues: {family: queue},
      reinstall: reinstall,
    );
    return null;
  }

  /// "Atualizar tudo" to [version]: the board, then every node, then every
  /// detector the tablet hears. Returns why not, or null when it started.
  Future<String?> startAll(String version, {bool reinstall = false}) async {
    final blocker = _startBlocker();
    if (blocker != null) return blocker;
    final library = _ref.read(firmwareLibraryProvider);
    _images.clear();
    for (final f in const [
      SafrProductFamily.board,
      SafrProductFamily.node,
      SafrProductFamily.leaf,
    ]) {
      final image = library.image(f, version);
      if (image == null) {
        return 'O tablet não tem as três imagens da versão $version.';
      }
      _images[f] = image;
    }
    final nodes = _online(SafrProductFamily.node);
    final leafs = _online(SafrProductFamily.leaf);
    _begin(
      all: true,
      phases: [
        SafrProductFamily.board,
        if (nodes.isNotEmpty) SafrProductFamily.node,
        if (leafs.isNotEmpty) SafrProductFamily.leaf,
      ],
      target: version,
      queues: {
        SafrProductFamily.board: const [deviceUpdateBoardKey],
        if (nodes.isNotEmpty) SafrProductFamily.node: nodes,
        if (leafs.isNotEmpty) SafrProductFamily.leaf: leafs,
      },
      reinstall: reinstall,
    );
    return null;
  }

  String? _startBlocker() {
    if (state?.running == true) return 'Já há uma atualização em andamento.';
    if (_ref.read(otaPushProvider).running) {
      return 'Aguarde o envio do arquivo à placa terminar.';
    }
    if (_ref.read(otaRolloutProvider).running != null) {
      return 'A placa já está atualizando dispositivos.';
    }
    if (_ref.read(activeAlarmProvider)) {
      return 'Há alarme ativo. Rearme a central antes de atualizar.';
    }
    return null;
  }

  void _begin({
    required bool all,
    required List<SafrProductFamily> phases,
    required String target,
    required Map<SafrProductFamily, List<String>> queues,
    bool reinstall = false,
  }) {
    _listen();
    _generation++;
    _aborted = false;
    _pushWait = null;
    _rolloutWait = null;
    final units = <String, DeviceUpdateUnit>{};
    for (final e in queues.entries) {
      for (final key in e.value) {
        final runs = _versionOf(key);
        // Chosen on purpose ("Reinstalar"): offered again all the same.
        final already = !reinstall &&
            runs.isNotEmpty &&
            compareFirmwareVersions(runs, target) == 0;
        units[key] = DeviceUpdateUnit(
          key: key,
          family: e.key,
          versionBefore: runs,
          version: runs,
          // A unit already on the version is not offered it again (the
          // version rule may be relaxed on the bench: it would reinstall).
          state: already ? SafrOtaUnitState.done : SafrOtaUnitState.waiting,
          note: already ? 'Já estava nesta versão.' : null,
        );
      }
    }
    state = DeviceUpdateRun(
      all: all,
      phases: phases,
      target: target,
      queues: queues,
      units: units,
      stage: DeviceUpdateStage.pushing,
      startedAt: _clock(),
      boardRestartedAt: _boardRestartedAt,
    );
    unawaited(_runPhase(_generation));
  }

  // ── Steering ─────────────────────────────────────────────────────────────

  /// No unit starts after the one that is updating now.
  Future<String?> pause() async {
    final run = state;
    if (run == null || run.stage != DeviceUpdateStage.rolling) return null;
    state = run.copyWith(holding: true);
    final f = _ref.read(otaRolloutProvider).families[run.family];
    if (f != null && f.state == SafrOtaRolloutState.rolling) {
      return _ref.read(otaRolloutProvider.notifier).pause(run.family);
    }
    return null;
  }

  /// Goes on. Not while an alarm is latched.
  Future<String?> resume() async {
    final run = state;
    if (run == null || !run.running) return null;
    if (_ref.read(activeAlarmProvider)) {
      return 'Há alarme ativo. Rearme a central antes de retomar.';
    }
    final f = _ref.read(otaRolloutProvider).families[run.family];
    if (f != null && f.state == SafrOtaRolloutState.paused) {
      final refused =
          await _ref.read(otaRolloutProvider.notifier).resume(run.family);
      if (refused != null) return refused;
    }
    if (!mounted || state == null) return null;
    state = state!.copyWith(holding: false, pausedBy: null, message: null);
    _release();
    return null;
  }

  /// Stops: nothing new starts, the units still waiting are left out.
  Future<void> abort() async {
    final run = state;
    if (run == null || !run.running) return;
    _aborted = true;
    _markWaitingSkipped();
    switch (run.stage) {
      case DeviceUpdateStage.pushing:
        _ref.read(otaPushProvider.notifier).cancel();
      case DeviceUpdateStage.reconnecting:
        break;
      case DeviceUpdateStage.rolling:
        final f = _ref.read(otaRolloutProvider).families[run.family];
        if (f != null && f.running) {
          await _ref.read(otaRolloutProvider.notifier).abort(run.family);
        }
      case DeviceUpdateStage.deciding:
        _finish(DeviceUpdateEnd.cancelled);
      case DeviceUpdateStage.ended:
        break;
    }
    _release();
  }

  /// "Atualizar tudo", a node failed: go on with the detectors, or stop.
  void decide({required bool goOn}) {
    final run = state;
    if (run == null || run.stage != DeviceUpdateStage.deciding) return;
    if (goOn) {
      _next(_generation);
    } else {
      _markWaitingSkipped();
      _finish(DeviceUpdateEnd.stopped, message: 'Parado antes dos detectores.');
    }
  }

  /// The units of the current family that failed, once more.
  String? retryFailed() {
    final run = state;
    if (run == null) return null;
    final canRetry = run.stage == DeviceUpdateStage.deciding ||
        (run.stage == DeviceUpdateStage.ended &&
            run.end == DeviceUpdateEnd.partial);
    if (!canRetry) return 'Não há falhas para tentar de novo.';
    final failed = [
      for (final u in run.notUpdated(run.family)) u.key,
    ];
    if (failed.isEmpty) return 'Não há falhas para tentar de novo.';
    if (_ref.read(activeAlarmProvider)) {
      return 'Há alarme ativo. Rearme a central antes de atualizar.';
    }
    final units = Map.of(run.units);
    for (final k in failed) {
      units[k] = units[k]!.copyWith(
          state: SafrOtaUnitState.waiting,
          percent: 0,
          reasonRaw: 0,
          note: null);
    }
    _generation++;
    _aborted = false;
    state = run.copyWith(
      units: units,
      stage: DeviceUpdateStage.rolling,
      end: null,
      endedAt: null,
      message: null,
    );
    unawaited(_runPhase(_generation));
    return null;
  }

  /// Closes a run that ended ("Concluir").
  void dismiss() {
    if (state?.running == false) state = null;
  }

  // ── The run ──────────────────────────────────────────────────────────────

  Future<void> _runPhase(int gen) async {
    try {
      await _phase(gen);
    } catch (e, st) {
      debugPrint('[OTA] update run failed: $e\n$st');
      if (_live(gen)) {
        _finish(DeviceUpdateEnd.failed, message: 'A atualização parou: $e');
      }
    }
  }

  bool _live(int gen) =>
      mounted && gen == _generation && state?.running == true;

  Future<void> _phase(int gen) async {
    final fam = state!.family;
    final image = _images[fam]!;
    final pending = _pending(fam);
    if (pending.isEmpty) return _endPhase(gen);

    await _waitNoAlarm(gen);
    if (!_live(gen) || _aborted) return _endPhase(gen);

    // 1. The image to the board — unless it holds that version already.
    final held = _ref.read(otaHeldOnBoardProvider)[fam];
    if (fam == SafrProductFamily.board || held != image.version) {
      _set((r) => r.copyWith(stage: DeviceUpdateStage.pushing, message: null));
      final ok = await _push(gen, image);
      if (!_live(gen) || !ok) return;
      if (fam == SafrProductFamily.board) return _endPhase(gen);
      await _waitHeld(gen, fam, image.version);
      if (!_live(gen)) return;
    }

    // The board restarted (phase 1, or a "Placa" just before): its access
    // point went down and the mesh is joining it again. An offer now reaches
    // nobody (bench 2026-10-02: every node timed out, "Tentar de novo" a
    // minute later went through).
    await _waitMeshBack(gen);
    if (!_live(gen)) return;

    // 2. The units, one rollout each. The next one is chosen right before
    // it is offered, from the map as it is then: the deepest first, parents
    // after their children, the mesh root always last. Never the board's
    // own queue: right after the board's restart (phase 1 of "Atualizar
    // tudo") the mesh rebuilds, the root may be another node and the board
    // may not know it yet — the root offered first takes the whole mesh down
    // with it (bench 2026-10-02).
    _set((r) => r.copyWith(stage: DeviceUpdateStage.rolling));
    final tried = <String>{};
    while (true) {
      await _waitWhileHolding(gen);
      await _waitNoAlarm(gen);
      if (!_live(gen) || _aborted) break;
      final key = _nextUnit(fam, tried);
      if (key == null) break;
      tried.add(key);
      await _roll(gen, fam, SafrOtaFilter.unit(key), [key]);
      if (!_live(gen)) return;
    }
    if (!_live(gen)) return;
    _endPhase(gen);
  }

  /// Sends [image] to the board and waits for its verdict. False when the
  /// run ended because of it.
  Future<bool> _push(int gen, FirmwareLibraryEntry image) async {
    final fam = image.family;
    final bytes = await _ref.read(firmwareLibraryProvider.notifier).read(image);
    if (!_live(gen)) return false;
    final push = _ref.read(otaPushProvider.notifier);
    await push.loadFile(image.fileName, bytes);
    if (!_live(gen)) return false;
    if (_ref.read(otaPushProvider).file == null) {
      _failPush(fam, 'O arquivo ${image.fileName} não pôde ser lido.');
      return false;
    }
    final wait = _pushWait = Completer<OtaPushPhase>();
    final refused = await push.start();
    if (refused != null) {
      _pushWait = null;
      if (_live(gen)) _failPush(fam, refused);
      return false;
    }
    final phase = await wait.future;
    _pushWait = null;
    if (!_live(gen)) return false;
    switch (phase) {
      case OtaPushPhase.confirmed:
        _setUnit(
            deviceUpdateBoardKey,
            (u) => u.copyWith(
                state: SafrOtaUnitState.done,
                percent: 100,
                version: image.version));
        return true;
      case OtaPushPhase.stored:
        return true;
      default:
        final rolledBack = phase == OtaPushPhase.rolledBack;
        final why = rolledBack
            ? 'A placa não passou no autoteste com ${image.version} e voltou à '
                'versão anterior.'
            : (_ref.read(otaPushProvider).message ??
                'O envio do arquivo à placa falhou.');
        _failPush(fam, why, rolledBack: rolledBack);
        return false;
    }
  }

  void _failPush(SafrProductFamily fam, String why, {bool rolledBack = false}) {
    if (fam == SafrProductFamily.board) {
      _setUnit(
          deviceUpdateBoardKey,
          (u) => u.copyWith(
                state: _aborted
                    ? SafrOtaUnitState.skipped
                    : SafrOtaUnitState.failed,
                reasonRaw: rolledBack ? SafrOtaReason.selftestFail.wire : 0,
                note: why,
              ));
    }
    _markWaitingSkipped();
    _finish(_aborted ? DeviceUpdateEnd.cancelled : DeviceUpdateEnd.failed,
        message: _aborted
            ? null
            : fam == SafrProductFamily.board
                ? why
                : 'A imagem não chegou à placa: $why');
  }

  /// The board's table may say it holds the new image a moment after the
  /// push ended; a start before that is refused.
  Future<void> _waitHeld(int gen, SafrProductFamily fam, String version) async {
    final rollout = _ref.read(otaRolloutProvider.notifier);
    unawaited(rollout.refresh());
    final until = _clock().add(_t.heldWait);
    while (_live(gen) && _clock().isBefore(until)) {
      final f = _ref.read(otaRolloutProvider).families[fam];
      if (f != null && f.holdsImage && f.target == version) return;
      await Future<void>.delayed(_t.heldPoll);
    }
  }

  /// One rollout of [fam] to [keys], and the wait for its end.
  Future<void> _roll(
    int gen,
    SafrProductFamily fam,
    SafrOtaFilter filter,
    List<String> keys,
  ) async {
    final wait = _RolloutWait(fam, _clock(), keys, filter);
    _rolloutWait = wait;
    final refused = await _ref
        .read(otaRolloutProvider.notifier)
        .start(fam, filter, expected: keys.length);
    if (!_live(gen)) return;
    if (refused != null) {
      _rolloutWait = null;
      for (final k in keys) {
        _setUnit(k,
            (u) => u.copyWith(state: SafrOtaUnitState.failed, note: refused));
      }
      return;
    }
    final timer = Timer(_t.perUnit(fam) * keys.length, () {
      if (!wait.done.isCompleted) wait.done.complete(false);
    });
    _onRollout(_ref.read(otaRolloutProvider));
    final ended = await wait.done.future;
    timer.cancel();
    if (identical(_rolloutWait, wait)) _rolloutWait = null;
    if (!_live(gen)) return;
    for (final k in keys) {
      final u = state!.units[k];
      if (u == null || u.state.settled) continue;
      _setUnit(
          k,
          (u) => u.copyWith(
                state: SafrOtaUnitState.failed,
                reasonRaw: ended ? 0 : SafrOtaReason.timedOut.wire,
                note: ended
                    ? 'A placa terminou sem atualizar este dispositivo.'
                    : 'A placa não disse mais nada sobre este dispositivo.',
              ));
    }
  }

  void _endPhase(int gen) {
    if (!_live(gen)) return;
    final run = state!;
    if (_aborted) {
      _markWaitingSkipped();
      return _finish(DeviceUpdateEnd.cancelled);
    }
    final fam = run.family;
    final last = run.phase == run.phases.length - 1;
    if (!run.all || last) {
      return _finish(run.notUpdatedCount > 0
          ? DeviceUpdateEnd.partial
          : DeviceUpdateEnd.done);
    }
    // Not only a failure: a node skipped or never offered is not updated
    // either, and the detectors hang off the nodes.
    if (fam == SafrProductFamily.node && run.notUpdated(fam).isNotEmpty) {
      state = run.copyWith(stage: DeviceUpdateStage.deciding);
      return;
    }
    _next(gen);
  }

  void _next(int gen) {
    final run = state!;
    state = run.copyWith(
      phase: run.phase + 1,
      stage: DeviceUpdateStage.pushing,
      message: null,
      pausedBy: null,
    );
    unawaited(_runPhase(gen));
  }

  void _finish(DeviceUpdateEnd end, {String? message}) {
    final run = state;
    if (run == null) return;
    _rolloutWait = null;
    state = run.copyWith(
      stage: DeviceUpdateStage.ended,
      end: end,
      message: message ?? run.message,
      endedAt: _clock(),
      holding: false,
      pausedBy: null,
    );
    _release();
  }

  // ── Waiting ──────────────────────────────────────────────────────────────

  Future<void> _waitWhileHolding(int gen) async {
    while (_live(gen) && !_aborted && state!.holding) {
      final w = _resumeWait ??= Completer<void>();
      await w.future;
    }
  }

  /// Waits until every mains unit of the run was heard since the board
  /// restarted and the mesh has its root again, for at most
  /// [DeviceUpdateTimings.meshBack]. Then it goes on: a unit still missing
  /// fails on its own offer and says so.
  Future<void> _waitMeshBack(int gen) async {
    final since = _boardRestartedAt;
    if (since == null || _meshBack(since)) return;
    _set((r) => r.copyWith(
        stage: DeviceUpdateStage.reconnecting, boardRestartedAt: since));
    final until = _clock().add(_t.meshBack);
    while (_live(gen) && !_aborted && _clock().isBefore(until)) {
      await Future<void>.delayed(_t.meshPoll);
      if (_meshBack(since)) break;
    }
  }

  /// The mains units of the run were heard after [since], and the mesh has
  /// a settled root.
  bool _meshBack(DateTime since) {
    if (_ref.read(rootElectionProvider).electing) return false;
    final nodes = _ref.read(topologyProvider);
    final queued = state!.queues[SafrProductFamily.node] ?? const <String>[];
    // A detector run: the nodes the detectors hang off.
    final wanted = queued.isNotEmpty
        ? queued.toSet()
        : {
            for (final n in nodes)
              if (n.layer > 0 &&
                  n.online &&
                  unitFamily(n) == SafrProductFamily.node)
                n.mac,
          };
    for (final n in nodes) {
      if (wanted.contains(n.mac) && !n.lastSeenAt.isAfter(since)) return false;
    }
    return true;
  }

  /// An alarm latched: nothing new starts until the operator resets the
  /// panel and taps "Retomar".
  Future<void> _waitNoAlarm(int gen) async {
    if (!_live(gen) || !_ref.read(activeAlarmProvider)) return;
    state = state!.copyWith(
      holding: true,
      pausedBy: OtaPauseCause.alarm,
      message: 'Há alarme ativo. Rearme a central e toque em Retomar.',
    );
    await _waitWhileHolding(gen);
  }

  void _release() {
    final w = _resumeWait;
    _resumeWait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  // ── What the board says ──────────────────────────────────────────────────

  void _onPush(OtaPushState s) {
    final wait = _pushWait;
    if (wait != null && !wait.isCompleted) {
      switch (s.phase) {
        case OtaPushPhase.confirmed:
        case OtaPushPhase.stored:
        case OtaPushPhase.rolledBack:
        case OtaPushPhase.failed:
          wait.complete(s.phase);
        default:
          break;
      }
    }
    // The board's own update: its row follows the push.
    final run = state;
    if (run == null ||
        run.stage != DeviceUpdateStage.pushing ||
        run.family != SafrProductFamily.board) {
      return;
    }
    final next = switch (s.phase) {
      OtaPushPhase.switchingSpeed || OtaPushPhase.sending => (
          SafrOtaUnitState.downloading,
          (s.progress * 100).round()
        ),
      OtaPushPhase.verifying => (SafrOtaUnitState.verifying, 100),
      OtaPushPhase.boardRestarting => (SafrOtaUnitState.rebooting, 100),
      _ => null,
    };
    if (s.phase == OtaPushPhase.boardRestarting &&
        _restartSeenFor != s.startedAt) {
      // About now the board went down, and its access point with it.
      _restartSeenFor = s.startedAt;
      _boardRestartedAt = _clock();
      state = state!.copyWith(boardRestartedAt: _boardRestartedAt);
    }
    if (next == null) return;
    _setUnit(deviceUpdateBoardKey,
        (u) => u.copyWith(state: next.$1, percent: next.$2));
  }

  void _onRollout(OtaRolloutState s) {
    final run = state;
    final wait = _rolloutWait;
    if (run == null || wait == null || !run.running) return;
    final f = s.families[wait.family];
    if (f == null) return;
    // Only what belongs to the rollout this run started.
    final fresh = f.startedAt != null && !f.startedAt!.isBefore(wait.since);
    final units = Map.of(run.units);
    var queue = run.queues[wait.family] ?? const <String>[];
    for (final row in f.units) {
      if (!fresh && row.changedAt.isBefore(wait.since)) continue;
      final byUnit = wait.filter.kind == SafrOtaFilterKind.unit;
      if (byUnit && !wait.keys.contains(row.mac)) continue;
      final had = units[row.mac] ??
          DeviceUpdateUnit(
            key: row.mac,
            family: wait.family,
            versionBefore: row.versionBefore ?? row.version,
            version: row.version,
          );
      if (!queue.contains(row.mac)) queue = [...queue, row.mac];
      units[row.mac] = had.copyWith(
        state: row.state,
        percent: row.percent,
        attempts: math.max(row.attempts, 0),
        reasonRaw: row.reasonRaw,
        version: row.version.isEmpty ? had.version : row.version,
        note: null,
      );
    }
    final pausedByBoard = fresh && f.state == SafrOtaRolloutState.paused
        ? (f.pauseCause ?? OtaPauseCause.unknown)
        : null;
    state = run.copyWith(
      units: units,
      queues: {...run.queues, wait.family: queue},
      pausedBy: pausedByBoard ??
          (run.pausedBy == OtaPauseCause.alarm && run.holding
              ? OtaPauseCause.alarm
              : null),
    );
    final settled = wait.keys.every((k) => units[k]?.state.settled == true);
    if (f.ended && (fresh || settled) && !wait.done.isCompleted) {
      wait.done.complete(true);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  List<String> _pending(SafrProductFamily fam) => [
        for (final u in state!.unitsOf(fam))
          if (u.state == SafrOtaUnitState.waiting) u.key,
      ];

  void _markWaitingSkipped() {
    final run = state;
    if (run == null) return;
    final units = {
      for (final e in run.units.entries)
        e.key: e.value.state == SafrOtaUnitState.waiting
            ? e.value.copyWith(
                state: SafrOtaUnitState.skipped,
                note: 'A atualização foi interrompida antes de chegar a este '
                    'dispositivo.')
            : e.value,
    };
    state = run.copyWith(units: units);
  }

  void _set(DeviceUpdateRun Function(DeviceUpdateRun r) f) {
    final run = state;
    if (run != null) state = f(run);
  }

  void _setUnit(String key, DeviceUpdateUnit Function(DeviceUpdateUnit u) f) {
    final run = state;
    final u = run?.units[key];
    if (run == null || u == null) return;
    state = run.copyWith(units: {...run.units, key: f(u)});
  }

  /// What the unit with [key] runs, as the tablet heard it.
  String _versionOf(String key) {
    for (final n in _ref.read(topologyProvider)) {
      final isIt = key == deviceUpdateBoardKey
          ? unitFamily(n) == SafrProductFamily.board
          : n.mac == key;
      if (isIt) return n.fwVersion ?? '';
    }
    return '';
  }

  /// Units of [family] the tablet hears now, in map order, the root last.
  List<String> _online(SafrProductFamily family) => _rootLast([
        for (final n in _ref.read(topologyProvider))
          if (n.layer > 0 && n.online && unitFamily(n) == family) n.mac,
      ]);

  /// The next unit of [fam] to offer, from the map as it is now: the deepest
  /// first (a unit restarting never cuts off one still waiting below it),
  /// the mesh root last; null when none waits.
  String? _nextUnit(SafrProductFamily fam, Set<String> tried) {
    final waiting = [
      for (final k in _pending(fam))
        if (!tried.contains(k)) k,
    ];
    if (waiting.isEmpty) return null;
    final layer = {
      for (final n in _ref.read(topologyProvider)) n.mac: n.layer,
    };
    final root = _rootMac();
    int rank(String k) => k == root ? -1 : (layer[k] ?? 0);
    final order = [...waiting];
    // Stable: same depth keeps the order of the queue.
    final index = {for (var i = 0; i < waiting.length; i++) waiting[i]: i};
    order.sort((a, b) {
      final byDepth = rank(b).compareTo(rank(a));
      return byDepth != 0 ? byDepth : index[a]!.compareTo(index[b]!);
    });
    return order.first;
  }

  /// The mesh root: the settled election's, else the one unit at layer 1
  /// (the election may not have settled yet when the run starts).
  String? _rootMac() {
    final elected = _ref.read(rootElectionProvider).rootMac;
    if (elected != null) return elected;
    final first = [
      for (final n in _ref.read(topologyProvider))
        if (n.layer == 1 && n.online) n.mac,
    ];
    return first.length == 1 ? first.single : null;
  }

  List<String> _rootLast(Iterable<String> keys) {
    final root = _rootMac();
    final list = keys.toList();
    if (root != null && list.remove(root)) list.add(root);
    return list;
  }
}

class _RolloutWait {
  _RolloutWait(this.family, this.since, this.keys, this.filter);
  final SafrProductFamily family;
  final DateTime since;
  final List<String> keys;
  final SafrOtaFilter filter;
  final done = Completer<bool>();
}

final deviceUpdateTimingsProvider =
    Provider<DeviceUpdateTimings>((_) => const DeviceUpdateTimings());

final deviceUpdateProvider =
    StateNotifierProvider<DeviceUpdateController, DeviceUpdateRun?>(
  (ref) => DeviceUpdateController(ref,
      timings: ref.read(deviceUpdateTimingsProvider)),
);
