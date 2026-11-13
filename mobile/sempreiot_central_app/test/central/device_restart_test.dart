import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_command_widgets.dart';

/// REINICIAR (protocol §7.6 RESTART, central-mirror.md §4.11): a plain
/// restart of one unit — the board, a mains unit, a battery unit. Its steps
/// come from what crossed the wire: the board's ACK, the unit's own ACK
/// (sent before it restarts), then its first frame of the next boot.
void main() {
  const unit = 'AA:00:00:00:00:01';
  final t0 = DateTime.utc(2026, 11, 13, 10);

  late StreamController<String> deliveries;
  late StreamController<SafrTrafficTick> traffic;
  late Completer<bool> boardAck;

  DeviceCommandTracker tracker(FakeAsync async) {
    boardAck = Completer<bool>();
    return DeviceCommandTracker(
      send: (_, __) => boardAck.future,
      deliveries: deliveries.stream,
      traffic: traffic.stream,
      clock: () => t0.add(async.elapsed),
    );
  }

  SafrTrafficTick frame({int? boot, int? uptimeS}) => SafrTrafficTick(
        mac: unit,
        direction: SafrTrafficDirection.uplink,
        severity: 0,
        msgType: SafrMsgType.heartbeat,
        bootCtr: boot,
        uptimeS: uptimeS,
      );

  setUp(() {
    deliveries = StreamController<String>.broadcast();
    traffic = StreamController<SafrTrafficTick>.broadcast();
  });

  test('sent → the board (✓) → the unit confirms (✓✓) → it is back', () {
    fakeAsync((async) {
      final t = tracker(async);
      traffic.add(frame(boot: 7, uptimeS: 5000));
      async.flushMicrotasks();

      t.run(unit, DeviceCommandKind.restart);
      boardAck.complete(true);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.boardAck);

      deliveries.add(unit);
      async.flushMicrotasks();
      final confirmed = t.state[unit]!;
      expect(confirmed.step, DeviceCommandStep.delivered);
      expect(confirmed.inFlight, isTrue, reason: 'still waited for');
      expect(commandStepText(confirmed), 'Reiniciar · confirmado, reiniciando');

      // A frame of the boot that is ending is not the unit back.
      async.elapse(const Duration(seconds: 1));
      traffic.add(frame(boot: 7, uptimeS: 5001));
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);

      async.elapse(const Duration(seconds: 20));
      traffic.add(frame(boot: 8, uptimeS: 4));
      async.flushMicrotasks();
      final back = t.state[unit]!;
      expect(back.step, DeviceCommandStep.answered);
      expect(back.inFlight, isFalse);
      expect(commandStepText(back), 'Reiniciar · voltou');

      async.elapse(const Duration(seconds: 6));
      expect(t.state[unit], isNull);
      t.dispose();
    });
  });

  test('confirmed and never heard again: red, "não voltou"', () {
    fakeAsync((async) {
      final t = tracker(async);
      traffic.add(frame(boot: 7));
      t.run(unit, DeviceCommandKind.restart);
      boardAck.complete(true);
      deliveries.add(unit);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);

      async.elapse(restartReturnWindow - const Duration(seconds: 1));
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);
      async.elapse(const Duration(seconds: 2));
      expect(t.state[unit]!.step, DeviceCommandStep.failed);
      expect(t.state[unit]!.note, DeviceCommandTracker.notBackNote);
      expect(commandStepText(t.state[unit]!), 'Reiniciar · não voltou');
      t.dispose();
    });
  });

  test('a battery unit: its wake is a new boot, never taken for the restart',
      () {
    fakeAsync((async) {
      final t = tracker(async);
      traffic.add(frame(boot: 40));
      async.flushMicrotasks();
      t.run(unit, DeviceCommandKind.restart, waitsForWake: true);
      boardAck.complete(true);
      async.flushMicrotasks();

      // It wakes (BOOT_CTR 41), says its heartbeat, takes the command from
      // its parent and confirms it — all in the boot that then restarts.
      async.elapse(const Duration(seconds: 30));
      traffic.add(frame(boot: 41, uptimeS: 0));
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.boardAck,
          reason: 'not confirmed yet: a wake proves nothing');
      deliveries.add(unit);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered);

      async.elapse(const Duration(seconds: 5));
      traffic.add(frame(boot: 42, uptimeS: 0));
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.answered);
      t.dispose();
    });
  });

  test('no BOOT_CTR to compare: a heartbeat that booted after the ACK', () {
    fakeAsync((async) {
      final t = tracker(async);
      t.run(unit, DeviceCommandKind.restart);
      boardAck.complete(true);
      deliveries.add(unit);
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 10));
      traffic.add(frame(uptimeS: 900));
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.delivered,
          reason: 'up for 15 min: it has not restarted');
      traffic.add(frame(uptimeS: 6));
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.answered);
      t.dispose();
    });
  });

  test('a phone asks the central; a refusal is shown as it was worded', () {
    fakeAsync((async) {
      String? refusal;
      final asked = <(String, DeviceCommandKind)>[];
      final t = DeviceCommandTracker(
        askCentral: (mac, kind) async {
          asked.add((mac, kind));
          return refusal;
        },
        traffic: traffic.stream,
      );
      expect(DeviceCommandTracker.phoneMayAsk,
          contains(DeviceCommandKind.restart));
      t.run(unit, DeviceCommandKind.restart);
      async.flushMicrotasks();
      expect(asked, [(unit, DeviceCommandKind.restart)]);
      expect(t.state[unit]!.step, DeviceCommandStep.boardAck);

      // The central's steps then arrive as `command` events.
      for (final step in [
        DeviceCommandStep.delivered,
        DeviceCommandStep.answered
      ]) {
        t.applyRemote(DeviceCommandStatus(
            mac: unit,
            kind: DeviceCommandKind.restart,
            step: step,
            startedAt: t0));
        expect(t.state[unit]!.step, step);
      }

      async.elapse(const Duration(seconds: 30));
      refusal = 'Só para Administrador';
      t.run(unit, DeviceCommandKind.restart);
      async.flushMicrotasks();
      expect(t.state[unit]!.step, DeviceCommandStep.failed);
      expect(t.state[unit]!.note, 'Só para Administrador');
      t.dispose();
    });
  });

  test('on the wire it is a new kind at the end: the old ones keep theirs', () {
    expect(DeviceCommandKind.values.last, DeviceCommandKind.restart);
    expect(DeviceCommandKind.unitEvent.index, 7);
    final wire = DeviceCommandStatus(
      mac: unit,
      kind: DeviceCommandKind.restart,
      step: DeviceCommandStep.answered,
      startedAt: t0,
      waitsForWake: true,
    ).wire;
    final back = DeviceCommandStatus.fromWire(unit, wire, at: t0)!;
    expect(back.kind, DeviceCommandKind.restart);
    expect(back.step, DeviceCommandStep.answered);
    expect(back.waitsForWake, isTrue);
  });

  test('unit_restart round trip; never read as a test of the unit', () {
    final back = decodeMirrorRemoteTest(
        encodeMirrorUnitRestart(id: 'r1', mac: unit, name: 'Ana'))!;
    expect((back.id, back.mac, back.restart, back.name),
        ('r1', unit, true, 'Ana'));
    expect(
        decodeMirrorRemoteTest(encodeMirrorUnitTest(id: 't1', mac: unit))!
            .restart,
        isFalse);
    expect(decodeMirrorRemoteOta(encodeMirrorUnitRestart(id: 'r2', mac: unit)),
        isNull);
  });
}
