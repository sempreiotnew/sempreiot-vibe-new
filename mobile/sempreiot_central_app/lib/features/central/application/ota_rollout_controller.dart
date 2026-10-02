import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'ota_board_events_provider.dart';
import 'ota_push_controller.dart';
import 'ota_push_state.dart' show OtaLogLine;
import 'ota_rollout_events_provider.dart';
import 'ota_rollout_state.dart';
import 'ota_rollout_words.dart';
import 'safr_downlink_provider.dart';
import 'serial_link_provider.dart';

/// The rollout (docs/safr/protocol-safr-v3.md §13.6): the board sends the
/// image it holds to the units, one at a time, the root last; the tablet
/// starts it, steers it and shows it.
///
///   GET_ROLLOUT → OTA_ROLLOUT pages: what the board holds and where every
///   unit is; OTA_CONTROL: start / pause / resume / abort; OTA_STATUS and
///   OTA_RESULT of the units refine a row between two pages of the board.
///
/// The board's table is the one that counts: a page replaces what the units
/// said. Nothing here is stored: after an app restart everything is learned
/// again from the board.
///
/// The controller lives as long as the app. Building it touches neither the
/// serial port nor the database; both are used when there is something to
/// ask or to write down.
class OtaRolloutController extends StateNotifier<OtaRolloutState> {
  OtaRolloutController(
    this._ref, {
    OtaRolloutTimings? timings,
    DateTime Function()? clock,
  })  : _t = timings ?? const OtaRolloutTimings(),
        _clock = clock ?? DateTime.now,
        super(const OtaRolloutState()) {
    _events = _ref.read(otaRolloutBusProvider).stream.listen(_enqueue);
    _boardEvents = _ref.read(otaBoardBusProvider).stream.listen(_onBoardEvent);
    // The downlink finished what it says when the link comes up: ask now.
    _ref.listen<int>(linkUpSequenceProvider, (_, __) {
      _answeredThisLink = false;
      refresh();
    });
  }

  /// Lines the log keeps; the oldest leave first.
  static const logCapacity = 600;

  final Ref _ref;
  final OtaRolloutTimings _t;
  final DateTime Function() _clock;
  late final StreamSubscription<OtaRolloutEvent> _events;
  late final StreamSubscription<OtaBoardEvent> _boardEvents;

  /// Events are handled one at a time, in the order they arrived.
  Future<void> _queue = Future<void>.value();

  /// Pages of a set that is not complete yet, by family.
  final _sets = <SafrProductFamily, _PageSet>{};
  Timer? _setTimer;

  Timer? _answerTimer;
  Timer? _afterControlTimer;
  Timer? _watchdog;
  Timer? _pauseCauseTimer;

  /// A page arrived since the link last came up.
  bool _answeredThisLink = false;

  /// When the last page of any family arrived.
  DateTime? _lastPageAt;

  /// What this session asked of the board and the board accepted.
  final _startedHere = <SafrProductFamily, ({DateTime at, SafrOtaFilter filter})>{};
  DateTime? _pauseAskedAt;
  bool _abortAsked = false;

  /// MAC → name, for the log.
  final _names = <String, String>{};

  /// MAC → what the log last said of it.
  final _said = <String, String>{};

  DateTime? _silenceLoggedFor;
  DateTime? _lastStrayRefresh;

  SafrDownlink get _downlink => _ref.read(safrDownlinkProvider);
  bool get _linkUp =>
      _ref.read(serialLinkProvider) == SerialLinkStatus.connected;

  /// For how long a unit in an active state is UPDATING instead of missing.
  Duration get updatingGrace => _t.updatingGrace;

  // ── Asking ───────────────────────────────────────────────────────────────

  /// GET_ROLLOUT: asks the board what it holds and where its rollout is.
  /// Sent when the link comes up (after GET_DEVICE_TABLE), when the update
  /// screen opens, after an image was stored, and while a rollout runs and
  /// the board is silent.
  Future<void> refresh() async {
    if (!mounted || !_linkUp) return;
    final sent = await _downlink.sendGetRollout();
    if (!mounted || !sent) return;
    state = state.copyWith(asking: true);
    _answerTimer?.cancel();
    _answerTimer = Timer(_t.answerTimeout, _noAnswer);
    unawaited(_loadNames());
  }

  void _noAnswer() {
    if (!mounted || !state.asking) return;
    if (_answeredThisLink) {
      // It answered before on this link: a frame was lost, or it has
      // nothing new to say. What is known stays.
      state = state.copyWith(asking: false);
      return;
    }
    final first = state.boardAnswered != false;
    _sets.clear();
    state = state.copyWith(
      asking: false,
      boardAnswered: false,
      families: const {},
    );
    _stopWatchdog();
    if (first) {
      _log('A placa não respondeu ao pedido da tabela de atualização '
          '(GET_ROLLOUT). O que ela guarda é o que este tablet enviou nesta '
          'sessão.');
    }
  }

  void _onBoardEvent(OtaBoardEvent event) {
    // An image was verified and stored: the board holds something new.
    if (event is OtaPushResultEvent &&
        event.result.phase == SafrOtaPushPhase.ok &&
        event.result.family != SafrProductFamily.board.wire) {
      refresh();
    }
  }

  // ── Steering ─────────────────────────────────────────────────────────────

  /// Why a rollout of [family] cannot start now, or null when it can.
  /// Never while an alarm is latched: the units restart one at a time.
  Future<String?> startBlocker(SafrProductFamily family) async {
    if (family != SafrProductFamily.node && family != SafrProductFamily.leaf) {
      return 'Este tipo de firmware não é enviado aos dispositivos.';
    }
    if (!_linkUp) return 'A placa não está respondendo. Verifique o cabo USB.';
    if (state.command != null) return 'Aguarde a resposta da placa.';
    if (state.running != null) return 'Já há uma atualização em andamento.';
    if (_ref.read(otaPushProvider).running) {
      return 'Aguarde o envio do arquivo à placa terminar.';
    }
    if (state.boardAnswered == true &&
        state.families[family]?.holdsImage != true) {
      return 'A placa não tem imagem guardada para este tipo de dispositivo.';
    }
    if (await _anyAlarmLatched()) {
      return 'Há alarme ativo. Rearme a central antes de atualizar os '
          'dispositivos.';
    }
    return null;
  }

  /// Starts the rollout of the image of [family] the board holds, to the
  /// units [filter] lets through. [expected]: how many units the tablet
  /// counts for that filter, for the log; the board makes its own queue.
  /// Returns why not, or null when the board accepted.
  Future<String?> start(
    SafrProductFamily family,
    SafrOtaFilter filter, {
    int? expected,
    String? filterText,
  }) async {
    final blocker = await startBlocker(family);
    if (blocker != null) {
      _log('Envio aos dispositivos não iniciado: $blocker');
      return blocker;
    }
    if (!mounted) return 'A atualização foi encerrada.';
    final target = state.families[family]?.target ?? '';
    _log('Pedido à placa: enviar ${otaFirmwareWord(family)}'
        '${target.isEmpty ? '' : ' $target'} aos dispositivos — filtro: '
        '${filterText ?? otaFilterText(filter)}'
        '${expected == null ? '' : '; $expected ${expected == 1 ? 'dispositivo' : 'dispositivos'} pelo registro do tablet'}');
    final refused = await _control(SafrOtaAction.start, family, filter);
    if (refused != null) return refused;
    _startedHere[family] = (at: _clock(), filter: filter);
    _abortAsked = false;
    _pauseAskedAt = null;
    return null;
  }

  /// No new offer; the unit that is downloading finishes.
  Future<String?> pause(SafrProductFamily family) async {
    if (!_linkUp) return 'A placa não está respondendo. Verifique o cabo USB.';
    if (state.command != null) return 'Aguarde a resposta da placa.';
    _log('Pedido à placa: pausar a atualização');
    final refused =
        await _control(SafrOtaAction.pause, family, const SafrOtaFilter.all());
    if (refused == null) _pauseAskedAt = _clock();
    return refused;
  }

  /// Goes on from the first unit that is not settled. Not while an alarm is
  /// latched (§13.1 rule 4).
  Future<String?> resume(SafrProductFamily family) async {
    if (!_linkUp) return 'A placa não está respondendo. Verifique o cabo USB.';
    if (state.command != null) return 'Aguarde a resposta da placa.';
    if (await _anyAlarmLatched()) {
      const text = 'Há alarme ativo. Rearme a central antes de retomar a '
          'atualização.';
      _log('Atualização não retomada: $text');
      return text;
    }
    _log('Pedido à placa: retomar a atualização');
    final refused =
        await _control(SafrOtaAction.resume, family, const SafrOtaFilter.all());
    if (refused == null) _pauseAskedAt = null;
    return refused;
  }

  /// No new offer; the units still waiting are skipped.
  Future<String?> abort(SafrProductFamily family) async {
    if (!_linkUp) return 'A placa não está respondendo. Verifique o cabo USB.';
    if (state.command != null) return 'Aguarde a resposta da placa.';
    _log('Pedido à placa: cancelar a atualização');
    final refused =
        await _control(SafrOtaAction.abort, family, const SafrOtaFilter.all());
    if (refused == null) _abortAsked = true;
    return refused;
  }

  Future<String?> _control(
    SafrOtaAction action,
    SafrProductFamily family,
    SafrOtaFilter filter,
  ) async {
    state = state.copyWith(command: action);
    final asked = _clock();
    final SafrAckPayload? ack;
    try {
      ack = await _downlink.sendOtaControl(
        SafrOtaControlArgs(action: action, family: family.wire, filter: filter),
        ackTimeout: _t.controlAckTimeout,
        attempts: _t.controlAttempts,
      );
    } on ArgumentError catch (e) {
      if (mounted) state = state.copyWith(command: null);
      _log('Pedido não enviado: ${e.message}');
      return 'O filtro escolhido não pode ser enviado à placa.';
    }
    if (!mounted) return 'A atualização foi encerrada.';
    state = state.copyWith(command: null);

    if (ack == null) {
      const text = 'A placa não respondeu ao pedido. O firmware dela pode não '
          'enviar atualizações aos dispositivos.';
      _log('${otaActionWord(action)}: sem resposta da placa');
      return text;
    }
    if (ack.status != SafrAckStatus.ok) {
      final text = otaControlRefusal(action, ack.otaReason);
      _log('${otaActionWord(action)} recusado pela placa: '
          '${otaReasonLogText(ack.detailRaw)}');
      return text;
    }
    _log('${otaActionWord(action)}: a placa aceitou');

    // Its table changed: it sends it. If it does not, the tablet asks.
    _afterControlTimer?.cancel();
    _afterControlTimer = Timer(_t.pageAfterControl, () {
      final last = _lastPageAt;
      if (mounted && (last == null || last.isBefore(asked))) refresh();
    });
    return null;
  }

  // ── What the board and the units say ─────────────────────────────────────

  void _enqueue(OtaRolloutEvent event) {
    _queue = _queue.then((_) async {
      if (!mounted) return;
      try {
        switch (event) {
          case OtaRolloutPageEvent(:final page):
            await _onPage(page);
          case OtaUnitStatusEvent(:final mac, :final status):
            await _onStatus(mac, status);
          case OtaUnitResultEvent(:final mac, :final result):
            await _onResult(mac, result);
        }
      } catch (e, st) {
        debugPrint('[OTA] rollout event failed: $e\n$st');
      }
    });
  }

  /// Everything that arrived so far was handled.
  @visibleForTesting
  Future<void> get settled => _queue;

  Future<void> _onPage(SafrOtaRolloutPayload page) async {
    final now = _clock();
    _lastPageAt = now;
    _answeredThisLink = true;
    _answerTimer?.cancel();
    _silenceLoggedFor = null;
    if (state.boardAnswered != true || state.asking) {
      state = state.copyWith(boardAnswered: true, asking: false);
    }

    final family = page.productFamily;
    if (family == SafrProductFamily.unknown) {
      // "Nothing at all" (idle, no family) is an answer too; anything else
      // under a family this app does not know is left alone.
      return;
    }

    var set = _sets[family];
    if (page.page == 1) {
      set = _sets[family] = _PageSet(page.pageCount);
    } else if (set == null ||
        set.next != page.page ||
        set.pageCount != page.pageCount) {
      // A page of the set is missing: the header is good, the rows are
      // not. Ask for the whole table again.
      _sets.remove(family);
      await _apply(family, page, null, now);
      _log('Tabela da placa incompleta (página ${page.page} de '
          '${page.pageCount} fora de ordem); pedindo de novo');
      unawaited(refresh());
      return;
    }
    set
      ..entries.addAll(page.entries)
      ..next = page.page + 1
      ..last = page;

    if (!page.isLastPage) {
      _setTimer?.cancel();
      _setTimer = Timer(_t.pageSetTimeout, _setTimedOut);
      return;
    }
    _sets.remove(family);
    if (_sets.isEmpty) _setTimer?.cancel();
    await _apply(family, page, set.entries, now);
  }

  void _setTimedOut() {
    if (!mounted || _sets.isEmpty) return;
    final stale = Map.of(_sets);
    _sets.clear();
    _queue = _queue.then((_) async {
      if (!mounted) return;
      for (final e in stale.entries) {
        final last = e.value.last;
        if (last != null) await _apply(e.key, last, null, _clock());
      }
      _log('Tabela da placa incompleta (faltou página); pedindo de novo');
      unawaited(refresh());
    });
  }

  /// The header of [page] and, when the set is complete, its [entries] in
  /// place of the rows there were. Null [entries]: the rows stay.
  Future<void> _apply(
    SafrProductFamily family,
    SafrOtaRolloutPayload page,
    List<SafrOtaRolloutEntry>? entries,
    DateTime now,
  ) async {
    final old = state.families[family];

    if (page.state == SafrOtaRolloutState.idle) {
      if (old == null) return;
      state = state.copyWith(families: {...state.families}..remove(family));
      _log('Placa: nenhuma imagem de ${otaFirmwareWord(family)} guardada, '
          'nenhuma atualização');
      _syncWatchdog();
      return;
    }

    if (entries != null) await _ensureNames(entries.map((e) => e.mac));
    if (!mounted) return;

    final wasRunning = old?.running ?? false;
    final first = old == null;
    final oldRows = <String, OtaRolloutUnit>{
      for (final u in old?.units ?? const <OtaRolloutUnit>[]) u.mac: u,
    };
    // A rollout that starts has the rows of no rollout before it.
    final sameRollout = old != null &&
        old.target == page.target &&
        !(old.ended && page.state.running) &&
        old.state != SafrOtaRolloutState.staged;
    final units = entries == null
        ? (sameRollout ? old.units : const <OtaRolloutUnit>[])
        : [
            for (final e in entries)
              _row(e, sameRollout ? oldRows[e.mac] : null, old, now),
          ];

    // When it started.
    DateTime? startedAt = sameRollout ? old.startedAt : null;
    var exact = sameRollout && old.startedAtExact;
    SafrOtaFilter? filter = sameRollout ? old.filter : null;
    if (page.state.running || page.state.ended) {
      final here = _startedHere[family];
      if (here != null && (!sameRollout || old.filter == null)) {
        filter = here.filter;
        if (!exact) {
          startedAt = here.at;
          exact = true;
        }
      }
      if (startedAt == null) {
        if (old != null && page.state.running) {
          // Seen starting, by somebody else's hand.
          startedAt = now;
          exact = true;
        } else {
          startedAt = _oldestChange(units, now);
        }
      }
    } else {
      startedAt = null;
      exact = false;
    }

    final endedAt = page.state.ended
        ? (wasRunning ? now : (sameRollout ? old.endedAt : null))
        : null;

    OtaPauseCause? cause;
    if (page.state == SafrOtaRolloutState.paused) {
      cause = old?.state == SafrOtaRolloutState.paused
          ? old!.pauseCause
          : await _pauseCause(now);
      if (!mounted) return;
    }

    final next = OtaFamilyRollout(
      family: family,
      state: page.state,
      target: page.target,
      total: page.total,
      units: units,
      updatedAt: now,
      startedAt: startedAt,
      startedAtExact: exact,
      endedAt: endedAt,
      pauseCause: cause,
      filter: filter,
    );
    state = state.copyWith(families: {...state.families, family: next});

    _sayHeader(old, next, first: first);
    if (entries != null) _sayRows(old, next, sameRollout: sameRollout);
    if (next.ended && wasRunning) _sayEnd(next);
    if (next.ended || next.state == SafrOtaRolloutState.staged) {
      _startedHere.remove(family);
    }
    if (cause == OtaPauseCause.unknown &&
        old?.state != SafrOtaRolloutState.paused) {
      _recheckPauseCause(family);
    }
    _syncWatchdog();
  }

  OtaRolloutUnit _row(
    SafrOtaRolloutEntry e,
    OtaRolloutUnit? prev,
    OtaFamilyRollout? old,
    DateTime now,
  ) {
    final age = e.ageS;
    final changedAt = age == null
        ? (prev?.changedAt ?? now)
        : now.subtract(Duration(seconds: age));

    DateTime? activeSince;
    if (e.state.active) {
      final sameOffer = prev != null &&
          prev.state.active &&
          prev.activeSince != null &&
          (prev.live || prev.attempts == e.attempts);
      if (sameOffer) {
        activeSince = prev.activeSince;
      } else {
        // It entered an active state no later than its last change, and —
        // when the tablet saw it outside them — no earlier than that.
        activeSince = age == null ? now : changedAt;
        final seenOutside = prev != null ? old?.updatedAt : null;
        if (seenOutside != null && activeSince.isBefore(seenOutside)) {
          activeSince = seenOutside;
        }
      }
    }

    final before = prev?.versionBefore ??
        (e.state == SafrOtaUnitState.done || e.version.isEmpty
            ? null
            : e.version);

    return OtaRolloutUnit(
      mac: e.mac,
      productCode: e.productCode,
      state: e.state,
      percent: e.percent,
      attempts: e.attempts,
      reasonRaw: e.reasonRaw,
      version: e.version.isNotEmpty ? e.version : (prev?.version ?? ''),
      versionBefore: before,
      changedAt: changedAt,
      activeSince: activeSince,
    );
  }

  static DateTime _oldestChange(List<OtaRolloutUnit> units, DateTime now) {
    var oldest = now;
    for (final u in units) {
      if (u.state != SafrOtaUnitState.waiting && u.changedAt.isBefore(oldest)) {
        oldest = u.changedAt;
      }
    }
    return oldest;
  }

  Future<OtaPauseCause> _pauseCause(DateTime now) async {
    final asked = _pauseAskedAt;
    if (asked != null && now.difference(asked) < const Duration(seconds: 30)) {
      return OtaPauseCause.operator;
    }
    return await _anyAlarmLatched()
        ? OtaPauseCause.alarm
        : OtaPauseCause.unknown;
  }

  /// The ALARM that paused the board may reach the database a moment after
  /// the board's page: look once more.
  void _recheckPauseCause(SafrProductFamily family) {
    _pauseCauseTimer?.cancel();
    _pauseCauseTimer = Timer(const Duration(seconds: 2), () async {
      if (!mounted) return;
      final latched = await _anyAlarmLatched();
      if (!mounted || !latched) return;
      final f = state.families[family];
      if (f == null ||
          f.state != SafrOtaRolloutState.paused ||
          f.pauseCause != OtaPauseCause.unknown) {
        return;
      }
      state = state.copyWith(families: {
        ...state.families,
        family: f.copyWith(pauseCause: OtaPauseCause.alarm),
      });
      _log('A pausa foi por alarme: há alarme ativo na instalação');
    });
  }

  Future<void> _onStatus(String mac, SafrOtaStatusPayload status) async {
    await _ensureNames([mac]);
    if (!mounted) return;
    final now = _clock();
    final found = _find(mac);
    if (found == null) {
      _sayUnit(mac, 'estado', otaUnitStateLog(status.state, status.percent));
      _strayFrame();
      return;
    }
    final (family, row) = found;
    // The board settled it, or is ahead: its table is the one that counts.
    if (row.state.settled && !row.live) return;
    final ahead = status.state.wire > row.state.wire ||
        (status.state == row.state && status.percent > row.percent);
    if (!ahead) return;

    _replace(
      family,
      row.copyWith(
        state: status.state,
        percent: status.percent,
        changedAt: now,
        activeSince:
            status.state.active ? (row.activeSince ?? now) : null,
        live: true,
      ),
    );
    _sayUnit(mac, 'estado', otaUnitStateLog(status.state, status.percent));
  }

  Future<void> _onResult(String mac, SafrOtaResultPayload result) async {
    await _ensureNames([mac]);
    if (!mounted) return;
    final now = _clock();
    final version = result.version;
    final text = result.ok
        ? 'atualizado${version.isEmpty ? '' : ', agora na versão $version'}'
        : 'não atualizado, ${otaReasonLogText(result.reasonRaw)}'
            '${result.detail == 0 ? '' : ' — reinício: ${otaResetReasonText(result.detail)}'}'
            '${version.isEmpty ? '' : '; continua na versão $version'}';
    _sayUnit(mac, 'resultado', text, always: true);

    final found = _find(mac);
    if (found == null) {
      _strayFrame();
      return;
    }
    final (family, row) = found;
    if (row.state.settled && !row.live) return;
    final state = result.ok
        ? SafrOtaUnitState.done
        : result.reason == SafrOtaReason.notNewer
            ? SafrOtaUnitState.skipped
            : SafrOtaUnitState.failed;
    _replace(
      family,
      row.copyWith(
        state: state,
        percent: result.ok ? 100 : row.percent,
        reasonRaw: result.ok ? 0 : result.reasonRaw,
        version: version.isEmpty ? row.version : version,
        changedAt: now,
        activeSince: null,
        live: true,
      ),
    );
  }

  /// A unit talks about an update the tablet knows nothing of: ask the
  /// board, not more than once in a while.
  void _strayFrame() {
    final now = _clock();
    final last = _lastStrayRefresh;
    if (last != null && now.difference(last) < _t.rollingSilence) return;
    _lastStrayRefresh = now;
    refresh();
  }

  /// The row of [mac] in the rollout that runs, else in any.
  (SafrProductFamily, OtaRolloutUnit)? _find(String mac) {
    (SafrProductFamily, OtaRolloutUnit)? found;
    for (final f in state.families.values) {
      final u = f.unit(mac);
      if (u == null) continue;
      if (f.running) return (f.family, u);
      found ??= (f.family, u);
    }
    return found;
  }

  void _replace(SafrProductFamily family, OtaRolloutUnit row) {
    final f = state.families[family];
    if (f == null) return;
    state = state.copyWith(families: {
      ...state.families,
      family: f.copyWith(units: [
        for (final u in f.units) u.mac == row.mac ? row : u,
      ]),
    });
  }

  // ── The watchdog ─────────────────────────────────────────────────────────

  void _syncWatchdog() {
    final rolling = state.families.values
        .any((f) => f.state == SafrOtaRolloutState.rolling);
    if (!rolling) {
      _stopWatchdog();
      return;
    }
    _watchdog ??= Timer.periodic(_t.watchdogPeriod, (_) => _watch());
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// While a rollout is rolling the board sends its table every 5 s.
  void _watch() {
    if (!mounted || !_linkUp || state.asking) return;
    final now = _clock();
    for (final f in state.families.values) {
      if (f.state != SafrOtaRolloutState.rolling) continue;
      if (now.difference(f.updatedAt) < _t.rollingSilence) continue;
      if (_silenceLoggedFor != f.updatedAt) {
        _silenceLoggedFor = f.updatedAt;
        _log('Sem notícias da placa há '
            '${now.difference(f.updatedAt).inSeconds} s; perguntando '
            '(GET_ROLLOUT)');
      }
      refresh();
      return;
    }
  }

  // ── The log ──────────────────────────────────────────────────────────────

  void _sayHeader(OtaFamilyRollout? old, OtaFamilyRollout next,
      {required bool first}) {
    final name = otaFirmwareWord(next.family);
    final was = old?.state;
    final now = next.state;
    if (was == now && old?.target == next.target) return;

    switch (now) {
      case SafrOtaRolloutState.staged:
        _log('Na placa: $name ${next.target} (nada enviado aos dispositivos)');
      case SafrOtaRolloutState.rolling:
        if (was == SafrOtaRolloutState.paused) {
          _log('Placa: atualização retomada');
        } else {
          final n = next.unitCount;
          _log(first
              ? 'Placa: atualização em andamento — $name ${next.target}, '
                  '$n ${n == 1 ? 'dispositivo' : 'dispositivos'}'
              : 'Placa: atualização iniciada — $name ${next.target}, '
                  '$n ${n == 1 ? 'dispositivo' : 'dispositivos'}, um de cada '
                  'vez');
        }
      case SafrOtaRolloutState.paused:
        _log('Placa: atualização pausada — '
            '${otaPauseCauseText(next.pauseCause ?? OtaPauseCause.unknown)}');
      case SafrOtaRolloutState.done || SafrOtaRolloutState.partial:
        if (!(old?.running ?? false)) {
          _log('Placa: atualização de $name ${next.target} '
              '${now == SafrOtaRolloutState.done ? 'concluída' : 'parcial'} '
              '(${otaCountsText(next)})');
        }
      case SafrOtaRolloutState.idle:
        break;
    }
  }

  void _sayRows(OtaFamilyRollout? old, OtaFamilyRollout next,
      {required bool sameRollout}) {
    if (!next.running && !next.ended) return;
    if (!sameRollout && old == null && next.units.isNotEmpty) {
      // Learned in the middle of it: where everybody is, in one line each.
      for (final u in next.units) {
        _said[u.mac] = _key(u);
        _log('${_unitName(u.mac)}: ${otaUnitRowLog(u)}');
      }
      return;
    }
    if (!sameRollout) {
      for (final u in next.units) {
        _said.remove(u.mac);
      }
    }
    for (final u in next.units) {
      final key = _key(u);
      if (_said[u.mac] == key) continue;
      final before = _said[u.mac];
      _said[u.mac] = key;
      // A rollout that starts: everybody waits, the header said how many.
      if (before == null && u.state == SafrOtaUnitState.waiting) continue;
      _log('${_unitName(u.mac)}: ${otaUnitRowLog(u)}');
    }
  }

  void _sayEnd(OtaFamilyRollout f) {
    _log('Atualização '
        '${_abortAsked ? 'cancelada' : f.state == SafrOtaRolloutState.done ? 'concluída' : 'concluída com falhas'}'
        ': ${otaCountsText(f)}'
        '${f.startedAt == null ? '' : ', em ${_duration(_clock().difference(f.startedAt!))}'}');
    for (final u in f.failures) {
      _log('Falhou: ${_unitName(u.mac)} — '
          '${otaReasonLogText(u.reasonRaw)}'
          '${u.version.isEmpty ? '' : '; continua na versão ${u.version}'}');
    }
    _abortAsked = false;
  }

  void _sayUnit(String mac, String what, String text, {bool always = false}) {
    final key = '$what:$text';
    if (!always && _said['$mac/live'] == key) return;
    _said['$mac/live'] = key;
    _log('${_unitName(mac)} → $what: $text');
  }

  static String _key(OtaRolloutUnit u) =>
      '${u.state.wire}/${u.percent ~/ 10}/${u.attempts}/${u.reasonRaw}';

  String _unitName(String mac) {
    final name = _names[mac];
    return name == null || name.isEmpty ? mac : '$name [$mac]';
  }

  void _log(String text) {
    if (!mounted) return;
    debugPrint('[OTA] $text');
    final log = state.log.length >= logCapacity
        ? state.log.sublist(state.log.length - logCapacity + 1)
        : state.log;
    state = state.copyWith(log: [...log, OtaLogLine(_clock(), text)]);
  }

  /// Forgets the log. What the board said stays.
  void clearLog() {
    state = state.copyWith(log: const []);
  }

  static String _duration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} s';
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '${d.inMinutes} min $s s';
  }

  // ── The database: names and the alarm latch ──────────────────────────────

  Future<void> _ensureNames(Iterable<String> macs) async {
    if (macs.every(_names.containsKey)) return;
    await _loadNames();
    for (final m in macs) {
      _names.putIfAbsent(m, () => '');
    }
  }

  Future<void> _loadNames() async {
    try {
      final db = _ref.read(appDatabaseProvider);
      final rows = await db.select(db.meshDevices).get();
      for (final r in rows) {
        final name = r.name;
        if (name != null && name.isNotEmpty) _names[r.mac] = name;
      }
    } catch (e) {
      debugPrint('[OTA] names not read: $e');
    }
  }

  Future<bool> _anyAlarmLatched() async {
    final db = _ref.read(appDatabaseProvider);
    final row = await (db.select(db.meshDevices)
          ..where((t) => t.alarmLatched.equals(1))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  @override
  void dispose() {
    _events.cancel();
    _boardEvents.cancel();
    _answerTimer?.cancel();
    _afterControlTimer?.cancel();
    _setTimer?.cancel();
    _pauseCauseTimer?.cancel();
    _stopWatchdog();
    super.dispose();
  }
}

class _PageSet {
  _PageSet(this.pageCount);
  final int pageCount;
  int next = 1;
  final entries = <SafrOtaRolloutEntry>[];
  SafrOtaRolloutPayload? last;
}

/// Timeouts of the rollout; tests override it with short ones.
final otaRolloutTimingsProvider =
    Provider<OtaRolloutTimings>((ref) => const OtaRolloutTimings());

final otaRolloutProvider =
    StateNotifierProvider<OtaRolloutController, OtaRolloutState>((ref) {
  return OtaRolloutController(
    ref,
    timings: ref.watch(otaRolloutTimingsProvider),
  );
});
