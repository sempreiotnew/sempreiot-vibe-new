import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart'
    show safrBroadcastMac;
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// The command in flight per unit (device_command_provider.dart): the steps
/// come from what crossed the wire — the board's ACK, then the unit's own.
void main() {
  const unit = 'AA:00:00:00:00:01';

  late StreamController<String> deliveries;
  late StreamController<SafrTrafficTick> traffic;
  late Completer<bool> boardAck;

  /// Built inside fakeAsync: the board's answer must complete in fake time.
  DeviceCommandTracker tracker() {
    boardAck = Completer<bool>();
    return DeviceCommandTracker(
      send: (_, __) => boardAck.future,
      deliveries: deliveries.stream,
      traffic: traffic.stream,
    );
  }

  setUp(() {
    deliveries = StreamController<String>.broadcast();
    traffic = StreamController<SafrTrafficTick>.broadcast();
  });

  test('sent → the board takes it (✓) → the unit confirms it (✓✓)', () {
    fakeAsync((async) {
      final t = tracker();
      t.run(unit, DeviceCommandKind.identify);
      expect(t.state[unit]!.step, DeviceCommandStep.sending);
      expect(t.state[unit]!.inFlight, isTrue);

      boardAck.complete(true);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.boardAck);

      deliveries.add(unit);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);

      // It stays on the map a moment, then leaves by itself.
      async.elapse(const Duration(seconds: 6));
      expect(t.state[unit], isNull);
      t.dispose();
    });
  });

  test('the unit\'s ACK may come before the board\'s: never goes back', () {
    fakeAsync((async) {
      final t = tracker();
      t.run(unit, DeviceCommandKind.identify);
      deliveries.add(unit);
      async.flushMicrotasks();
      boardAck.complete(true);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);
      t.dispose();
    });
  });

  test('TESTAR is answered when the unit\'s test event comes up', () {
    fakeAsync((async) {
      final t = tracker();
      t.run(unit, DeviceCommandKind.test);
      boardAck.complete(true);
      deliveries.add(unit);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);
      expect(t.state[unit]!.inFlight, isTrue, reason: 'waits for the test');

      traffic.add(const SafrTrafficTick(
        mac: unit,
        direction: SafrTrafficDirection.uplink,
        severity: 2,
        msgType: SafrMsgType.event,
        eventCode: SafrEventCode.manualTest,
      ));
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.answered);
      t.dispose();
    });
  });

  test('no confirmation: failed, and a retry is allowed', () {
    fakeAsync((async) {
      final t = tracker();
      t.run(unit, DeviceCommandKind.reset);
      boardAck.complete(false);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.failed);
      expect(t.state[unit]!.inFlight, isFalse);
      t.dispose();
    });
  });

  test('one command at a time per unit', () {
    fakeAsync((async) {
      final t = tracker();
      t.run(unit, DeviceCommandKind.identify);
      var second = true;
      t.run(unit, DeviceCommandKind.test).then((ok) => second = ok);
      async.flushMicrotasks();
      expect(second, isFalse);
      expect(t.state[unit]!.kind, DeviceCommandKind.identify);
      t.dispose();
    });
  });

  test('a battery unit waits for its wake: ✓ stays up for the next wake', () {
    fakeAsync((async) {
      final t = tracker();
      t.run(unit, DeviceCommandKind.soundOff, waitsForWake: true);
      boardAck.complete(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      expect(t.state[unit]!.step, DeviceCommandStep.boardAck);
      deliveries.add(unit);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);
      t.dispose();
    });
  });

  test('phone: asks the central, then follows the steps it publishes', () {
    fakeAsync((async) {
      final answer = Completer<String?>();
      final t = DeviceCommandTracker(askCentral: (_) => answer.future);
      t.run(unit, DeviceCommandKind.identify, by: 'ana@x.com');
      expect(t.state[unit]!.step, DeviceCommandStep.sending);

      t.applyRemote(DeviceCommandStatus.fromWire(
        unit,
        DeviceCommandStatus(
          mac: unit,
          kind: DeviceCommandKind.identify,
          step: DeviceCommandStep.delivered,
          startedAt: _t0,
        ).wire,
        at: DateTime.now(),
      )!);
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);
      // The central's own outcome (the board's ACK) arrives later: no step
      // back.
      answer.complete(null);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);
      t.dispose();
    });
  });

  test('phone: the central did not answer — said so', () {
    fakeAsync((async) {
      final t = DeviceCommandTracker(
          askCentral: (_) async => 'A central não respondeu');
      t.run(unit, DeviceCommandKind.identify);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.failed);
      expect(t.state[unit]!.note, 'A central não respondeu');
      t.dispose();
    });
  });

  test('the unit\'s own TEST button: ✓ received, ✓✓ when the central ACKs', () {
    fakeAsync((async) {
      final t = tracker();
      traffic.add(const SafrTrafficTick(
        mac: unit,
        direction: SafrTrafficDirection.uplink,
        severity: 2,
        msgType: SafrMsgType.event,
        eventCode: SafrEventCode.manualTest,
      ));
      async.flushMicrotasks();
      expect(t.state[unit]!.kind, DeviceCommandKind.unitTest);
      expect(t.state[unit]!.step, DeviceCommandStep.boardAck);
      expect(t.state[unit]!.inFlight, isFalse, reason: 'never blocks');

      traffic.add(const SafrTrafficTick(
        mac: unit,
        direction: SafrTrafficDirection.downlink,
        severity: 0,
        ack: true,
        msgType: SafrMsgType.ack,
      ));
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);
      t.dispose();
    });
  });

  test(
      'an alarm from the unit gets its ticks; a command in flight keeps '
      'its own', () {
    fakeAsync((async) {
      final t = tracker();
      traffic.add(const SafrTrafficTick(
        mac: unit,
        direction: SafrTrafficDirection.uplink,
        severity: 3,
        msgType: SafrMsgType.event,
        eventCode: SafrEventCode.smokeAlarm,
      ));
      async.flushMicrotasks();
      expect(t.state[unit]!.kind, DeviceCommandKind.unitAlarm);

      t.run(unit, DeviceCommandKind.identify);
      traffic.add(const SafrTrafficTick(
        mac: unit,
        direction: SafrTrafficDirection.uplink,
        severity: 1,
        msgType: SafrMsgType.event,
      ));
      async.flushMicrotasks();
      expect(t.state[unit]!.kind, DeviceCommandKind.identify);
      t.dispose();
    });
  });

  test(
      'a broadcast: every unit shows the clock, a detector\'s until its '
      'wake; the Central ✓ at the board\'s ACK, ✓✓ only when the LAST one '
      'is in', () {
    fakeAsync((async) {
      const a = 'AA:00:00:00:00:01', b = 'AA:00:00:00:00:02';
      const leaf = 'CC:00:00:00:00:03';
      TopologyNode n(String mac, SafrNodeRole role) => TopologyNode(
            mac: mac,
            role: role,
            layer: 1,
            parentMac: null,
            rssi: -60,
            batteryPct: null,
            online: true,
            lastSeenAt: DateTime.now(),
            alarmLatched: true,
          );
      boardAck = Completer<bool>();
      final t = DeviceCommandTracker(
        send: (_, __) => boardAck.future,
        deliveries: deliveries.stream,
        nodes: () => [
          n(a, SafrNodeRole.root),
          n(b, SafrNodeRole.node),
          n(leaf, SafrNodeRole.leaf),
        ],
      );
      t.run(safrBroadcastMac, DeviceCommandKind.test);
      for (final m in [a, b, leaf]) {
        expect(t.state[m]!.step, DeviceCommandStep.sending, reason: m);
      }
      expect(t.state[leaf]!.waitsForWake, isTrue);
      boardAck.complete(true);
      async.flushMicrotasks();
      expect(t.state[safrBroadcastMac]!.step, DeviceCommandStep.boardAck);
      expect(t.state[safrBroadcastMac]!.note,
          '0 confirmaram · 3 pendentes (1 no próximo despertar)');

      deliveries.add(a);
      deliveries.add(b);
      async.flushMicrotasks();
      expect(t.state[a]!.step, DeviceCommandStep.delivered);
      expect(t.state[safrBroadcastMac]!.step, DeviceCommandStep.boardAck,
          reason: 'the detector has not woken yet');
      expect(t.state[safrBroadcastMac]!.note,
          '2 confirmaram · 1 pendente (1 no próximo despertar)');

      async.elapse(const Duration(seconds: 50)); // the detector sleeps on
      expect(t.state[leaf]!.step, DeviceCommandStep.sending);
      deliveries.add(leaf);
      async.flushMicrotasks();
      expect(t.state[leaf]!.step, DeviceCommandStep.delivered);
      expect(t.state[safrBroadcastMac]!.step, DeviceCommandStep.delivered);
      expect(t.state[safrBroadcastMac]!.note, '3 confirmaram');
      t.dispose();
    });
  });

  test(
      'a broadcast past its window: red on the Central and on who is '
      'still waiting; a late ACK still gets its ✓✓', () {
    fakeAsync((async) {
      const a = 'AA:00:00:00:00:01', leaf = 'CC:00:00:00:00:03';
      TopologyNode n(String mac, SafrNodeRole role) => TopologyNode(
            mac: mac,
            role: role,
            layer: 1,
            parentMac: null,
            rssi: -60,
            batteryPct: null,
            online: true,
            lastSeenAt: DateTime.now(),
            alarmLatched: false,
          );
      boardAck = Completer<bool>();
      final t = DeviceCommandTracker(
        send: (_, __) => boardAck.future,
        deliveries: deliveries.stream,
        nodes: () => [n(a, SafrNodeRole.root), n(leaf, SafrNodeRole.leaf)],
      );
      t.run(safrBroadcastMac, DeviceCommandKind.reset);
      boardAck.complete(true);
      deliveries.add(a);
      async.flushMicrotasks();
      async.elapse(DeviceCommandTracker.broadcastWindow);
      expect(t.state[safrBroadcastMac]!.step, DeviceCommandStep.failed);
      expect(t.state[leaf]!.step, DeviceCommandStep.failed);
      deliveries.add(leaf);
      async.flushMicrotasks();
      expect(t.state[leaf]!.step, DeviceCommandStep.delivered);
      t.dispose();
    });
  });

  test('kind, step and "waits for the wake" cross the mirror in one int', () {
    for (final k in DeviceCommandKind.values) {
      for (final s in DeviceCommandStep.values) {
        for (final waits in [false, true]) {
          final wire = DeviceCommandStatus(
                  mac: unit,
                  kind: k,
                  step: s,
                  startedAt: _t0,
                  waitsForWake: waits)
              .wire;
          final back = DeviceCommandStatus.fromWire(unit, wire, at: _t0)!;
          expect((back.kind, back.step, back.waitsForWake), (k, s, waits));
        }
      }
    }
    // An unknown kind (a newer build's) is ignored, not guessed.
    expect(DeviceCommandStatus.fromWire(unit, 16 * 15, at: _t0), isNull);
  });

  test('phone: a detector\'s clock from the central keeps the whole window',
      () {
    fakeAsync((async) {
      final t = DeviceCommandTracker();
      t.applyRemote(DeviceCommandStatus.fromWire(
        unit,
        DeviceCommandStatus(
          mac: unit,
          kind: DeviceCommandKind.test,
          step: DeviceCommandStep.sending,
          startedAt: _t0,
          waitsForWake: true,
        ).wire,
        at: DateTime.now(),
      )!);
      async.elapse(const Duration(seconds: 60));
      expect(t.state[unit]!.step, DeviceCommandStep.sending,
          reason: 'still waiting for the wake');
      t.dispose();
    });
  });
  test('no second broadcast while one runs', () {
    fakeAsync((async) {
      final t = DeviceCommandTracker(
        send: (_, __) async => true,
        deliveries: deliveries.stream,
        nodes: () => const [],
      );
      t.run(safrBroadcastMac, DeviceCommandKind.test);
      async.flushMicrotasks();
      var second = true;
      t.run(safrBroadcastMac, DeviceCommandKind.test).then((ok) => second = ok);
      async.flushMicrotasks();
      expect(second, isFalse);
      t.dispose();
    });
  });
  test(
      'a unit offline at the start is in the test as red; the Central ends '
      'red with it; every outcome stays until the test leaves', () {
    fakeAsync((async) {
      const a = 'AA:00:00:00:00:01', off = 'AA:00:00:00:00:09';
      TopologyNode n(String mac, {required bool online}) => TopologyNode(
            mac: mac,
            role: SafrNodeRole.node,
            layer: 1,
            parentMac: null,
            rssi: -60,
            batteryPct: null,
            online: online,
            lastSeenAt: DateTime.now(),
            alarmLatched: false,
          );
      boardAck = Completer<bool>();
      final t = DeviceCommandTracker(
        send: (_, __) => boardAck.future,
        deliveries: deliveries.stream,
        nodes: () => [n(a, online: true), n(off, online: false)],
      );
      t.run(safrBroadcastMac, DeviceCommandKind.test);
      expect(t.state[off]!.step, DeviceCommandStep.failed);
      expect(t.state[off]!.note, DeviceCommandTracker.missingNote);
      boardAck.complete(true);
      deliveries.add(a);
      async.flushMicrotasks();
      expect(t.state[a]!.step, DeviceCommandStep.delivered);
      expect(t.state[safrBroadcastMac]!.step, DeviceCommandStep.failed,
          reason: 'one unit was out of reach: the test is not clean');
      expect(t.broadcastTally.text, '1 confirmou · 1 sem comunicação');

      // The outcomes stay with the test; they all leave together.
      async.elapse(const Duration(seconds: 8));
      expect(t.state[a], isNotNull);
      expect(t.state[off], isNotNull);
      async.elapse(const Duration(seconds: 3));
      expect(t.state[safrBroadcastMac], isNull);
      expect(t.state[a], isNull);
      expect(t.state[off], isNull);
      t.dispose();
    });
  });
  test(
      'phone: the test\'s units are learnt from the events; their outcomes '
      'stay with the test and leave with it; no verdict is invented', () {
    fakeAsync((async) {
      const a = 'AA:00:00:00:00:01', b = 'AA:00:00:00:00:02';
      final t = DeviceCommandTracker();
      final t0 = DateTime.now();
      DeviceCommandStatus st(String mac, DeviceCommandStep step,
              {bool waits = false}) =>
          DeviceCommandStatus(
            mac: mac,
            kind: DeviceCommandKind.test,
            step: step,
            startedAt: t0,
            waitsForWake: waits,
          );
      // The tablet's order: the broadcast, then its units, then the steps.
      t.applyRemote(st(safrBroadcastMac, DeviceCommandStep.sending));
      t.applyRemote(st(a, DeviceCommandStep.sending));
      t.applyRemote(st(b, DeviceCommandStep.sending, waits: true));
      t.applyRemote(st(safrBroadcastMac, DeviceCommandStep.boardAck));
      t.applyRemote(st(a, DeviceCommandStep.delivered));
      expect(t.broadcastTally.text,
          '1 confirmou · 1 pendente (1 no próximo despertar)');
      expect(t.state[safrBroadcastMac]!.note,
          '1 confirmou · 1 pendente (1 no próximo despertar)');
      async.elapse(const Duration(seconds: 12));
      expect(t.state[a]!.step, DeviceCommandStep.delivered,
          reason: 'stays while the test runs, not 5 s');

      // Nothing more ever heard: past the window the phone lets it go —
      // without a red of its own.
      async.elapse(DeviceCommandTracker.broadcastWindow);
      expect(t.state[safrBroadcastMac], isNull);
      expect(t.state[a], isNull);
      expect(t.state[b], isNull);
      t.dispose();
    });
  });
}

final _t0 = DateTime.utc(2026, 10, 8);
