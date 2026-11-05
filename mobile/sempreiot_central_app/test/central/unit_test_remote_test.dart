import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/access/application/central_access_provider.dart';
import 'package:sempreiot_central_app/features/access/domain/entities/access_level.dart';
import 'package:sempreiot_central_app/features/access/domain/entities/access_relation.dart';
import 'package:sempreiot_central_app/features/central/application/central_iot_provider.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_publisher.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/remote_system_test.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';
import 'package:sempreiot_central_app/features/central/application/system_test_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/iot/domain/entities/mqtt_message_entity.dart';

import 'fake_mqtt_repo.dart';

/// "Testar" of one unit from a phone (docs/cloud/central-mirror.md §4.10):
/// an Administrador's, on the phone's own topic, sent by the central as its
/// own popover sends it — and the rule that the central never says "not an
/// Administrador" from a list of users it has not read yet.
void main() {
  const central = 'us-east-1:aaaaaaaa-0000-0000-0000-000000000001';
  const admin = 'us-east-1:bbbbbbbb-0000-0000-0000-000000000002';
  const viewer = 'us-east-1:cccccccc-0000-0000-0000-000000000003';
  const unit = 'AA:00:00:00:00:01';
  const detector = 'CC:00:00:00:00:03';
  const silent = 'AA:00:00:00:00:09';
  final t0 = DateTime.utc(2026, 11, 5, 14);

  AccessRelation user(String identityId, AccessLevel level) => AccessRelation(
        centralIdentityId: central,
        userSubId: 'sub-$identityId',
        userIdentityId: identityId,
        status: 'ACCEPTED',
        level: level,
        requestId: 'r',
        requestedAt: t0,
        resolvedAt: t0,
        updatedAt: t0,
      );

  TopologyNode node(String mac, SafrNodeRole role, {bool online = true}) =>
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
      );

  group('codec', () {
    test('unit_test round trip; it needs a unit; never read as an update', () {
      final test = decodeMirrorRemoteTest(
          encodeMirrorUnitTest(id: 'u1', mac: unit, name: 'Ana'))!;
      expect(test.id, 'u1');
      expect(test.mac, unit);
      expect(test.cancel, isFalse);
      expect(test.name, 'Ana');
      expect(
          decodeMirrorRemoteTest(encodeMirrorTestStart(id: 't1'))!.mac, isNull,
          reason: 'the system test names no unit');
      expect(
          decodeMirrorRemoteTest(
              jsonEncode({'v': 1, 'type': 'unit_test', 'id': 'u2'})),
          isNull);
      expect(decodeMirrorRemoteOta(encodeMirrorUnitTest(id: 'u3', mac: unit)),
          isNull);
    });
  });

  group('the central\'s mirror', () {
    late List<({String topic, String payload})> sent;
    late List<(String, MirrorRemoteTest)> asked;
    late String? answer;
    late CentralMirrorPublisher publisher;

    List<MirrorEvent> events() => [
          for (final m in sent)
            if (m.topic == mirrorFramesTopic(central))
              ...decodeMirrorFrames(m.payload)!.events,
        ];

    setUp(() {
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
        remoteTest: (user, command) async {
          asked.add((user, command));
          return answer;
        },
        clock: () => t0,
      );
      publisher.onCommand(encodeMirrorWatch(hello: true, sub: 'ana'));
    });

    test('who asked comes from the topic; the answer pairs with the request',
        () async {
      publisher.onUserCommand(
          admin, encodeMirrorUnitTest(id: 'u1', mac: unit, name: 'Ana'));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      expect(asked.single.$1, admin);
      expect(asked.single.$2.mac, unit);
      expect(events().map((e) => (e.kind, e.mac, e.arg)), [
        (MirrorEventKind.testAnswer, 'u1', MirrorOtaAnswer.started),
      ]);
    });

    test('a refusal carries the central\'s reason', () async {
      answer = RemoteSystemTest.unitNotAdmin;
      publisher.onUserCommand(
          viewer, encodeMirrorUnitTest(id: 'u2', mac: unit));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      final last = events().single;
      expect(last.arg, MirrorOtaAnswer.refused);
      expect(last.text, RemoteSystemTest.unitNotAdmin);
    });

    test('never taken from the open topic, where nobody is proven', () async {
      publisher.onCommand(encodeMirrorUnitTest(id: 'u3', mac: unit));
      await Future<void>.delayed(Duration.zero);
      publisher.pump();
      expect(asked, isEmpty);
    });
  });

  group('the central\'s checks', () {
    late AppDatabase db;
    late ProviderContainer container;
    late List<(String, DeviceCommandKind)> sentDown;
    late bool boardTakes;
    late bool linkUp;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      sentDown = [];
      boardTakes = true;
      linkUp = true;
      final nodes = [
        node(unit, SafrNodeRole.node),
        node(detector, SafrNodeRole.leaf),
        node(silent, SafrNodeRole.node, online: false),
      ];
      container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        topologyProvider.overrideWithValue(nodes),
        boardLinkUpProvider.overrideWith((_) => linkUp),
        centralAccessRelationsProvider.overrideWith((ref) => _Relations(ref, [
              user(admin, AccessLevel.level4),
              user(viewer, AccessLevel.level1),
            ])),
        deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
              send: (mac, kind) async {
                sentDown.add((mac, kind));
                return boardTakes;
              },
              nodes: () => nodes,
            )),
      ]);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<String?> ask(String who, String mac) => container
        .read(remoteSystemTestProvider)
        .handle(who, MirrorRemoteTest(id: 'u', mac: mac, name: 'Ana'));

    Future<List<String>> audit() async =>
        [for (final e in await db.recentAudit()) e.action];

    test('an Administrador: TESTAR goes down as from the tablet\'s popover',
        () async {
      expect(await ask(admin, unit), isNull);
      expect(sentDown, [(unit, DeviceCommandKind.test)]);
      final status = container.read(deviceCommandProvider)[unit]!;
      expect(status.kind, DeviceCommandKind.test);
      expect(status.step, DeviceCommandStep.boardAck);
      expect(status.by, 'Ana', reason: 'who asked, on every screen');
      await pumpEventQueue();
      expect(await audit(), ['unit_test_remote_started']);
    });

    test('anyone else is refused, and nothing is sent', () async {
      expect(await ask(viewer, unit), RemoteSystemTest.unitNotAdmin);
      expect(
          await ask('us-east-1:nobody', unit), RemoteSystemTest.unitNotAdmin);
      expect(sentDown, isEmpty);
      await pumpEventQueue();
      expect(await audit(),
          ['unit_test_remote_refused', 'unit_test_remote_refused']);
    });

    test('only a mains unit the central hears', () async {
      expect(await ask(admin, silent), RemoteSystemTest.unitUnreachable);
      expect(await ask(admin, 'AA:00:00:00:00:77'),
          RemoteSystemTest.unitUnreachable);
      expect(await ask(admin, detector), RemoteSystemTest.unitIsBattery);
      linkUp = false;
      container.invalidate(boardLinkUpProvider);
      expect(await ask(admin, unit), RemoteSystemTest.unitNoLink);
      expect(sentDown, isEmpty);
    });

    test('the board did not take it: said so', () async {
      boardTakes = false;
      expect(await ask(admin, unit), RemoteSystemTest.unitNoBoardAck);
      expect(sentDown, hasLength(1));
    });

    test('not while the system test runs; one command at a time per unit',
        () async {
      await container.read(systemTestControllerProvider.notifier).start();
      expect(container.read(systemTestControllerProvider).running, isNotNull);
      sentDown.clear();
      expect(await ask(admin, unit), RemoteSystemTest.unitTestRunning);
      expect(sentDown, isEmpty);
    });

    test('a unit busy with another command is not sent a second one', () async {
      final hold = Completer<bool>();
      final busy = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        topologyProvider.overrideWithValue([node(unit, SafrNodeRole.node)]),
        boardLinkUpProvider.overrideWith((_) => true),
        centralAccessRelationsProvider.overrideWith(
            (ref) => _Relations(ref, [user(admin, AccessLevel.master)])),
        deviceCommandProvider.overrideWith(
            (ref) => DeviceCommandTracker(send: (_, __) => hold.future)),
      ]);
      addTearDown(busy.dispose);
      busy
          .read(deviceCommandProvider.notifier)
          .run(unit, DeviceCommandKind.identify);
      expect(
          await busy
              .read(remoteSystemTestProvider)
              .handle(admin, const MirrorRemoteTest(id: 'u', mac: unit)),
          RemoteSystemTest.unitBusy);
      hold.complete(true);
    });
  });

  // 2026-11-05: the first "Testar tudo" a phone asked for after the tablet
  // started was refused — "Só um Administrador…" — to an Administrador. The
  // list of users is built the first time something reads it, and starts
  // empty: the check read it before the tablet's own copy was in.
  group('the list of users is read before anyone is refused', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    ProviderContainer tablet() {
      final nodes = [node(unit, SafrNodeRole.node)];
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        centralIotConnectionProvider.overrideWith(_Offline.new),
        centralMqttMessagesProvider
            .overrideWith((ref) => const Stream<MqttMessageEntity>.empty()),
        centralMqttRepositoryProvider.overrideWithValue(_NoIdentity()),
        topologyProvider.overrideWithValue(nodes),
        boardLinkUpProvider.overrideWith((_) => true),
        deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
            send: (_, __) async => true, nodes: () => nodes)),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('the first request of all finds the Administrador', () async {
      await db.setMeta(
          'access', jsonEncode([user(admin, AccessLevel.level4).toMap()]));
      final container = tablet();
      // Nothing has touched the list yet: this request is what builds it.
      expect(
          await container
              .read(remoteSystemTestProvider)
              .handle(admin, const MirrorRemoteTest(id: 't1', name: 'Ana')),
          isNull,
          reason: '"Testar tudo" starts, the first time as every time');
      expect(container.read(systemTestControllerProvider).running?.by,
          'remote:Ana');
    });

    test('someone who is not one is still refused, once it was read', () async {
      await db.setMeta(
          'access', jsonEncode([user(viewer, AccessLevel.level2).toMap()]));
      final container = tablet();
      expect(
          await container
              .read(remoteSystemTestProvider)
              .handle(viewer, const MirrorRemoteTest(id: 't1')),
          RemoteSystemTest.refusedNotAdmin);
      expect(
          await container
              .read(centralAccessRelationsProvider.notifier)
              .adminOf(admin),
          isNull);
    });
  });
}

/// The central's users as a test gives them: nothing is loaded.
class _Relations extends CentralAccessRelationsNotifier {
  _Relations(super.ref, List<AccessRelation> relations) {
    state = relations;
  }
}

/// The tablet with no cloud session.
class _Offline extends CentralIotConnectionNotifier {
  @override
  Future<bool> build() async => false;
}

/// No identity yet: the backend's list cannot be asked for.
class _NoIdentity extends FakeMqttRepo {
  @override
  String? get identityId => null;
}
