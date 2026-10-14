import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart'
    show safrBroadcastMac;
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_publisher.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/system_test_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/domain/system_test/system_test_run.dart';

/// The system test as a thing of its own (2026-10-14): kept on the tablet
/// while it runs and after, cancellable, reported, and published retained
/// so a phone opened or reloaded mid-test starts with the whole picture.
void main() {
  const a = 'AA:00:00:00:00:01', b = 'AA:00:00:00:00:02';
  const leaf = 'CC:00:00:00:00:03';
  final t0 = DateTime.utc(2026, 10, 14, 15, 42);

  TopologyNode n(String mac, SafrNodeRole role,
          {bool online = true, String? name}) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: 1,
        parentMac: null,
        rssi: -60,
        batteryPct: null,
        online: online,
        lastSeenAt: t0,
        alarmLatched: false,
        name: name,
      );

  group('controller (the tablet)', () {
    late StreamController<String> deliveries;
    late Completer<bool> boardAck;
    late DateTime now;
    late List<SystemTestRun> saved;
    late List<SystemTestRun> stored;
    late DeviceCommandTracker tracker;
    late SystemTestController controller;
    late StreamSubscription<Map<String, DeviceCommandStatus>> feed;

    void build(List<TopologyNode> nodes) {
      deliveries = StreamController<String>.broadcast();
      boardAck = Completer<bool>();
      tracker = DeviceCommandTracker(
        send: (_, __) => boardAck.future,
        deliveries: deliveries.stream,
        nodes: () => nodes,
        clock: () => now,
      );
      controller = SystemTestController(
        tracker: tracker,
        nodes: () => nodes,
        save: (run) async => saved.add(run),
        load: () async => stored,
        clock: () => now,
      );
      // What the provider does with ref.listen.
      feed = tracker.stream.listen(controller.onCommands);
    }

    setUp(() {
      now = t0;
      saved = [];
      stored = [];
    });

    tearDown(() async {
      await feed.cancel();
      if (controller.mounted) controller.dispose();
      tracker.dispose();
      await deliveries.close();
    });

    test('start: a running run with every unit pending, written at once', () {
      fakeAsync((async) {
        build([
          n(a, SafrNodeRole.root, name: 'Sirene Hall'),
          n(leaf, SafrNodeRole.leaf),
          n(b, SafrNodeRole.node, online: false),
        ]);
        async.flushMicrotasks();
        controller.start();
        async.flushMicrotasks();
        final run = controller.state.running!;
        expect(run.verdict, SystemTestVerdict.running);
        expect(run.boardAcked, isFalse);
        expect(run.id, SystemTestRun.idFor(t0));
        expect({
          for (final u in run.units) u.mac: u.outcome
        }, {
          a: SystemTestOutcome.pending,
          leaf: SystemTestOutcome.pendingWake,
          b: SystemTestOutcome.missing,
        });
        expect(run.units.firstWhere((u) => u.mac == a).name, 'Sirene Hall');
        // Written as it moves (the start, then each change the tracker
        // reports), always as the same running run.
        expect(saved, isNotEmpty);
        expect(saved.every((r) => r.id == run.id), isTrue);
        expect(saved.every((r) => r.verdict == SystemTestVerdict.running),
            isTrue);

        boardAck.complete(true);
        async.flushMicrotasks();
        expect(controller.state.running!.boardAcked, isTrue);
      });
    });

    test('every unit confirms: passed, in the history, written once more', () {
      fakeAsync((async) {
        build([n(a, SafrNodeRole.root), n(b, SafrNodeRole.node)]);
        controller.start();
        boardAck.complete(true);
        async.flushMicrotasks();
        now = t0.add(const Duration(seconds: 3));
        deliveries.add(a);
        async.flushMicrotasks();
        expect(controller.state.running!.confirmed, 1);
        expect(controller.state.running!.units.firstWhere((u) => u.mac == a).at,
            now);
        now = t0.add(const Duration(seconds: 7));
        deliveries.add(b);
        async.flushMicrotasks();
        expect(controller.state.running, isNull);
        final done = controller.state.recent.single;
        expect(done.verdict, SystemTestVerdict.passed);
        expect(done.endedAt, now);
        expect(done.elapsed(), const Duration(seconds: 7));
        expect(done.summary, '2 confirmaram');
        expect(saved.last.verdict, SystemTestVerdict.passed);
        expect(saved.last.id, done.id);
      });
    });

    test('cancel: the units still waiting are "cancelado", the run says so',
        () {
      fakeAsync((async) {
        build([n(a, SafrNodeRole.root), n(b, SafrNodeRole.node)]);
        controller.start();
        boardAck.complete(true);
        deliveries.add(a);
        async.flushMicrotasks();
        expect(controller.cancel(), isTrue);
        async.flushMicrotasks();
        expect(controller.state.running, isNull);
        final done = controller.state.recent.single;
        expect(done.verdict, SystemTestVerdict.cancelled);
        expect({
          for (final u in done.units) u.mac: u.outcome
        }, {
          a: SystemTestOutcome.confirmed,
          b: SystemTestOutcome.cancelled,
        });
        expect(done.summary, '1 confirmou · 1 cancelado');
        expect(tracker.state[b]!.note, DeviceCommandTracker.cancelledNote);
        expect(tracker.broadcastTally.text, '1 confirmou · 1 cancelado');
        // Nothing runs: nothing to cancel.
        expect(controller.cancel(), isFalse);
      });
    });

    test('the window closes on a unit: failed, with "sem resposta"', () {
      fakeAsync((async) {
        build([n(a, SafrNodeRole.root), n(b, SafrNodeRole.node)]);
        controller.start();
        boardAck.complete(true);
        deliveries.add(a);
        async.flushMicrotasks();
        async.elapse(DeviceCommandTracker.broadcastWindow);
        final done = controller.state.recent.single;
        expect(done.verdict, SystemTestVerdict.failed);
        expect(done.units.firstWhere((u) => u.mac == b).outcome,
            SystemTestOutcome.noAnswer);
      });
    });

    test('one test at a time; the history comes from the database', () {
      fakeAsync((async) {
        stored = [
          SystemTestRun(
            id: 'old',
            startedAt: t0.subtract(const Duration(days: 1)),
            endedAt: t0.subtract(const Duration(days: 1, minutes: -1)),
            verdict: SystemTestVerdict.passed,
            units: const [],
          ),
          // Running when the app died: closed as failed on restart.
          SystemTestRun(
            id: 'stale',
            startedAt: t0.subtract(const Duration(hours: 1)),
            verdict: SystemTestVerdict.running,
            units: const [
              SystemTestUnit(mac: a, outcome: SystemTestOutcome.pending),
            ],
          ),
        ];
        build([n(a, SafrNodeRole.root)]);
        async.flushMicrotasks();
        expect(controller.state.recent.map((r) => r.id), ['old', 'stale']);
        expect(controller.state.recent[1].verdict, SystemTestVerdict.failed);
        expect(controller.state.recent[1].units.single.outcome,
            SystemTestOutcome.noAnswer);
        expect(saved.map((r) => r.id), ['stale']);

        controller.start();
        async.flushMicrotasks();
        var second = true;
        controller.start().then((ok) => second = ok);
        async.flushMicrotasks();
        expect(second, isFalse);
      });
    });
  });

  group('the phone', () {
    test(
        'seeds its tracker from the running test: the broadcast, then '
        'its units, with their outcomes', () {
      fakeAsync((async) {
        final t = DeviceCommandTracker();
        t.seedFromRun(SystemTestRun(
          id: 'x',
          startedAt: t0,
          verdict: SystemTestVerdict.running,
          boardAcked: true,
          by: 'ana@x.com',
          units: const [
            SystemTestUnit(mac: a, outcome: SystemTestOutcome.confirmed),
            SystemTestUnit(mac: leaf, outcome: SystemTestOutcome.pendingWake),
            SystemTestUnit(mac: b, outcome: SystemTestOutcome.missing),
          ],
        ));
        expect(t.state[safrBroadcastMac]!.step, DeviceCommandStep.boardAck);
        expect(t.state[safrBroadcastMac]!.by, 'ana@x.com');
        expect(t.state[a]!.step, DeviceCommandStep.delivered);
        expect(t.state[leaf]!.step, DeviceCommandStep.sending);
        expect(t.state[leaf]!.waitsForWake, isTrue);
        expect(t.state[b]!.step, DeviceCommandStep.failed);
        expect(t.state[b]!.note, DeviceCommandTracker.missingNote);
        expect(t.broadcastTally.text,
            '1 confirmou · 1 pendente (1 no próximo despertar) · 1 sem comunicação');
        expect(t.state[safrBroadcastMac]!.note,
            '1 confirmou · 1 pendente (1 no próximo despertar) · 1 sem comunicação');
        // Seeded again (the retained message moves): nothing goes back.
        t.seedFromRun(SystemTestRun(
          id: 'x',
          startedAt: t0,
          verdict: SystemTestVerdict.running,
          boardAcked: true,
          units: const [
            SystemTestUnit(mac: a, outcome: SystemTestOutcome.pending),
          ],
        ));
        expect(t.state[a]!.step, DeviceCommandStep.delivered);
        // An ended test seeds nothing.
        final fresh = DeviceCommandTracker();
        fresh.seedFromRun(SystemTestRun(
          id: 'y',
          startedAt: t0,
          verdict: SystemTestVerdict.passed,
          units: const [],
        ));
        expect(fresh.state, isEmpty);
        t.dispose();
        fresh.dispose();
      });
    });
  });

  group('the wire', () {
    final run = SystemTestRun(
      id: 'abc',
      startedAt: t0,
      endedAt: t0.add(const Duration(seconds: 48)),
      by: 'ana@x.com',
      verdict: SystemTestVerdict.failed,
      boardAcked: true,
      units: [
        SystemTestUnit(
            mac: a,
            name: 'Sirene Hall',
            outcome: SystemTestOutcome.confirmed,
            at: t0.add(const Duration(seconds: 2))),
        const SystemTestUnit(mac: b, outcome: SystemTestOutcome.noAnswer),
      ],
    );

    test('a run comes back as itself', () {
      final back = SystemTestRun.fromJson(run.toJson())!;
      expect(back.id, 'abc');
      expect(back.startedAt, t0);
      expect(back.endedAt, run.endedAt);
      expect(back.by, 'ana@x.com');
      expect(back.verdict, SystemTestVerdict.failed);
      expect(back.boardAcked, isTrue);
      expect(back.units.map((u) => u.mac), [a, b]);
      expect(back.units.first.name, 'Sirene Hall');
      expect(back.units.first.at, t0.add(const Duration(seconds: 2)));
      expect(back.units.last.outcome, SystemTestOutcome.noAnswer);
      expect(back.summary, '1 confirmou · 1 sem resposta');
    });

    test('the retained test message: the running one and the last ones', () {
      final running = run.copyWith(verdict: SystemTestVerdict.running);
      final decoded = decodeMirrorTests(encodeMirrorTests(
        at: t0,
        running: running,
        recent: [for (var i = 0; i < 15; i++) run],
      ))!;
      expect(decoded.running!.running, isTrue);
      expect(decoded.recent, hasLength(mirrorTestsRecent));
      final none = decodeMirrorTests(encodeMirrorTests(at: t0))!;
      expect(none.running, isNull);
      expect(none.recent, isEmpty);
      expect(decodeMirrorTests('{"v":99}'), isNull);
    });

    test(
        'the central writes it retained on every change and on every new '
        'session, with nobody watching', () {
      final sent = <({String topic, String payload, bool retain})>[];
      final publisher = CentralMirrorPublisher(
        identityId: () => 'central-1',
        publish: (topic, payload, {retain = false, qos = 1}) {
          sent.add((topic: topic, payload: payload, retain: retain));
          return true;
        },
        nodes: () => const [],
        link: () => 'connected',
        clock: () => t0,
      );
      publisher.onSystemTests(run, [run]);
      expect(sent.single.topic, mirrorTestTopic('central-1'));
      expect(sent.single.retain, isTrue);
      expect(decodeMirrorTests(sent.single.payload)!.running!.id, 'abc');
      // The same again: not written again.
      publisher.onSystemTests(run, [run]);
      expect(sent, hasLength(1));
      // Ended: written (running gone).
      publisher.onSystemTests(null, [run]);
      expect(sent, hasLength(2));
      expect(decodeMirrorTests(sent.last.payload)!.running, isNull);
      // A new MQTT session rewrites what the broker holds.
      publisher.onConnected();
      expect(sent.where((m) => m.topic == mirrorTestTopic('central-1')),
          hasLength(3));
    });
  });
}
