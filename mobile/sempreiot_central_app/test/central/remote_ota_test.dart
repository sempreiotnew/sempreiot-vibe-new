import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_publisher.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_viewer.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_release.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';

import 'fake_mqtt_repo.dart';

/// An Internet update asked from a phone (docs/ota/ota-internet-plan.md
/// §5.4, §6): the topic says who asks, the central answers on the frames.
void main() {
  const central = 'us-east-1:aaaaaaaa-0000-0000-0000-000000000001';
  const phone = 'us-east-1:bbbbbbbb-0000-0000-0000-000000000002';

  group('codec', () {
    test("the user's command topic, and who it names", () {
      expect(mirrorUserCommandTopic(central, phone), '$central/cmd/$phone');
      expect(mirrorUserCommandFilter(central), '$central/cmd/+');
      expect(mirrorCommandUser(central, '$central/cmd/$phone'), phone);
      expect(mirrorCommandUser(central, central), isNull);
      expect(mirrorCommandUser(central, '$central/cmd/'), isNull);
      expect(mirrorCommandUser(central, '$central/cmd/a/b'), isNull,
          reason: 'one level only: AWS proves only the last one');
      expect(mirrorCommandUser(central, 'other/cmd/$phone'), isNull);
    });

    test('ota_start and ota_cancel round trip', () {
      final one = decodeMirrorRemoteOta(encodeMirrorOtaStart(
          id: 'r1',
          family: SafrProductFamily.node,
          version: '0.3.4',
          units: ['5A:46:52:00:00:02'],
          name: 'Ana'))!;
      expect(one.id, 'r1');
      expect(one.cancel, isFalse);
      expect(one.all, isFalse);
      expect(one.family, SafrProductFamily.node);
      expect(one.version, '0.3.4');
      expect(one.units, ['5A:46:52:00:00:02']);
      expect(one.name, 'Ana');

      final all = decodeMirrorRemoteOta(encodeMirrorOtaStart(id: 'r2', all: true))!;
      expect(all.all, isTrue);

      final cancel = decodeMirrorRemoteOta(encodeMirrorOtaCancel(id: 'r3'))!;
      expect(cancel.cancel, isTrue);

      // A start that is neither "all" nor a family at a version: refused.
      expect(
          decodeMirrorRemoteOta(jsonEncode(
              {'v': 1, 'type': 'ota_start', 'id': 'x', 'family': 'node'})),
          isNull);
      expect(decodeMirrorRemoteOta('{"type":"watch"}'), isNull);
    });

    test('the ota message carries what is published and what the badge counts',
        () {
      final release = FirmwareRelease(
        version: '0.3.4',
        bucket: 'sempreiot-releases',
        region: 'us-east-1',
        published: DateTime.utc(2026, 10, 5, 16),
        publishedBy: const FirmwarePublisher(who: 'tallesaugusto'),
        notes: 'fix',
        forThisCentral: true,
        images: const {
          SafrProductFamily.node: FirmwareReleaseImage(
              key: 'k', size: 1000, sha256: 'secret', project: 'sempreiot-node'),
        },
      );
      const updates = UpdatesAvailable(
        units: {
          SafrProductFamily.node: ['5A:46:52:00:00:02']
        },
        versions: {SafrProductFamily.node: '0.3.4'},
      );
      final payload = encodeMirrorOta(
          seq: 1, run: null, push: null, releases: [release], updates: updates);
      expect(payload, isNot(contains('secret')),
          reason: 'keys and hashes stay on the tablet');
      final ota = decodeMirrorOta(payload)!;
      final r = ota.releases!.single;
      expect(r.version, '0.3.4');
      expect(r.publishedBy!.who, 'tallesaugusto');
      expect(r.notes, 'fix');
      expect(r.forThisCentral, isTrue);
      expect(r.images[SafrProductFamily.node]!.size, 1000);
      expect(ota.updates.count, 1);
      expect(ota.updates.versions[SafrProductFamily.node], '0.3.4');

      // A central from before: no releases, nothing counted.
      final old = decodeMirrorOta(jsonEncode({'v': 1, 'seq': 1, 'run': null}))!;
      expect(old.releases, isNull);
      expect(old.updates.any, isFalse);
    });

    test('an event keeps its text', () {
      final frames = decodeMirrorFrames(encodeMirrorFrames(
        seq: 1,
        t0: DateTime.utc(2026),
        ticks: const [],
        events: const [
          (
            kind: MirrorEventKind.otaAnswer,
            mac: 'r1',
            arg: MirrorOtaAnswer.refused,
            text: 'Há alarme ativo.'
          ),
          (kind: MirrorEventKind.identify, mac: 'AA', arg: 10, text: null),
        ],
      ))!;
      expect(frames.events.first.text, 'Há alarme ativo.');
      expect(frames.events.last.text, isNull);
    });
  });

  group('the central', () {
    late DateTime now;
    late List<({String topic, String payload})> sent;
    late List<(String, MirrorRemoteOta)> asked;
    late String? answer;
    late CentralMirrorPublisher publisher;

    List<MirrorEvent> events() => [
          for (final m in sent)
            if (m.topic == mirrorFramesTopic(central))
              ...decodeMirrorFrames(m.payload)!.events,
        ];

    setUp(() {
      now = DateTime.utc(2026, 10, 5, 12);
      sent = [];
      asked = [];
      answer = null;
      publisher = CentralMirrorPublisher(
        identityId: () => central,
        publish: (topic, payload, {retain = false, qos = 1}) {
          sent.add((topic: topic, payload: payload));
          return true;
        },
        nodes: () => const [],
        link: () => 'connected',
        remoteOta: (user, command) async {
          asked.add((user, command));
          return answer;
        },
        clock: () => now,
      );
      publisher.onCommand(encodeMirrorWatch(hello: true, sub: 'ana'));
    });

    test('heard at once, then started — with who asked from the topic',
        () async {
      publisher.onUserCommand(phone,
          encodeMirrorOtaStart(id: 'r1', all: true, name: 'Ana'));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      expect(asked.single.$1, phone);
      expect(asked.single.$2.all, isTrue);
      expect(events().map((e) => (e.kind, e.mac, e.arg)), [
        (MirrorEventKind.otaAnswer, 'r1', MirrorOtaAnswer.working),
        (MirrorEventKind.otaAnswer, 'r1', MirrorOtaAnswer.started),
      ]);
    });

    test('a refusal carries the reason', () async {
      answer = 'Só um Administrador desta central pode atualizar pela internet.';
      publisher.onUserCommand(phone, encodeMirrorOtaCancel(id: 'r2'));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      final last = events().last;
      expect(last.arg, MirrorOtaAnswer.refused);
      expect(last.text, answer);
    });

    test('something that is not an update command is ignored', () async {
      publisher.onUserCommand(phone, encodeMirrorIdentify('AA'));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      expect(asked, isEmpty);
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
              (kind: MirrorEventKind.otaAnswer, mac: id, arg: arg, text: text)
            ],
          ),
        );

    String lastId() =>
        decodeMirrorRemoteOta(repo.published.last.payload)!.id;

    test('asks on its own command topic and waits for the answer', () async {
      final result = viewer.sendOtaStart(
          family: SafrProductFamily.node, version: '0.3.4', units: ['AA']);
      expect(repo.published.last.topic,
          mirrorUserCommandTopic(central, repo.identityId!));
      final id = lastId();
      answerWith(id, MirrorOtaAnswer.working);
      answerWith(id, MirrorOtaAnswer.started);
      expect(await result, isNull);
    });

    test('a refusal comes back as its reason', () async {
      final result = viewer.sendOtaCancel();
      answerWith(lastId(), MirrorOtaAnswer.refused, 'Nenhuma atualização em andamento.');
      expect(await result, 'Nenhuma atualização em andamento.');
    });

    test('the published versions and the badge come from the central',
        () async {
      repo.deliver(
        mirrorOtaTopic(central),
        encodeMirrorOta(
          seq: 1,
          run: null,
          push: null,
          releases: const [
            FirmwareRelease(
              version: '0.3.4',
              bucket: '',
              region: '',
              images: {
                SafrProductFamily.board:
                    FirmwareReleaseImage(key: '', size: 1, sha256: '', project: ''),
              },
            ),
          ],
          updates: const UpdatesAvailable(
            units: {
              SafrProductFamily.board: ['@board']
            },
            versions: {SafrProductFamily.board: '0.3.4'},
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(viewer.state.releases!.single.version, '0.3.4');
      expect(viewer.state.updates.count, 1);
    });
  });
}
