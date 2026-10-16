import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart' show safrBroadcastMac;
import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'central_mirror_viewer.dart';
import 'device_led_provider.dart';
import 'device_sound_provider.dart';
import 'safr_downlink_provider.dart';
import 'safr_traffic_provider.dart';
import 'central_mirror_codec.dart' show MirrorTests;
import 'system_test_provider.dart' show mirrorTestsProvider;
import 'topology_provider.dart';
import '../domain/system_test/system_test_run.dart';

/// What an operator commands a unit to do from the Rede map.
///
/// The last three go the other way: something the UNIT sent that the
/// central confirms — its TEST button, an alarm, any other event. Same
/// ticks, the other side of the conversation: ✓ the central received it,
/// ✓✓ the central's ACK went back (the unit's LED turns cyan on it).
enum DeviceCommandKind {
  identify('Identificar'),
  test('Testar'),
  soundOff('Silenciar'),
  soundOn('Ligar som'),
  reset('Rearmar'),
  unitTest('Teste da unidade', fromUnit: true),
  unitAlarm('Alarme', fromUnit: true),
  unitEvent('Evento', fromUnit: true);

  const DeviceCommandKind(this.label, {this.fromUnit = false});
  final String label;

  /// Sent by the unit, confirmed by the central (not a command).
  final bool fromUnit;
}

/// Where a command is, from what actually crossed the wire:
///
/// - [sending]: left the tablet, the board has not confirmed it yet;
/// - [boardAck]: the board took it (it ACKs a COMMAND before relaying it,
///   protocol §7.5) — one check;
/// - [delivered]: the unit itself confirmed it (its own ACK, relayed up by
///   the board) — two checks: it reached both ends;
/// - [answered]: TESTAR only — the unit's test event came back up;
/// - [failed]: no confirmation after every retry.
///
/// Order matters: a later step never goes back to an earlier one.
enum DeviceCommandStep { sending, boardAck, delivered, answered, failed }

class DeviceCommandStatus {
  const DeviceCommandStatus({
    required this.mac,
    required this.kind,
    required this.step,
    required this.startedAt,
    DateTime? updatedAt,
    this.waitsForWake = false,
    this.by,
    this.note,
  }) : updatedAt = updatedAt ?? startedAt;

  /// A unit's MAC — or [safrBroadcastMac]: a command to every unit.
  final String mac;
  final DeviceCommandKind kind;
  final DeviceCommandStep step;
  final DateTime startedAt;

  /// When it reached [step].
  final DateTime updatedAt;

  /// A battery unit: the command waits on its parent for the next wake.
  final bool waitsForWake;

  /// Who started it from a phone (null = the tablet itself).
  final String? by;

  /// Why it failed, when there is more to say than "no confirmation".
  final String? note;

  /// A broadcast on its way: the Central waits for the units' ACKs. No
  /// second one starts meanwhile (the button is disabled).
  bool get broadcastRunning =>
      mac == safrBroadcastMac &&
      (step == DeviceCommandStep.sending || step == DeviceCommandStep.boardAck);

  /// Still on its way: another command to the same unit waits. What the
  /// unit sent never blocks a command.
  bool get inFlight =>
      !kind.fromUnit &&
      (step == DeviceCommandStep.sending ||
          (kind == DeviceCommandKind.test &&
              step == DeviceCommandStep.delivered));

  DeviceCommandStatus copyWith(
          {DeviceCommandStep? step, String? note, DateTime? updatedAt}) =>
      DeviceCommandStatus(
        mac: mac,
        kind: kind,
        step: step ?? this.step,
        startedAt: startedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        waitsForWake: waitsForWake,
        by: by,
        note: note ?? this.note,
      );

  /// The central mirror's `command` event carries kind, step and "waits
  /// for the wake" in one int: kind × 16 + step, + 256 when it waits. (A
  /// phone of an older build reads a value ≥ 256 as an unknown kind and
  /// ignores it.)
  int get wire => kind.index * 16 + step.index + (waitsForWake ? 256 : 0);

  static DeviceCommandStatus? fromWire(
    String mac,
    int wire, {
    String? by,
    required DateTime at,
  }) {
    final waits = wire >= 256;
    final k = (wire % 256) ~/ 16;
    final s = wire % 16;
    if (k >= DeviceCommandKind.values.length ||
        s >= DeviceCommandStep.values.length) {
      return null;
    }
    return DeviceCommandStatus(
      mac: mac,
      kind: DeviceCommandKind.values[k],
      step: DeviceCommandStep.values[s],
      startedAt: at,
      waitsForWake: waits,
      by: by,
    );
  }
}

/// A broadcast's units by outcome (DeviceCommandTracker.broadcastTally).
class BroadcastTally {
  const BroadcastTally({
    required this.total,
    required this.confirmed,
    required this.pending,
    required this.sleepers,
    required this.missing,
    required this.noAnswer,
    this.cancelled = 0,
  });
  final int total, confirmed, pending, sleepers, missing, noAnswer, cancelled;

  bool get done => pending == 0;

  String get text => [
        '$confirmed ${confirmed == 1 ? 'confirmou' : 'confirmaram'}',
        if (pending > 0)
          '$pending ${pending == 1 ? 'pendente' : 'pendentes'}'
              '${sleepers > 0 ? ' ($sleepers no próximo despertar)' : ''}',
        if (missing > 0) '$missing sem comunicação',
        if (noAnswer > 0) '$noAnswer sem resposta',
        if (cancelled > 0)
          '$cancelled ${cancelled == 1 ? 'cancelado' : 'cancelados'}',
      ].join(' · ');
}

/// How long a status stays on the map once it reached a step.
const _lingerAfter = {
  DeviceCommandStep.sending: Duration(seconds: 20),
  DeviceCommandStep.boardAck: Duration(seconds: 8),
  DeviceCommandStep.delivered: Duration(seconds: 5),
  DeviceCommandStep.answered: Duration(seconds: 5),
  DeviceCommandStep.failed: Duration(seconds: 10),
};

/// A TESTAR's test event comes within this of the unit's ACK.
const _testAnswerWithin = Duration(seconds: 10);

/// A battery unit's command waits for its next wake (60 s cadence).
const _wakeWindow = Duration(seconds: 75);

/// A mains unit's own ACK comes back within this of the board's; past it
/// the unit is not going to confirm (a unit that just died: the registry
/// still says online, nothing answers) — red, "sem resposta".
const unitAckWindow = Duration(seconds: 15);

/// IDENTIFY: how long the unit blinks.
const identifyBlinkSeconds = 10;

/// The command in flight per unit, shown on the Rede map (a packet down, a
/// check on the central when the board takes it, two on the unit when the
/// unit confirms) and in the device popover.
///
/// On the tablet it sends the command itself; on a phone viewing a central
/// it asks the central for IDENTIFY and follows the steps the central
/// publishes (central mirror `command` events).
class DeviceCommandTracker
    extends StateNotifier<Map<String, DeviceCommandStatus>> {
  DeviceCommandTracker({
    Future<bool> Function(String mac, DeviceCommandKind kind)? send,
    Future<String?> Function(String mac)? askCentral,
    void Function(String mac, DeviceCommandKind kind)? onConfirmed,
    Stream<String>? deliveries,
    Stream<SafrTrafficTick>? traffic,
    List<TopologyNode> Function()? nodes,
    DateTime Function()? clock,
  })  : _send = send,
        _askCentral = askCentral,
        _onConfirmed = onConfirmed,
        _nodes = nodes,
        _clock = clock ?? DateTime.now,
        super(const {}) {
    _subs = [
      if (deliveries != null) deliveries.listen(_onDelivered),
      if (traffic != null) traffic.listen(_onTraffic),
    ];
  }

  final Future<bool> Function(String mac, DeviceCommandKind kind)? _send;

  /// Phone: asks the central for IDENTIFY; null = it went, else why not.
  final Future<String?> Function(String mac)? _askCentral;

  /// The UNIT confirmed a command to it (its own ACK came back up): what
  /// follows from the unit having it — the IDENTIFY blink on its LED —
  /// starts here, never on the board's ACK (a unit that just died would
  /// blink on the screen and nowhere else, 2026-10-15).
  final void Function(String mac, DeviceCommandKind kind)? _onConfirmed;

  /// The map: who a broadcast must hear back from.
  final List<TopologyNode> Function()? _nodes;
  final DateTime Function() _clock;

  /// A broadcast on its way: every unit it still waits for — the mains
  /// units, which answer within seconds, and the battery detectors, whose
  /// parent holds the command until their next wake (protocol §12.5): they
  /// show the clock meanwhile. The Central's ✓✓ (and the wave) comes only
  /// when the LAST one confirmed; past [broadcastWindow] without them all,
  /// the Central and the units still waiting go red.
  final _broadcastWaiting = <String>{};

  /// Every unit the broadcast includes — the ones waited for, the ones
  /// that confirmed, and the ones that were offline when it started (red
  /// from the first moment: "sem comunicação"). Their statuses stay for as
  /// long as the broadcast's own does, so the Central's popover can show
  /// where each one stands at any moment of the test.
  final _broadcastUnits = <String>{};

  /// A detector wakes every 60 s (protocol §12.2); its ACK rides up right
  /// after. Past this, a unit that did not confirm is not going to.
  static const broadcastWindow = Duration(seconds: 100);

  /// A phone: what the central's retained record last said — a test runs,
  /// or the last one that ended. A step of a test that arrives when the
  /// record says nothing runs (a late or repeated batch after the end)
  /// would put the whole test back on the map for [broadcastWindow];
  /// after [staleGrace] with still no running record it is closed from
  /// the ended one instead. The grace covers a new test whose record
  /// comes a moment after its first steps.
  bool _recordRunning = false;
  SystemTestRun? _lastEnded;
  Timer? _staleTimer;
  static const staleGrace = Duration(seconds: 5);
  late final List<StreamSubscription<Object?>> _subs;
  final _timers = <String, Timer>{};

  /// Sends [kind] to [mac] and follows it. False when it was never
  /// confirmed, or another command to the unit is still on its way.
  Future<bool> run(
    String mac,
    DeviceCommandKind kind, {
    bool waitsForWake = false,
    String? by,
  }) async {
    if (state[mac]?.inFlight == true) return false;
    if (state[mac]?.broadcastRunning == true) return false;
    final started = DeviceCommandStatus(
      mac: mac,
      kind: kind,
      step: DeviceCommandStep.sending,
      startedAt: _clock(),
      waitsForWake: waitsForWake,
      by: by,
    );
    _put(started);
    if (mac == safrBroadcastMac) {
      _broadcastWaiting.clear();
      _broadcastUnits.clear();
      final now = _clock();
      for (final n in _nodes?.call() ?? const <TopologyNode>[]) {
        if (n.layer <= 0 || n.awaitingSignal) continue;
        if (state[n.mac]?.inFlight == true) continue; // busy: not counted
        _broadcastUnits.add(n.mac);
        if (!n.online) {
          // Not reachable: its outcome is known before the command leaves.
          _put(DeviceCommandStatus(
            mac: n.mac,
            kind: kind,
            step: DeviceCommandStep.failed,
            startedAt: now,
            note: missingNote,
            by: by,
          ));
          continue;
        }
        _broadcastWaiting.add(n.mac);
        // Every unit shows the clock until its own ACK comes back; a
        // sleeping detector's says it waits for the wake.
        _put(DeviceCommandStatus(
          mac: n.mac,
          kind: kind,
          step: DeviceCommandStep.sending,
          startedAt: now,
          waitsForWake: n.isLeaf,
          by: by,
        ));
      }
      _put(started.copyWith(note: _broadcastNote()));
    }

    final send = _send;
    if (send != null) {
      final ok = await send(mac, kind);
      if (!identical(_startOf(mac), started.startedAt)) return ok;
      _advance(mac, ok ? DeviceCommandStep.boardAck : DeviceCommandStep.failed);
      // The units' own ACKs may all be in before the board's answer was
      // handed back (the board answers first on the wire, but the
      // awaiting code runs after): the verdict is given now, not never.
      if (mac == safrBroadcastMac && ok) _settleBroadcast();
      return ok;
    }
    final ask = _askCentral;
    if (ask == null || kind != DeviceCommandKind.identify) {
      _advance(mac, DeviceCommandStep.failed);
      return false;
    }
    final refused = await ask(mac);
    if (!identical(_startOf(mac), started.startedAt)) return refused == null;
    if (refused == null) {
      _advance(mac, DeviceCommandStep.boardAck);
    } else {
      final cur = state[mac];
      if (cur != null && cur.step == DeviceCommandStep.sending) {
        _put(cur.copyWith(step: DeviceCommandStep.failed, note: refused));
      }
    }
    return refused == null;
  }

  /// Phone: a step the central published.
  void applyRemote(DeviceCommandStatus remote) {
    final cur = state[remote.mac];
    if (cur != null &&
        cur.kind == remote.kind &&
        cur.step.index > remote.step.index &&
        cur.step != DeviceCommandStep.failed) {
      return; // late, out of order
    }
    // The test's membership, learnt from the events themselves: a broadcast
    // starting opens the list; every unit's status of the same command
    // joins it. The phone then keeps outcomes, tallies and sweeps exactly as
    // the tablet does.
    final all = state[safrBroadcastMac];
    if (remote.mac == safrBroadcastMac) {
      // A NEW broadcast opens an empty list. The tablet re-publishes the
      // same "sending" with its tally line right after it listed the
      // units: that one must not empty the list again, or the units'
      // clocks would leave the phone's map after 20 s and the Central's
      // tally would count nobody (fixed 2026-10-14).
      if (remote.step == DeviceCommandStep.sending &&
          (cur == null || cur.step != DeviceCommandStep.sending)) {
        _broadcastUnits.clear();
      }
    } else if (all != null && all.kind == remote.kind) {
      _broadcastUnits.add(remote.mac);
    }
    _put(DeviceCommandStatus(
      mac: remote.mac,
      kind: remote.kind,
      step: remote.step,
      startedAt: cur?.kind == remote.kind ? cur!.startedAt : remote.startedAt,
      // A detector waiting for its wake keeps its clock the whole window
      // on the phone too.
      waitsForWake: remote.waitsForWake,
      by: remote.by ?? cur?.by,
      note: remote.mac == safrBroadcastMac ? _broadcastNote() : remote.note,
    ));
    // The Central's tick says the tally as it moves (through _put: the
    // status object the linger timer watches must be the one in state).
    final after = state[safrBroadcastMac];
    if (remote.mac != safrBroadcastMac &&
        after != null &&
        _broadcastUnits.contains(remote.mac)) {
      _put(after.copyWith(note: _broadcastNote()));
    }
    // A test on the map with no record of it running: stale unless its
    // record is about to come (2026-10-15: a late batch put the Central
    // back at ✓ with every unit ✓✓, for the whole window).
    if (after != null &&
        after.kind == DeviceCommandKind.test &&
        after.broadcastRunning &&
        !_recordRunning &&
        _lastEnded != null) {
      _staleTimer?.cancel();
      _staleTimer = Timer(staleGrace, () {
        if (!mounted || _recordRunning) return;
        final ended = _lastEnded;
        final cur = state[safrBroadcastMac];
        if (ended == null || cur == null || !cur.broadcastRunning) return;
        closeFromRun(ended);
      });
    }
  }

  DateTime? _startOf(String mac) => state[mac]?.startedAt;

  /// A unit that was offline when the broadcast started.
  static const missingNote = 'sem comunicação';

  /// A unit that never confirmed inside the window.
  static const noAnswerNote = 'sem resposta';

  /// A unit still waiting when the operator cancelled the test.
  static const cancelledNote = 'cancelado';

  /// Every unit of the running (or lingering) broadcast.
  Set<String> get broadcastUnits => Set.unmodifiable(_broadcastUnits);

  /// The operator cancels the running broadcast: every unit still waiting
  /// is "cancelado", the Central's own status fails with that note, and
  /// nothing more is waited for. False when no broadcast runs.
  bool cancelBroadcast() {
    final all = state[safrBroadcastMac];
    if (all == null || !all.broadcastRunning) return false;
    final now = _clock();
    for (final m in _broadcastUnits) {
      final cur = state[m];
      if (cur != null &&
          cur.kind == all.kind &&
          (cur.step == DeviceCommandStep.sending ||
              cur.step == DeviceCommandStep.boardAck)) {
        _put(cur.copyWith(
            step: DeviceCommandStep.failed,
            note: cancelledNote,
            updatedAt: now));
      }
    }
    _broadcastWaiting.clear();
    _put(all.copyWith(
        step: DeviceCommandStep.failed, note: cancelledNote, updatedAt: now));
    return true;
  }

  /// A phone: the running test as the central's retained record says it
  /// (a reload, a late join): the broadcast, then every unit, through the
  /// same door as the events — a step already passed is never undone.
  void seedFromRun(SystemTestRun run) {
    if (!run.running) return;
    _recordRunning = true;
    _staleTimer?.cancel();
    final t0 = run.startedAt;
    applyRemote(DeviceCommandStatus(
      mac: safrBroadcastMac,
      kind: DeviceCommandKind.test,
      step: run.boardAcked
          ? DeviceCommandStep.boardAck
          : DeviceCommandStep.sending,
      startedAt: t0,
      by: run.by,
    ));
    for (final u in run.units) {
      final (step, note) = switch (u.outcome) {
        SystemTestOutcome.pending || SystemTestOutcome.pendingWake => (
            DeviceCommandStep.sending,
            null
          ),
        SystemTestOutcome.confirmed => (DeviceCommandStep.delivered, null),
        SystemTestOutcome.noAnswer => (DeviceCommandStep.failed, noAnswerNote),
        SystemTestOutcome.missing => (DeviceCommandStep.failed, missingNote),
        SystemTestOutcome.cancelled => (
            DeviceCommandStep.failed,
            cancelledNote
          ),
      };
      applyRemote(DeviceCommandStatus(
        mac: u.mac,
        kind: DeviceCommandKind.test,
        step: step,
        startedAt: t0,
        waitsForWake: u.outcome == SystemTestOutcome.pendingWake,
        by: run.by,
        note: note,
      ));
    }
  }

  /// The broadcast's units by outcome, from their statuses.
  BroadcastTally get broadcastTally {
    var confirmed = 0, pending = 0, sleepers = 0, missing = 0, noAnswer = 0;
    var cancelled = 0;
    for (final m in _broadcastUnits) {
      final u = state[m];
      if (u == null) continue;
      switch (u.step) {
        case DeviceCommandStep.delivered:
        case DeviceCommandStep.answered:
          confirmed++;
        case DeviceCommandStep.failed:
          if (u.note == missingNote) {
            missing++;
          } else if (u.note == cancelledNote) {
            cancelled++;
          } else {
            noAnswer++;
          }
        case DeviceCommandStep.sending:
        case DeviceCommandStep.boardAck:
          pending++;
          if (u.waitsForWake) sleepers++;
      }
    }
    return BroadcastTally(
      total: _broadcastUnits.length,
      confirmed: confirmed,
      pending: pending,
      sleepers: sleepers,
      missing: missing,
      noAnswer: noAnswer,
      cancelled: cancelled,
    );
  }

  /// What the Central's tick says while a broadcast runs and when it ends:
  /// "2 confirmaram · 1 pendente (no próximo despertar) · 1 sem comunicação".
  String? _broadcastNote() {
    if (_broadcastUnits.isEmpty) return null;
    return broadcastTally.text;
  }

  /// The window closed with units still waiting: red on the Central and
  /// on each of them. A unit that confirms later still gets its ✓✓.
  void _broadcastTimedOut() {
    final all = state[safrBroadcastMac];
    if (all == null || all.step != DeviceCommandStep.boardAck) return;
    _dropSettledFromWaiting(all);
    final now = _clock();
    for (final m in _broadcastWaiting.toList()) {
      final cur = state[m];
      if (cur != null &&
          cur.kind == all.kind &&
          cur.step == DeviceCommandStep.sending) {
        _put(cur.copyWith(
            step: DeviceCommandStep.failed,
            note: noAnswerNote,
            updatedAt: now));
      }
    }
    _broadcastWaiting.clear();
    // The verdict comes from the outcomes themselves: a unit that
    // answered (its test came back) confirmed, whatever happened to its
    // ACK. Red only when someone really was out of reach or never
    // answered.
    final tally = broadcastTally;
    final clean =
        tally.pending == 0 && tally.missing == 0 && tally.noAnswer == 0;
    _put(all.copyWith(
        step: clean ? DeviceCommandStep.delivered : DeviceCommandStep.failed,
        note: _broadcastNote(),
        updatedAt: now));
  }

  /// A unit of the broadcast is confirmed (its own ACK, or its answer to
  /// the test). The Central's ✓✓ — and the wave — once the LAST one is
  /// in: the verdict is given whenever the last confirmation lands, before
  /// or after the board's own answer was handed back.
  void _broadcastUnitConfirmed(String mac) {
    _broadcastWaiting.remove(mac);
    _settleBroadcast();
  }

  /// Everyone reachable confirmed: ✓✓ and the wave only if nobody was
  /// left out — a unit that was offline makes the whole test red. With
  /// units still waiting, the Central's tally moves.
  void _settleBroadcast() {
    final all = state[safrBroadcastMac];
    if (all == null || all.step != DeviceCommandStep.boardAck) return;
    _dropSettledFromWaiting(all);
    if (_broadcastWaiting.isNotEmpty) {
      _put(all.copyWith(note: _broadcastNote()));
      return;
    }
    final clean = broadcastTally.missing == 0;
    _put(all.copyWith(
        step: clean ? DeviceCommandStep.delivered : DeviceCommandStep.failed,
        note: _broadcastNote(),
        updatedAt: _clock()));
  }

  /// A unit whose status already says confirmed, answered or failed holds
  /// no verdict back, whatever the waiting list still says (the list and
  /// the statuses must never disagree; the statuses are what is shown).
  void _dropSettledFromWaiting(DeviceCommandStatus all) {
    _broadcastWaiting.removeWhere((m) {
      final s = state[m];
      return s == null ||
          s.kind != all.kind ||
          (s.step != DeviceCommandStep.sending &&
              s.step != DeviceCommandStep.boardAck);
    });
  }

  void _onDelivered(String mac) {
    final cur = state[mac];
    final all = state[safrBroadcastMac];
    final ofBroadcast =
        all != null && cur != null && _broadcastWaiting.contains(mac);
    if (!ofBroadcast &&
        cur != null &&
        (cur.step == DeviceCommandStep.sending ||
            cur.step == DeviceCommandStep.boardAck)) {
      _advance(mac, DeviceCommandStep.delivered);
      if (!cur.kind.fromUnit) _onConfirmed?.call(mac, cur.kind);
      return;
    }
    // A unit confirming a broadcast: its own ✓✓ — even after the window
    // closed on it — and the Central's ✓✓ once the LAST one is in.
    if (all == null) return;
    // A unit that already answered the test keeps its ✓✓ as it is.
    final answered = cur != null &&
        cur.kind == all.kind &&
        cur.step == DeviceCommandStep.answered;
    if (!answered && (cur == null || !cur.inFlight || cur.kind == all.kind)) {
      _put(DeviceCommandStatus(
        mac: mac,
        kind: all.kind,
        step: DeviceCommandStep.delivered,
        startedAt: all.startedAt,
        updatedAt: _clock(),
        by: all.by,
      ));
    }
    _broadcastUnitConfirmed(mac);
  }

  void _onTraffic(SafrTrafficTick tick) {
    final cur = state[tick.mac];
    if (tick.direction == SafrTrafficDirection.uplink &&
        tick.msgType == SafrMsgType.event) {
      // The test TESTAR asked for came back: the command is answered.
      if (cur != null &&
          cur.kind == DeviceCommandKind.test &&
          tick.eventCode == SafrEventCode.manualTest) {
        if (cur.step.index < DeviceCommandStep.answered.index) {
          _advance(tick.mac, DeviceCommandStep.answered);
        }
        // The answer proves the command reached it: for the system test
        // it counts as the unit's confirmation, whether or not its own
        // ACK makes it up the mesh (the unit emits the test event before
        // it ACKs, and an ACK has no retry).
        if (_broadcastWaiting.contains(tick.mac) &&
            state[safrBroadcastMac]?.kind == DeviceCommandKind.test) {
          _broadcastUnitConfirmed(tick.mac);
        }
        return;
      }
      // Something the unit sent on its own: ✓, the central received it.
      // A command still on its way keeps its ticks.
      if (cur != null && cur.inFlight) return;
      _put(DeviceCommandStatus(
        mac: tick.mac,
        kind: tick.eventCode == SafrEventCode.manualTest
            ? DeviceCommandKind.unitTest
            : tick.severity == 3
                ? DeviceCommandKind.unitAlarm
                : DeviceCommandKind.unitEvent,
        step: DeviceCommandStep.boardAck,
        startedAt: _clock(),
      ));
      return;
    }
    // The central's ACK going down: ✓✓, the unit's cyan.
    if (tick.direction == SafrTrafficDirection.downlink &&
        tick.ack &&
        cur != null &&
        cur.kind.fromUnit &&
        cur.step.index < DeviceCommandStep.delivered.index) {
      _advance(tick.mac, DeviceCommandStep.delivered);
    }
  }

  /// A phone: the central's record says the test ENDED (its retained
  /// message moved on, with nobody running). Whatever this phone still
  /// shows of it — the clocks, the Central's ✓ — is closed as the record
  /// says, in case the batch with the last steps never reached it.
  /// Nothing when this phone shows no running test (an old record on an
  /// app just opened must not light ticks for a test long over).
  void closeFromRun(SystemTestRun run) {
    if (run.running) return;
    _recordRunning = false;
    _lastEnded = run;
    _staleTimer?.cancel();
    final all = state[safrBroadcastMac];
    if (all == null ||
        all.kind != DeviceCommandKind.test ||
        !all.broadcastRunning) {
      return;
    }
    final now = _clock();
    for (final u in run.units) {
      final (step, note) = switch (u.outcome) {
        SystemTestOutcome.confirmed => (DeviceCommandStep.delivered, null),
        SystemTestOutcome.noAnswer => (DeviceCommandStep.failed, noAnswerNote),
        SystemTestOutcome.missing => (DeviceCommandStep.failed, missingNote),
        SystemTestOutcome.cancelled ||
        SystemTestOutcome.pending ||
        SystemTestOutcome.pendingWake =>
          (DeviceCommandStep.failed, cancelledNote),
      };
      final cur = state[u.mac];
      if (cur != null && cur.kind == DeviceCommandKind.test) {
        if (cur.step.index < step.index ||
            cur.step == DeviceCommandStep.failed) {
          _put(cur.copyWith(step: step, note: note, updatedAt: now));
        }
      } else if (cur == null) {
        _broadcastUnits.add(u.mac);
        _put(DeviceCommandStatus(
          mac: u.mac,
          kind: DeviceCommandKind.test,
          step: step,
          startedAt: all.startedAt,
          updatedAt: now,
          by: all.by,
          note: note,
        ));
      }
    }
    _broadcastWaiting.clear();
    _put(all.copyWith(
      step: run.verdict == SystemTestVerdict.passed
          ? DeviceCommandStep.delivered
          : DeviceCommandStep.failed,
      note: run.verdict == SystemTestVerdict.cancelled
          ? cancelledNote
          : _broadcastNote(),
      updatedAt: now,
    ));
  }

  /// Moves forward only (a late board ACK never undoes the unit's).
  void _advance(String mac, DeviceCommandStep step) {
    final cur = state[mac];
    if (cur == null) return;
    if (cur.step.index >= step.index && cur.step != DeviceCommandStep.failed) {
      return;
    }
    _put(cur.copyWith(
        step: step,
        updatedAt: _clock(),
        note: mac == safrBroadcastMac ? _broadcastNote() : null));
  }

  void _put(DeviceCommandStatus s) {
    state = {...state, s.mac: s};
    _timers.remove(s.mac)?.cancel();
    var linger = _lingerAfter[s.step]!;
    final broadcastWaits =
        s.mac == safrBroadcastMac && s.step == DeviceCommandStep.boardAck;
    // The board took a command to one unit: its ✓ waits for the unit's
    // own ACK — seconds for a mains unit, the next wake for a detector.
    final awaitsUnit = s.mac != safrBroadcastMac &&
        !s.kind.fromUnit &&
        s.step == DeviceCommandStep.boardAck &&
        !_broadcastUnits.contains(s.mac);
    if (broadcastWaits ||
        (s.waitsForWake && s.step == DeviceCommandStep.sending)) {
      linger = broadcastWindow;
    } else if (awaitsUnit) {
      linger = s.waitsForWake ? _wakeWindow : unitAckWindow;
    } else if (s.kind == DeviceCommandKind.test &&
        s.step == DeviceCommandStep.delivered) {
      linger = _testAnswerWithin;
    }
    _timers[s.mac] = Timer(linger, () {
      if (!mounted) return;
      final now = state[s.mac];
      if (now == null || !identical(now, s)) return;
      // The window closed: the tablet gives the verdict. A phone never
      // invents one — with nothing heard it just lets the test go.
      if (broadcastWaits && _send != null) {
        _broadcastTimedOut();
        return;
      }
      // The unit never confirmed what the board took: red, and a tap
      // tries again. (A phone shows the central's own verdict, which
      // comes as a `command` event; with nothing heard it lets it go.)
      if (awaitsUnit && _send != null) {
        _put(s.copyWith(
            step: DeviceCommandStep.failed,
            note: noAnswerNote,
            updatedAt: _clock()));
        return;
      }
      // A unit of a broadcast keeps its outcome for as long as the
      // broadcast's own status is up: the test's picture stays whole.
      if (s.mac != safrBroadcastMac && _broadcastUnits.contains(s.mac)) {
        if (state[safrBroadcastMac] != null) return;
      }
      // The broadcast leaves: its units' outcomes with it.
      if (s.mac == safrBroadcastMac) {
        final units = Set.of(_broadcastUnits);
        _broadcastUnits.clear();
        state = {...state}
          ..remove(s.mac)
          // (Its units were never busy with anything else: `run` left
          // those out of the test.)
          ..removeWhere((m, u) => units.contains(m) && u.kind == s.kind);
        return;
      }
      state = {...state}..remove(s.mac);
    });
  }

  @override
  void dispose() {
    _staleTimer?.cancel();
    for (final t in _timers.values) {
      t.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

final deviceCommandProvider = StateNotifierProvider<DeviceCommandTracker,
    Map<String, DeviceCommandStatus>>((ref) {
  final traffic = ref.watch(safrTrafficProvider).stream;
  // A phone viewing a central: it asks, the central sends.
  final viewed = ref.watch(viewedCentralProvider);
  if (viewed != null) {
    final tracker = DeviceCommandTracker(
      traffic: traffic,
      askCentral: (mac) async {
        final outcome =
            await ref.read(centralMirrorProvider.notifier).sendIdentify(mac);
        return switch (outcome) {
          MirrorIdentifyOutcome.confirmed => null,
          MirrorIdentifyOutcome.notConfirmed => 'Sem confirmação',
          MirrorIdentifyOutcome.noAnswer => 'A central não respondeu',
        };
      },
    );
    // The test running on the central, as its retained record says it:
    // the whole picture after a reload or a late join, whatever the
    // snapshot's and the events' timing.
    ref.listen<MirrorTests?>(mirrorTestsProvider(viewed), (_, next) {
      final run = next?.running;
      if (run != null) {
        tracker.seedFromRun(run);
      } else if (next?.recent.firstOrNull case final last?) {
        tracker.closeFromRun(last);
      }
    }, fireImmediately: true);
    return tracker;
  }
  final downlink = ref.watch(safrDownlinkProvider);
  return DeviceCommandTracker(
    traffic: traffic,
    deliveries: downlink.deliveries,
    nodes: () => ref.read(topologyProvider),
    // The unit starts its blue IDENTIFY blink when the command reaches it:
    // the screen's LED starts when the unit's own ACK says it did — not on
    // the board's ACK, which only says the board relayed it.
    onConfirmed: (mac, kind) {
      if (kind == DeviceCommandKind.identify) {
        ref.read(deviceLedProvider).identify(mac, identifyBlinkSeconds);
      }
    },
    send: (mac, kind) async {
      switch (kind) {
        case DeviceCommandKind.identify:
          return downlink.sendCommand(mac, SafrCommand.identify,
              args: const [identifyBlinkSeconds]);
        case DeviceCommandKind.test:
          return downlink.sendCommand(mac, SafrCommand.test);
        case DeviceCommandKind.soundOff:
          return ref
              .read(deviceSoundProvider.notifier)
              .setSound(mac, on: false);
        case DeviceCommandKind.soundOn:
          return ref.read(deviceSoundProvider.notifier).setSound(mac, on: true);
        case DeviceCommandKind.reset:
          // The latch clears only on the confirmation.
          return downlink.sendReset(mac);
        case DeviceCommandKind.unitTest:
        case DeviceCommandKind.unitAlarm:
        case DeviceCommandKind.unitEvent:
          return false; // the unit's own; nothing to send
      }
    },
  );
});
