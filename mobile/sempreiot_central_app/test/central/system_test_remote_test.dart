import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_publisher.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_viewer.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/system_test/system_test_run.dart';

import 'fake_mqtt_repo.dart';

/// "Testar tudo" from a phone (docs/cloud/central-mirror.md §4.9), and the
/// two rules that keep the retained `test` record true (§4.7, 2026-10-31):
/// the central retries a lost write until it lands, and a phone distrusts
/// a "running" written too long ago.
void main() {
  const central = 'us-east-1:aaaaaaaa-0000-0000-0000-000000000001';
  const phone = 'us-east-1:bbbbbbbb-0000-0000-0000-000000000002';
  final t0 = DateTime.utc(2026, 10, 31, 20, 36, 58);

  SystemTestRun running({String? by}) => SystemTestRun(
        id: 'x',
        startedAt: t0,
        verdict: SystemTestVerdict.running,
        boardAcked: true,
        by: by,
        units: const [
          SystemTestUnit(
              mac: 'AA:00:00:00:00:01', outcome: SystemTestOutcome.confirmed),
        ],
      );

  group('codec', () {
    test('test_start / test_cancel round trip; anything else is not one', () {
      final start =
          decodeMirrorRemoteTest(encodeMirrorTestStart(id: 't1', name: 'Ana'))!;
      expect(start.id, 't1');
      expect(start.cancel, isFalse);
      expect(start.name, 'Ana');
      final cancel = decodeMirrorRemoteTest(encodeMirrorTestCancel(id: 't2'))!;
      expect(cancel.cancel, isTrue);
      expect(cancel.name, isNull);
      expect(decodeMirrorRemoteTest(encodeMirrorOtaCancel(id: 'r1')), isNull);
      expect(decodeMirrorRemoteTest('not json'), isNull);
      expect(decodeMirrorRemoteOta(encodeMirrorTestStart(id: 't3')), isNull,
          reason: 'a test request is never read as an update');
    });

    test('a running record is a test only while it can still be true', () {
      final tests = MirrorTests(at: t0, running: running());
      expect(tests.runningAt(t0.add(const Duration(seconds: 90))), isNotNull);
      expect(tests.runningAt(t0.add(mirrorTestsStaleAfter)), isNull,
          reason: 'its end never reached the broker: no test, no ✓✓');
      expect(
          tests.runningAt(t0.subtract(const Duration(seconds: 30))), isNotNull,
          reason: 'a phone clock behind the central is not a stale record');
      expect(MirrorTests(at: DateTime.utc(2000)).runningAt(t0), isNull);
      final decoded = decodeMirrorTests(
          encodeMirrorTests(at: t0, running: running(by: 'remote:Ana')))!;
      expect(decoded.running!.by, 'remote:Ana');
    });
  });

  group('the central', () {
    late DateTime now;
    late List<({String topic, String payload, bool retain})> sent;
    late List<(String, MirrorRemoteTest)> asked;
    late String? answer;
    late bool connected;
    late String? identity;
    late CentralMirrorPublisher publisher;

    List<MirrorEvent> events() => [
          for (final m in sent)
            if (m.topic == mirrorFramesTopic(central))
              ...decodeMirrorFrames(m.payload)!.events,
        ];
    List<MirrorTests> tests() => [
          for (final m in sent)
            if (m.topic == mirrorTestTopic(central))
              decodeMirrorTests(m.payload)!,
        ];

    setUp(() {
      now = DateTime.utc(2026, 10, 31, 20, 36);
      sent = [];
      asked = [];
      answer = null;
      connected = true;
      identity = central;
      publisher = CentralMirrorPublisher(
        identityId: () => identity,
        publish: (topic, payload, {retain = false, qos = 1}) {
          if (!connected) return false;
          sent.add((topic: topic, payload: payload, retain: retain));
          return true;
        },
        nodes: () => const [],
        link: () => 'connected',
        remoteTest: (user, command) async {
          asked.add((user, command));
          return answer;
        },
        clock: () => now,
      );
    });

    test('a phone starts the test: who asked from the topic, answered at once',
        () async {
      publisher.onCommand(encodeMirrorWatch(hello: true, sub: 'ana'));
      publisher.onUserCommand(
          phone, encodeMirrorTestStart(id: 't1', name: 'Ana'));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      expect(asked.single.$1, phone);
      expect(asked.single.$2.cancel, isFalse);
      expect(events().map((e) => (e.kind, e.mac, e.arg)), [
        (MirrorEventKind.testAnswer, 't1', MirrorOtaAnswer.started),
      ]);
    });

    test('a refusal carries the reason (one test at a time)', () async {
      publisher.onCommand(encodeMirrorWatch(hello: true, sub: 'ana'));
      answer = 'Já há um teste em andamento. Iniciado por Ana.';
      publisher.onUserCommand(phone, encodeMirrorTestCancel(id: 't2'));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      final last = events().single;
      expect(last.kind, MirrorEventKind.testAnswer);
      expect(last.arg, MirrorOtaAnswer.refused);
      expect(last.text, answer);
      expect(asked.single.$2.cancel, isTrue);
    });

    test('the end of a test lost to a dropped session is written again',
        () async {
      final run = running();
      publisher.onSystemTests(run, [run]);
      expect(tests().single.running, isNotNull);
      // The session drops just as the test ends.
      connected = false;
      final ended =
          run.copyWith(verdict: SystemTestVerdict.failed, endedAt: now);
      publisher.onSystemTests(null, [ended]);
      publisher.pump();
      expect(tests(), hasLength(1), reason: 'nothing could be written');
      // Back: the pump writes it, watched or not, without a new change.
      connected = true;
      publisher.pump();
      expect(tests(), hasLength(1), reason: 'not before retryEvery');
      now = now.add(CentralMirrorPublisher.retryEvery);
      publisher.pump();
      expect(tests(), hasLength(2));
      expect(tests().last.running, isNull);
      expect(tests().last.recent.single.verdict, SystemTestVerdict.failed);
      expect(sent.last.retain, isTrue);
      // Landed: the pump has nothing more to write.
      now = now.add(CentralMirrorPublisher.retryEvery);
      publisher.pump();
      expect(tests(), hasLength(2));
    });

    test('no identity at start-up: written once there is one', () {
      identity = null;
      publisher.onSystemTests(null, [running()]);
      publisher.onAlarms(const []);
      publisher.pump();
      expect(sent, isEmpty);
      identity = central;
      now = now.add(CentralMirrorPublisher.retryEvery);
      publisher.pump();
      expect(sent.map((m) => m.topic),
          containsAll([mirrorTestTopic(central), mirrorAlarmTopic(central)]));
    });
  });

  group('the phone', () {
    late FakeMqttRepo repo;
    late CentralMirrorViewer viewer;

    setUp(() {
      repo = FakeMqttRepo();
      viewer = CentralMirrorViewer(
        centralId: central,
        repo: repo,
        traffic: SafrTrafficBus(),
        accountName: () => 'Ana',
      )..onConnected();
    });
    tearDown(() => viewer.dispose());

    void answerWith(String id, int arg, [String? text]) => repo.deliver(
          mirrorFramesTopic(central),
          encodeMirrorFrames(
            seq: 1,
            t0: DateTime.utc(2026),
            ticks: const [],
            events: [
              (kind: MirrorEventKind.testAnswer, mac: id, arg: arg, text: text)
            ],
          ),
        );

    String lastId() => decodeMirrorRemoteTest(repo.published.last.payload)!.id;

    test('asks on its own command topic and takes the answer', () async {
      final result = viewer.sendTestStart();
      expect(repo.published.last.topic,
          mirrorUserCommandTopic(central, repo.identityId!));
      final request = decodeMirrorRemoteTest(repo.published.last.payload)!;
      expect(request.cancel, isFalse);
      expect(request.name, 'Ana');
      answerWith(lastId(), MirrorOtaAnswer.started);
      expect(await result, isNull);
    });

    test('a refusal comes back as the central worded it', () async {
      final result = viewer.sendTestCancel();
      expect(
          decodeMirrorRemoteTest(repo.published.last.payload)!.cancel, isTrue);
      answerWith(lastId(), MirrorOtaAnswer.refused,
          'Só a central, ou quem iniciou o teste, pode cancelá-lo.');
      expect(await result,
          'Só a central, ou quem iniciou o teste, pode cancelá-lo.');
    });
  });
}
