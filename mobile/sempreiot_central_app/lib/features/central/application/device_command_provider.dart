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
import 'topology_provider.dart';

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
  });
  final int total, confirmed, pending, sleepers, missing, noAnswer;

  bool get done => pending == 0;

  String get text => [
        '$confirmed ${confirmed == 1 ? 'confirmou' : 'confirmaram'}',
        if (pending > 0)
          '$pending ${pending == 1 ? 'pendente' : 'pendentes'}'
              '${sleepers > 0 ? ' ($sleepers no próximo despertar)' : ''}',
        if (missing > 0) '$missing sem comunicação',
        if (noAnswer > 0) '$noAnswer sem resposta',
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
    Stream<String>? deliveries,
    Stream<SafrTrafficTick>? traffic,
    List<TopologyNode> Function()? nodes,
    DateTime Function()? clock,
  })  : _send = send,
        _askCentral = askCentral,
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
      if (remote.step == DeviceCommandStep.sending) _broadcastUnits.clear();
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
  }

  DateTime? _startOf(String mac) => state[mac]?.startedAt;

  /// A unit that was offline when the broadcast started.
  static const missingNote = 'sem comunicação';

  /// A unit that never confirmed inside the window.
  static const noAnswerNote = 'sem resposta';

  /// The broadcast's units by outcome, from their statuses.
  BroadcastTally get broadcastTally {
    var confirmed = 0, pending = 0, sleepers = 0, missing = 0, noAnswer = 0;
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
    _put(all.copyWith(
        step: DeviceCommandStep.failed,
        note: _broadcastNote(),
        updatedAt: now));
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
      return;
    }
    // A unit confirming a broadcast: its own ✓✓ — even after the window
    // closed on it — and the Central's ✓✓ once the LAST one is in.
    if (all == null) return;
    if (cur == null || !cur.inFlight || cur.kind == all.kind) {
      _put(DeviceCommandStatus(
        mac: mac,
        kind: all.kind,
        step: DeviceCommandStep.delivered,
        startedAt: all.startedAt,
        updatedAt: _clock(),
        by: all.by,
      ));
    }
    _broadcastWaiting.remove(mac);
    if (all.step == DeviceCommandStep.boardAck) {
      if (_broadcastWaiting.isEmpty) {
        // Everyone reachable confirmed. ✓✓ and the wave only if nobody was
        // left out; a unit that was offline makes the whole test red.
        final clean = broadcastTally.missing == 0;
        _put(all.copyWith(
            step:
                clean ? DeviceCommandStep.delivered : DeviceCommandStep.failed,
            note: _broadcastNote(),
            updatedAt: _clock()));
      } else {
        _put(all.copyWith(note: _broadcastNote()));
      }
    }
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
    if (broadcastWaits ||
        (s.waitsForWake && s.step == DeviceCommandStep.sending)) {
      linger = broadcastWindow;
    } else if (s.waitsForWake && s.step == DeviceCommandStep.boardAck) {
      linger = _wakeWindow;
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
  if (ref.watch(viewedCentralProvider) != null) {
    return DeviceCommandTracker(
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
  }
  final downlink = ref.watch(safrDownlinkProvider);
  return DeviceCommandTracker(
    traffic: traffic,
    deliveries: downlink.deliveries,
    nodes: () => ref.read(topologyProvider),
    send: (mac, kind) async {
      switch (kind) {
        case DeviceCommandKind.identify:
          final ok = await downlink.sendCommand(mac, SafrCommand.identify,
              args: const [identifyBlinkSeconds]);
          // The unit starts its blue IDENTIFY blink on receipt; mirror it.
          if (ok) {
            ref.read(deviceLedProvider).identify(mac, identifyBlinkSeconds);
          }
          return ok;
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
