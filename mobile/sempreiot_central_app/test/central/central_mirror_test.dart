import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart'
    show OtaRun, OtaRunUnit;
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_publisher.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_viewer.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_controller.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_history.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_state.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

import 'package:sempreiot_central_app/features/auth/application/auth_provider.dart';
import 'package:sempreiot_central_app/features/auth/domain/entities/auth_user_entity.dart';
import 'package:sempreiot_central_app/features/iot/application/iot_provider.dart';

import 'fake_mqtt_repo.dart';

/// The central mirror (docs/cloud/central-mirror.md): the central sends its
/// live picture only while a user is watching, the held alarms always; the
/// phone replays what arrives into the tablet's own screens.
void main() {
  const id = 'us-east-1:central';
  const boardMac = 'BB:00:00:00:00:00';
  const rootMac = 'AA:00:00:00:00:01';
  const leafMac = 'CC:00:00:00:00:03';

  TopologyNode node(
    String mac,
    SafrNodeRole role,
    int layer, {
    bool online = true,
    bool alarm = false,
    int? rssi = -60,
    DateTime? lastSeen,
    String? name,
  }) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: layer == 0 ? null : boardMac,
        rssi: rssi,
        batteryPct: role == SafrNodeRole.leaf ? 87 : null,
        online: online,
        lastSeenAt: lastSeen ?? DateTime.utc(2026, 10, 3, 21),
        alarmLatched: alarm,
        alarmLatchedAt: alarm ? DateTime.utc(2026, 10, 3, 20, 59) : null,
        name: name,
      );

  SafrTrafficTick heartbeat(String mac) => SafrTrafficTick(
        mac: mac,
        direction: SafrTrafficDirection.uplink,
        severity: 0,
        parentMac: boardMac,
        msgType: SafrMsgType.heartbeat,
        uptimeS: 5310,
      );

  // "Atualizar tudo": the board done, the nodes rolling, paused by an alarm.
  DeviceUpdateRun updateRun({int percent = 40}) => DeviceUpdateRun(
        runId: '0123456789abcdef',
        all: true,
        phases: const [SafrProductFamily.board, SafrProductFamily.node],
        phase: 1,
        target: 'placa v0.3.0 · nós v0.2.1',
        targets: const {
          SafrProductFamily.board: '0.3.0',
          SafrProductFamily.node: '0.2.1',
        },
        queues: const {
          SafrProductFamily.board: [deviceUpdateBoardKey],
          SafrProductFamily.node: [rootMac],
        },
        units: {
          deviceUpdateBoardKey: const DeviceUpdateUnit(
            key: deviceUpdateBoardKey,
            family: SafrProductFamily.board,
            state: SafrOtaUnitState.done,
            versionBefore: '0.2.0',
            version: '0.3.0',
          ),
          rootMac: DeviceUpdateUnit(
            key: rootMac,
            family: SafrProductFamily.node,
            state: SafrOtaUnitState.downloading,
            percent: percent,
            attempts: 2,
            reasonRaw: 3,
            versionBefore: '0.2.0',
            version: '0.2.0',
            note: 'segunda tentativa',
          ),
        },
        stage: DeviceUpdateStage.rolling,
        message: 'Pausado por um alarme',
        pausedBy: OtaPauseCause.alarm,
        startedAt: DateTime.utc(2026, 10, 3, 20, 30),
        boardRestartedAt: DateTime.utc(2026, 10, 3, 20, 32),
        startedBy: 'master',
      );

  const pushing = OtaPushState(
    phase: OtaPushPhase.sending,
    chunksDone: 30,
    bytesDone: 30000,
    totals: (chunks: 120, bytes: 120000),
  );

  final historyRun = (
    OtaRun(
      runId: 'aaaa',
      startedAt: DateTime.utc(2026, 10, 2, 15, 42),
      endedAt: DateTime.utc(2026, 10, 2, 15, 50),
      startedBy: 'master',
      allPhases: false,
      target: '0.2.0',
      families: 'node',
      outcome: 'partial',
      source: 'manual',
    ),
    [
      OtaRunUnit(
        runId: 'aaaa',
        unitKey: rootMac,
        family: 'node',
        versionBefore: '0.1.0',
        versionAfter: '0.2.0',
        state: 'done',
        attempts: 1,
        reasonRaw: 0,
        updatedAt: DateTime.utc(2026, 10, 2, 15, 49),
      ),
      OtaRunUnit(
        runId: 'aaaa',
        unitKey: leafMac,
        family: 'leaf',
        versionBefore: '0.1.0',
        versionAfter: '0.1.0',
        state: 'failed',
        attempts: 3,
        reasonRaw: 4,
        note: 'sem resposta',
        updatedAt: DateTime.utc(2026, 10, 2, 15, 50),
      ),
    ],
  );

  group('codec', () {
    test('an update comes back as the same run and the same push', () {
      final ota = decodeMirrorOta(
          encodeMirrorOta(seq: 3, run: updateRun(), push: pushing))!;
      final run = ota.run!;
      expect(ota.seq, 3);
      expect(run.runId, '0123456789abcdef');
      expect(run.all, isTrue);
      expect(run.phases, [SafrProductFamily.board, SafrProductFamily.node]);
      expect(run.phase, 1);
      expect(run.family, SafrProductFamily.node);
      expect(run.target, 'placa v0.3.0 · nós v0.2.1');
      expect(run.targetOf(SafrProductFamily.node), '0.2.1');
      expect(run.queues[SafrProductFamily.node], [rootMac]);
      expect(run.stage, DeviceUpdateStage.rolling);
      expect(run.running, isTrue);
      expect(run.end, isNull);
      expect(run.message, 'Pausado por um alarme');
      expect(run.pausedBy, OtaPauseCause.alarm);
      expect(run.paused, isTrue);
      expect(run.startedAt, DateTime.utc(2026, 10, 3, 20, 30));
      expect(run.boardRestartedAt, DateTime.utc(2026, 10, 3, 20, 32));
      expect(run.startedBy, 'master');
      final board = run.units[deviceUpdateBoardKey]!;
      expect(board.state, SafrOtaUnitState.done);
      expect(board.versionBefore, '0.2.0');
      expect(board.version, '0.3.0');
      final unit = run.units[rootMac]!;
      expect(unit.family, SafrProductFamily.node);
      expect(unit.state, SafrOtaUnitState.downloading);
      expect(unit.percent, 40);
      expect(unit.attempts, 2);
      expect(unit.reasonRaw, 3);
      expect(unit.note, 'segunda tentativa');
      expect(run.current!.key, rootMac);

      // The push without the image: what the bar and the map read of it.
      final push = ota.push!;
      expect(push.phase, OtaPushPhase.sending);
      expect(push.chunksDone, 30);
      expect(push.chunksTotal, 120);
      expect(push.progress, 0.25);
      expect(push.running, isTrue);
    });

    test('no update, and an ended one', () {
      final none =
          decodeMirrorOta(encodeMirrorOta(seq: 1, run: null, push: null))!;
      expect(none.run, isNull);
      expect(none.push, isNull);

      final ended = decodeMirrorOta(encodeMirrorOta(
        seq: 2,
        run: updateRun().copyWith(
          stage: DeviceUpdateStage.ended,
          end: DeviceUpdateEnd.partial,
          endedAt: DateTime.utc(2026, 10, 3, 20, 45),
          pausedBy: null,
        ),
        push: const OtaPushState(), // idle = nothing to say
      ))!;
      expect(ended.run!.running, isFalse);
      expect(ended.run!.end, DeviceUpdateEnd.partial);
      expect(ended.run!.endedAt, DateTime.utc(2026, 10, 3, 20, 45));
      expect(ended.run!.pausedBy, isNull);
      expect(ended.push, isNull);
      expect(decodeMirrorOta('{"v":1}'), isNull);
    });

    test('the history comes back, and stays inside one message', () {
      final decoded =
          decodeMirrorOtaHistory(encodeMirrorOtaHistory([historyRun]))!;
      final (run, units) = decoded.single;
      expect(run.runId, 'aaaa');
      expect(run.startedAt.toUtc(), DateTime.utc(2026, 10, 2, 15, 42));
      expect(run.outcome, 'partial');
      expect(run.startedBy, 'master');
      expect(units.map((u) => u.unitKey), [rootMac, leafMac]);
      expect(units[1].state, 'failed');
      expect(units[1].note, 'sem resposta');
      expect(units[1].attempts, 3);

      // Too many for one message: the newest ones go, the rest waits.
      final many = [for (var i = 0; i < 400; i++) historyRun];
      final payload = encodeMirrorOtaHistory(many, maxBytes: 10 * 1024);
      expect(payload.length, lessThanOrEqualTo(10 * 1024 + 64));
      final kept = decodeMirrorOtaHistory(payload)!;
      expect(kept.length, inInclusiveRange(1, 399));

      expect(isMirrorOtaHistoryRequest(encodeMirrorOtaHistoryRequest()), isTrue);
      expect(isMirrorOtaHistoryRequest(encodeMirrorWatch()), isFalse);
      expect(decodeMirrorWatch(encodeMirrorOtaHistoryRequest()), isNull);
    });

    test('a snapshot comes back as the same units', () {
      final leaf = TopologyNode(
        mac: leafMac,
        role: SafrNodeRole.leaf,
        layer: 2,
        parentMac: rootMac,
        rssi: -71,
        batteryPct: 87,
        online: true,
        heard: false,
        updating: true,
        lastSeenAt: DateTime.utc(2026, 10, 3, 21, 0, 5),
        alarmLatched: true,
        alarmLatchedAt: DateTime.utc(2026, 10, 3, 20, 59),
        name: 'Hall',
        zone: 'Térreo',
        boardState: SafrDeviceState.online,
        boardFlags: 2,
        parentCandidates: const [(mac: rootMac, rssi: -61)],
        productCode: 3,
        hwRev: 1,
        fwVersion: '0.2.1',
      );
      final decoded = decodeMirrorState(encodeMirrorState(
        seq: 7,
        at: DateTime.utc(2026, 10, 3, 21, 0, 6),
        link: 'connected',
        nodes: [node(boardMac, SafrNodeRole.root, 0), leaf],
      ))!;

      expect(decoded.seq, 7);
      expect(decoded.link, 'connected');
      expect(decoded.at, DateTime.utc(2026, 10, 3, 21, 0, 6));
      expect(decoded.nodes, hasLength(2));
      final n = decoded.nodes[1];
      expect(n.mac, leafMac);
      expect(n.role, SafrNodeRole.leaf);
      expect(n.layer, 2);
      expect(n.parentMac, rootMac);
      expect(n.rssi, -71);
      expect(n.batteryPct, 87);
      expect(n.online, isTrue);
      expect(n.heard, isFalse);
      expect(n.updating, isTrue);
      expect(n.lastSeenAt, DateTime.utc(2026, 10, 3, 21, 0, 5));
      expect(n.alarmLatched, isTrue);
      expect(n.alarmLatchedAt, DateTime.utc(2026, 10, 3, 20, 59));
      expect(n.name, 'Hall');
      expect(n.zone, 'Térreo');
      expect(n.boardState, SafrDeviceState.online);
      expect(n.boardFlags, 2);
      expect(n.parentCandidates, [(mac: rootMac, rssi: -61)]);
      expect(n.productCode, 3);
      expect(n.hwRev, 1);
      expect(n.fwVersion, '0.2.1');
    });

    test('a batch comes back as the same ticks, in order', () {
      final decoded = decodeMirrorFrames(encodeMirrorFrames(
        seq: 12,
        t0: DateTime.utc(2026, 10, 3, 21),
        ticks: [
          (offsetMs: 0, tick: heartbeat(rootMac)),
          (
            offsetMs: 180,
            tick: const SafrTrafficTick(
              mac: leafMac,
              direction: SafrTrafficDirection.downlink,
              severity: 0,
              ack: true,
              msgType: SafrMsgType.ack,
            ),
          ),
          (
            offsetMs: 200,
            tick: const SafrTrafficTick(
              mac: leafMac,
              direction: SafrTrafficDirection.uplink,
              severity: 3,
              msgType: SafrMsgType.event,
              eventCode: SafrEventCode.smokeAlarm,
            ),
          ),
        ],
      ))!;

      expect(decoded.seq, 12);
      expect(decoded.ticks.map((t) => t.offsetMs), [0, 180, 200]);
      final hb = decoded.ticks[0].tick;
      expect(hb.mac, rootMac);
      expect(hb.direction, SafrTrafficDirection.uplink);
      expect(hb.parentMac, boardMac);
      expect(hb.msgType, SafrMsgType.heartbeat);
      expect(hb.uptimeS, 5310);
      expect(hb.ack, isFalse);
      final ack = decoded.ticks[1].tick;
      expect(ack.direction, SafrTrafficDirection.downlink);
      expect(ack.ack, isTrue);
      expect(ack.msgType, SafrMsgType.ack);
      expect(ack.parentMac, isNull);
      final alarm = decoded.ticks[2].tick;
      expect(alarm.severity, 3);
      expect(alarm.eventCode, SafrEventCode.smokeAlarm);
    });

    test('the alarm list and the watch ping come back', () {
      final alarms = decodeMirrorAlarms(encodeMirrorAlarms(
        at: DateTime.utc(2026, 10, 3, 21),
        alarms: [
          MirrorAlarm(
            mac: leafMac,
            name: 'Hall',
            zone: 'Térreo',
            since: DateTime.utc(2026, 10, 3, 20, 59),
          ),
        ],
      ))!;
      expect(alarms.at, DateTime.utc(2026, 10, 3, 21));
      expect(alarms.alarms.single.mac, leafMac);
      expect(alarms.alarms.single.name, 'Hall');
      expect(alarms.alarms.single.zone, 'Térreo');
      expect(alarms.alarms.single.since, DateTime.utc(2026, 10, 3, 20, 59));

      expect(decodeMirrorWatch(encodeMirrorWatch())!.hello, isFalse);
      expect(decodeMirrorWatch(encodeMirrorWatch(hello: true))!.hello, isTrue);
      expect(decodeMirrorWatch('{"type":"other"}'), isNull);
      expect(decodeMirrorWatch('not json'), isNull);
    });

    test('the identify command and a batch\'s events come back', () {
      final cmd = decodeMirrorIdentify(
          encodeMirrorIdentify(rootMac, sub: 'sub-ana', name: 'ana@x.com'))!;
      expect(cmd.mac, rootMac);
      expect(cmd.sub, 'sub-ana');
      expect(cmd.name, 'ana@x.com');
      expect(decodeMirrorIdentify(encodeMirrorWatch()), isNull);
      expect(decodeMirrorWatch(encodeMirrorIdentify(rootMac)), isNull);

      final frames = decodeMirrorFrames(encodeMirrorFrames(
        seq: 1,
        t0: DateTime.utc(2026, 10, 3, 21),
        ticks: const [],
        events: const [
          (kind: MirrorEventKind.identify, mac: rootMac, arg: 10, text: null),
          (kind: MirrorEventKind.identifyFailed, mac: leafMac, arg: 0, text: null),
        ],
      ))!;
      expect(frames.ticks, isEmpty);
      expect(frames.events, const [
        (kind: MirrorEventKind.identify, mac: rootMac, arg: 10, text: null),
        (kind: MirrorEventKind.identifyFailed, mac: leafMac, arg: 0, text: null),
      ]);
      // A batch without events says nothing about them.
      expect(
          decodeMirrorFrames(encodeMirrorFrames(
                  seq: 2, t0: DateTime.utc(2026), ticks: const []))!
              .events,
          isEmpty);
    });

    test('anything else is refused, not guessed', () {
      expect(decodeMirrorState('{"v":2,"units":[]}'), isNull);
      expect(decodeMirrorState('nonsense'), isNull);
      expect(decodeMirrorFrames('{"v":1}'), isNull);
      expect(decodeMirrorAlarms('{"v":1,"alarms":[]}'), isNull); // no time
    });

    test('last seen and dBm do not change what a snapshot says', () {
      final a = [node(rootMac, SafrNodeRole.root, 1)];
      final b = [
        node(rootMac, SafrNodeRole.root, 1,
            rssi: -75, lastSeen: DateTime.utc(2026, 10, 3, 22)),
      ];
      final c = [node(rootMac, SafrNodeRole.root, 1, online: false)];
      expect(mirrorStateSignature('connected', a),
          mirrorStateSignature('connected', b));
      expect(mirrorStateSignature('connected', a),
          isNot(mirrorStateSignature('connected', c)));
      expect(mirrorStateSignature('connected', a),
          isNot(mirrorStateSignature('stalled', a)));
    });
  });

  group('central — publisher', () {
    late DateTime now;
    late List<TopologyNode> nodes;
    late String link;
    late bool mqttUp;
    late List<({String topic, String payload, bool retain, int qos})> sent;
    late List<List<String?>> watcherNotices;
    late DeviceUpdateRun? run;
    late OtaPushState push;
    late int historyReads;
    late List<({String mac, int seconds, String by})> identifySent;
    late bool rootAcks;
    late CentralMirrorPublisher publisher;

    void advance(Duration d) => now = now.add(d);
    Iterable<String> on(String topic) =>
        sent.where((m) => m.topic == topic).map((m) => m.payload);
    List<MirrorEvent> eventsSent() => [
          for (final p in on(mirrorFramesTopic(id)))
            ...decodeMirrorFrames(p)!.events,
        ];

    setUp(() {
      now = DateTime.utc(2026, 10, 3, 21);
      nodes = [
        node(boardMac, SafrNodeRole.root, 0),
        node(rootMac, SafrNodeRole.root, 1),
      ];
      link = 'connected';
      mqttUp = true;
      sent = [];
      watcherNotices = [];
      run = null;
      push = const OtaPushState();
      historyReads = 0;
      identifySent = [];
      rootAcks = true;
      publisher = CentralMirrorPublisher(
        identify: (mac, seconds, by) async {
          identifySent.add((mac: mac, seconds: seconds, by: by));
          // What the tablet does on the root's ACK: the blink starts.
          if (rootAcks) publisher.onIdentify(mac, seconds);
          return rootAcks;
        },
        ota: () => (run: run, push: push),
        otaHistory: () async {
          historyReads++;
          return [historyRun];
        },
        onWatchers: (w) => watcherNotices.add([for (final x in w) x.name]),
        identityId: () => id,
        publish: (topic, payload, {retain = false, qos = 1}) {
          if (!mqttUp) return false;
          sent.add((topic: topic, payload: payload, retain: retain, qos: qos));
          return true;
        },
        nodes: () => nodes,
        link: () => link,
        clock: () => now,
      );
    });

    test('with nobody watching, nothing of the map leaves the central', () {
      publisher.onMapChanged();
      publisher.onTick(heartbeat(rootMac));
      for (var i = 0; i < 40; i++) {
        advance(CentralMirrorPublisher.pumpEvery);
        publisher.pump();
      }
      expect(sent, isEmpty);
      expect(publisher.watched, isFalse);
    });

    test('a watch ping opens the stream: the snapshot, then the frames', () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      expect(publisher.watched, isTrue);
      publisher.onTick(heartbeat(rootMac));
      advance(const Duration(milliseconds: 120));
      publisher.onTick(heartbeat(boardMac));
      publisher.pump();

      final state = decodeMirrorState(on(mirrorStateTopic(id)).single)!;
      expect(state.nodes.map((n) => n.mac), [boardMac, rootMac]);
      expect(state.link, 'connected');
      final frames = decodeMirrorFrames(on(mirrorFramesTopic(id)).single)!;
      expect(frames.seq, 1);
      expect(frames.ticks.map((t) => t.tick.mac), [rootMac, boardMac]);
      expect(frames.ticks.map((t) => t.offsetMs), [0, 120]);
      // Never retained: a snapshot left on the broker would be read as
      // live by the next phone.
      expect(sent.every((m) => !m.retain), isTrue);

      // Nothing moved: nothing sent.
      sent.clear();
      advance(CentralMirrorPublisher.pumpEvery);
      publisher.pump();
      expect(sent, isEmpty);
    });

    test('the first ping opens the stream even without hello', () {
      publisher.onCommand(encodeMirrorWatch());
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(1));
    });

    test('the stream closes 75 s after the last ping', () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      sent.clear();

      advance(const Duration(seconds: 74));
      publisher.onTick(heartbeat(rootMac));
      publisher.pump();
      expect(on(mirrorFramesTopic(id)), hasLength(1));

      sent.clear();
      advance(const Duration(seconds: 2));
      expect(publisher.watched, isFalse);
      publisher.onTick(heartbeat(rootMac));
      publisher.onMapChanged();
      publisher.pump();
      expect(sent, isEmpty);

      // A ping in time keeps it open.
      publisher.onCommand(encodeMirrorWatch());
      advance(const Duration(seconds: 60));
      publisher.onCommand(encodeMirrorWatch());
      advance(const Duration(seconds: 60));
      expect(publisher.watched, isTrue);
    });

    test('a second phone\'s hello brings the snapshot again, one a second',
        () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(1));

      publisher.onCommand(encodeMirrorWatch(hello: true));
      advance(const Duration(milliseconds: 250));
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(1)); // too soon

      advance(const Duration(seconds: 1));
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(2));

      // A plain ping asks for nothing.
      publisher.onCommand(encodeMirrorWatch());
      advance(const Duration(seconds: 5));
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(2));
    });

    test('a change of the map is sent; a heartbeat\'s dBm waits 30 s', () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(1));

      // Only what every heartbeat changes.
      nodes = [
        node(boardMac, SafrNodeRole.root, 0),
        node(rootMac, SafrNodeRole.root, 1,
            rssi: -72, lastSeen: now.add(const Duration(seconds: 15))),
      ];
      publisher.onMapChanged();
      advance(const Duration(seconds: 5));
      publisher.onCommand(encodeMirrorWatch());
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(1));

      advance(const Duration(seconds: 26));
      publisher.onCommand(encodeMirrorWatch());
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(2));
      expect(
          decodeMirrorState(on(mirrorStateTopic(id)).last)!.nodes[1].rssi, -72);

      // A unit goes missing: sent at once.
      nodes = [
        node(boardMac, SafrNodeRole.root, 0),
        node(rootMac, SafrNodeRole.root, 1, online: false),
      ];
      publisher.onMapChanged();
      advance(const Duration(seconds: 2));
      publisher.pump();
      expect(on(mirrorStateTopic(id)), hasLength(3));

      // The board link too.
      link = 'stalled';
      publisher.onMapChanged();
      advance(const Duration(seconds: 2));
      publisher.pump();
      expect(decodeMirrorState(on(mirrorStateTopic(id)).last)!.link, 'stalled');
    });

    test('a full batch leaves at once, numbered in order', () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      for (var i = 0; i < CentralMirrorPublisher.maxTicksPerBatch + 3; i++) {
        publisher.onTick(heartbeat(rootMac));
      }
      expect(on(mirrorFramesTopic(id)), hasLength(1));
      publisher.pump();
      final batches =
          on(mirrorFramesTopic(id)).map((p) => decodeMirrorFrames(p)!).toList();
      expect(batches.map((b) => b.seq), [1, 2]);
      expect(batches.map((b) => b.ticks.length),
          [CentralMirrorPublisher.maxTicksPerBatch, 3]);
      expect(sent.where((m) => m.topic == mirrorFramesTopic(id)).first.qos, 0);
    });

    test('alarms are sent with nobody watching, retained, once per change',
        () {
      final alarm = MirrorAlarm(
          mac: leafMac, name: 'Hall', since: DateTime.utc(2026, 10, 3, 21));
      publisher.onAlarms(const []);
      publisher.onAlarms([alarm]);
      publisher.onAlarms([alarm]); // the registry moved, the alarms did not
      publisher.onAlarms(const []); // RESET

      final msgs = sent.where((m) => m.topic == mirrorAlarmTopic(id)).toList();
      expect(msgs, hasLength(3));
      expect(msgs.every((m) => m.retain && m.qos == 1), isTrue);
      expect(decodeMirrorAlarms(msgs[0].payload)!.alarms, isEmpty);
      expect(decodeMirrorAlarms(msgs[1].payload)!.alarms.single.mac, leafMac);
      // The reset replaces the retained list with an empty one.
      expect(decodeMirrorAlarms(msgs[2].payload)!.alarms, isEmpty);
      expect(publisher.watched, isFalse);
    });

    test('an alarm raised with MQTT down is written when the session is back',
        () {
      mqttUp = false;
      publisher.onAlarms([const MirrorAlarm(mac: leafMac)]);
      expect(sent, isEmpty);

      mqttUp = true;
      publisher.onConnected();
      expect(decodeMirrorAlarms(on(mirrorAlarmTopic(id)).single)!.alarms.single.mac,
          leafMac);

      // Every new session writes the retained list again: it is what a
      // phone opening the app later will read.
      publisher.onConnected();
      expect(on(mirrorAlarmTopic(id)), hasLength(2));
    });

    test('the update is sent on hello and when it changes, not every second',
        () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      // No update on the tablet: the phone is told so.
      expect(decodeMirrorOta(on(mirrorOtaTopic(id)).single)!.run, isNull);

      for (var i = 0; i < 10; i++) {
        advance(const Duration(seconds: 1));
        publisher.pump();
      }
      expect(on(mirrorOtaTopic(id)), hasLength(1));

      run = updateRun(percent: 10);
      push = pushing;
      advance(const Duration(seconds: 1));
      publisher.pump();
      final sentRun = decodeMirrorOta(on(mirrorOtaTopic(id)).last)!;
      expect(sentRun.run!.units[rootMac]!.percent, 10);
      expect(sentRun.push!.chunksDone, 30);
      expect(sentRun.seq, 2);

      // The percent moves several times inside a second: one message.
      run = updateRun(percent: 11);
      advance(const Duration(milliseconds: 250));
      publisher.pump();
      run = updateRun(percent: 12);
      advance(const Duration(milliseconds: 250));
      publisher.pump();
      expect(on(mirrorOtaTopic(id)), hasLength(2));
      advance(const Duration(milliseconds: 600));
      publisher.pump();
      expect(on(mirrorOtaTopic(id)), hasLength(3));
      expect(
          decodeMirrorOta(on(mirrorOtaTopic(id)).last)!
              .run!
              .units[rootMac]!
              .percent,
          12);
      expect(
          sent.where((m) => m.topic == mirrorOtaTopic(id)).every((m) => !m.retain),
          isTrue);
    });

    test('with nobody watching the update is not even read', () {
      var reads = 0;
      final quiet = CentralMirrorPublisher(
        identityId: () => id,
        publish: (topic, payload, {retain = false, qos = 1}) => true,
        nodes: () => nodes,
        link: () => link,
        ota: () {
          reads++;
          return (run: null, push: null);
        },
        clock: () => now,
      );
      for (var i = 0; i < 20; i++) {
        advance(const Duration(seconds: 1));
        quiet.pump();
      }
      expect(reads, 0);
    });

    test('the history is sent when a phone asks, and only while watched',
        () async {
      publisher.onCommand(encodeMirrorOtaHistoryRequest());
      await pumpEventQueue();
      expect(historyReads, 0);
      expect(on(mirrorOtaHistoryTopic(id)), isEmpty);

      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.onCommand(encodeMirrorOtaHistoryRequest());
      await pumpEventQueue();
      expect(historyReads, 1);
      final runs = decodeMirrorOtaHistory(on(mirrorOtaHistoryTopic(id)).single)!;
      expect(runs.single.$1.runId, 'aaaa');
    });

    test('Identificar from a watching phone: sent, and the blink goes back',
        () async {
      publisher.onCommand(
          encodeMirrorWatch(hello: true, sub: 'sub-ana', name: 'ana@x.com'));
      publisher.pump();
      sent.clear();

      publisher.onCommand(
          encodeMirrorIdentify(rootMac, sub: 'sub-ana', name: 'ana@x.com'));
      await pumpEventQueue();
      expect(identifySent, [
        (
          mac: rootMac,
          seconds: CentralMirrorPublisher.identifySeconds,
          by: 'ana@x.com',
        ),
      ]);

      advance(CentralMirrorPublisher.pumpEvery);
      publisher.pump();
      expect(eventsSent(), [
        // "heard you", so the phone knows the central is answering …
        (kind: MirrorEventKind.identifySending, mac: rootMac, arg: 0, text: null),
        // … then the blink itself, on the root's confirmation.
        (
          kind: MirrorEventKind.identify,
          mac: rootMac,
          arg: CentralMirrorPublisher.identifySeconds,
          text: null,
        ),
      ]);
      // An event is not repeated by a later batch: it is acknowledged.
      expect(sent.where((m) => m.topic == mirrorFramesTopic(id)).single.qos, 1);
    });

    test('Identificar on the tablet itself blinks on the phones too', () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      sent.clear();

      publisher.onIdentify(rootMac, 10); // the tablet's menu, confirmed
      advance(CentralMirrorPublisher.pumpEvery);
      publisher.pump();
      expect(eventsSent().single,
          (kind: MirrorEventKind.identify, mac: rootMac, arg: 10, text: null));
      expect(identifySent, isEmpty);
    });

    test('Identificar without the root\'s confirmation says so', () async {
      rootAcks = false;
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      sent.clear();

      publisher.onCommand(encodeMirrorIdentify(rootMac));
      await pumpEventQueue();
      advance(CentralMirrorPublisher.pumpEvery);
      publisher.pump();
      expect(eventsSent().map((e) => e.kind), [
        MirrorEventKind.identifySending,
        MirrorEventKind.identifyFailed,
      ]);
    });

    test('Identificar is refused for what the tablet would not offer',
        () async {
      // Nobody watching: a command out of nowhere is ignored.
      publisher.onCommand(encodeMirrorIdentify(rootMac));
      await pumpEventQueue();
      expect(identifySent, isEmpty);
      publisher.onIdentify(rootMac, 10);
      publisher.pump();
      expect(sent, isEmpty);

      nodes = [
        node(boardMac, SafrNodeRole.root, 0),
        node(rootMac, SafrNodeRole.root, 1, online: false),
        node(leafMac, SafrNodeRole.leaf, 2),
      ];
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      sent.clear();

      // A unit without communication, a battery detector, an unknown MAC.
      for (final mac in [rootMac, leafMac, 'EE:00:00:00:00:09']) {
        publisher.onCommand(encodeMirrorIdentify(mac));
      }
      await pumpEventQueue();
      expect(identifySent, isEmpty);
      advance(CentralMirrorPublisher.pumpEvery);
      publisher.pump();
      // Each one is answered, and each answer is "no".
      expect(eventsSent().map((e) => e.kind), [
        for (var i = 0; i < 3; i++) ...[
          MirrorEventKind.identifySending,
          MirrorEventKind.identifyFailed,
        ],
      ]);
    });

    test('the tablet knows who is watching, and when each one leaves', () {
      publisher.onCommand(
          encodeMirrorWatch(hello: true, sub: 'sub-ana', name: 'ana@x.com'));
      advance(const Duration(seconds: 10));
      publisher.onCommand(
          encodeMirrorWatch(hello: true, sub: 'sub-bia', name: 'bia@x.com'));

      expect(publisher.watchers.map((w) => w.name), ['ana@x.com', 'bia@x.com']);
      expect(publisher.watchers.map((w) => w.sub), ['sub-ana', 'sub-bia']);
      expect(publisher.watchers.first.since, DateTime.utc(2026, 10, 3, 21));

      // Ana keeps pinging, Bia closed the app.
      advance(const Duration(seconds: 30));
      publisher.onCommand(encodeMirrorWatch(sub: 'sub-ana', name: 'ana@x.com'));
      advance(const Duration(seconds: 50));
      publisher.pump();
      expect(publisher.watchers.map((w) => w.name), ['ana@x.com']);
      expect(publisher.watched, isTrue);
      // Since when she watches does not move with every ping.
      expect(publisher.watchers.single.since, DateTime.utc(2026, 10, 3, 21));

      advance(const Duration(seconds: 80));
      publisher.pump();
      expect(publisher.watchers, isEmpty);
      expect(publisher.watched, isFalse);

      // Told once per arrival and per departure, not per ping.
      expect(watcherNotices, [
        ['ana@x.com'],
        ['ana@x.com', 'bia@x.com'],
        ['ana@x.com'],
        <String?>[],
      ]);
    });

    test('a phone that says it left is dropped at once', () {
      publisher.onCommand(
          encodeMirrorWatch(hello: true, sub: 'sub-ana', name: 'ana@x.com'));
      publisher.onCommand(
          encodeMirrorWatch(hello: true, sub: 'sub-bia', name: 'bia@x.com'));
      publisher.pump();

      // Ana leaves the central: Bia still watches, the stream goes on.
      publisher.onCommand(encodeMirrorUnwatch(sub: 'sub-ana', name: 'ana@x.com'));
      expect(publisher.watchers.map((w) => w.name), ['bia@x.com']);
      expect(publisher.watched, isTrue);

      // Bia leaves too: nothing more is sent, with no 75 s of waiting.
      publisher.onCommand(encodeMirrorUnwatch(sub: 'sub-bia'));
      expect(publisher.watchers, isEmpty);
      expect(publisher.watched, isFalse);
      sent.clear();
      publisher.onTick(heartbeat(rootMac));
      publisher.onMapChanged();
      advance(const Duration(seconds: 2));
      publisher.pump();
      expect(sent, isEmpty);

      expect(watcherNotices.last, isEmpty);
      // Someone who was never watching leaving changes nothing.
      final notices = watcherNotices.length;
      publisher.onCommand(encodeMirrorUnwatch(sub: 'sub-zed'));
      expect(watcherNotices, hasLength(notices));
    });

    test('a new MQTT session forgets who was watching', () {
      publisher.onCommand(encodeMirrorWatch(hello: true));
      publisher.pump();
      publisher.onConnected();
      expect(publisher.watched, isFalse);
    });
  });

  group('phone — viewer', () {
    late FakeMqttRepo repo;
    late SafrTrafficBus bus;
    late List<SafrTrafficTick> played;
    late List<({String mac, int seconds})> blinks;
    late DateTime now;
    late CentralMirrorViewer viewer;
    late StreamSubscription<SafrTrafficTick> busSub;

    Iterable<String> pings() =>
        repo.published.where((m) => m.topic == id).map((m) => m.payload);

    setUp(() {
      now = DateTime.utc(2026, 10, 3, 21);
      repo = FakeMqttRepo();
      bus = SafrTrafficBus();
      played = [];
      blinks = [];
      busSub = bus.stream.listen(played.add);
      viewer = CentralMirrorViewer(
        centralId: id,
        repo: repo,
        traffic: bus,
        accountName: () => 'ana@x.com',
        onIdentify: (mac, seconds) => blinks.add((mac: mac, seconds: seconds)),
        clock: () => now,
      );
    });

    tearDown(() async {
      if (viewer.mounted) viewer.dispose();
      await busSub.cancel();
      bus.dispose();
    });

    String snapshot({bool online = true}) => encodeMirrorState(
          seq: 1,
          at: now,
          link: 'connected',
          nodes: [
            node(boardMac, SafrNodeRole.root, 0),
            node(rootMac, SafrNodeRole.root, 1,
                online: online, lastSeen: DateTime.utc(2026, 10, 3, 20)),
          ],
        );

    test('opening a central subscribes and says hello', () {
      viewer.onConnected();
      expect(repo.subscribed, [
        mirrorStateTopic(id),
        mirrorFramesTopic(id),
        mirrorOtaTopic(id),
        mirrorOtaHistoryTopic(id),
      ]);
      final ping = decodeMirrorWatch(pings().single)!;
      expect(ping.hello, isTrue);
      // Who is watching, for the eye on the tablet.
      expect(ping.sub, 'user');
      expect(ping.name, 'ana@x.com');
    });

    test('the picture is live only with a snapshot and the central online',
        () async {
      viewer.onConnected();
      expect(viewer.state.live, isFalse);

      repo.deliver(mirrorStateTopic(id), snapshot());
      await pumpEventQueue();
      expect(viewer.state.nodes, hasLength(2));
      expect(viewer.state.live, isFalse); // the central's presence unknown

      viewer.setCentralOnline(true);
      expect(viewer.state.live, isTrue);
      expect(viewer.state.linkUp, isTrue);

      viewer.setCentralOnline(false);
      expect(viewer.state.live, isFalse);
      expect(viewer.state.linkUp, isFalse);

      viewer.setCentralOnline(true);
      viewer.onDisconnected(); // this phone lost the cloud
      expect(viewer.state.live, isFalse);
    });

    test('the central coming back online gets a hello at once', () {
      viewer.onConnected();
      viewer.setCentralOnline(true);
      expect(pings().map((p) => decodeMirrorWatch(p)!.hello), [true, true]);
    });

    test('frames are replayed into the app\'s own traffic bus', () async {
      viewer.onConnected();
      viewer.setCentralOnline(true);
      repo.deliver(mirrorStateTopic(id), snapshot());
      await pumpEventQueue();

      now = now.add(const Duration(seconds: 30));
      repo.deliver(
        mirrorFramesTopic(id),
        encodeMirrorFrames(
          seq: 1,
          t0: now,
          ticks: [(offsetMs: 0, tick: heartbeat(rootMac))],
        ),
      );
      await pumpEventQueue();

      expect(played.single.mac, rootMac);
      expect(played.single.msgType, SafrMsgType.heartbeat);
      // A frame from a unit is the unit heard now.
      final root = viewer.state.nodes.firstWhere((n) => n.mac == rootMac);
      expect(root.lastSeenAt, now);
    });

    testWidgets('ticks keep their spacing inside a batch', (tester) async {
      viewer.onConnected();
      repo.deliver(
        mirrorFramesTopic(id),
        encodeMirrorFrames(
          seq: 1,
          t0: now,
          ticks: [
            (offsetMs: 0, tick: heartbeat(rootMac)),
            (offsetMs: 200, tick: heartbeat(boardMac)),
          ],
        ),
      );
      await tester.pump();
      expect(played.map((t) => t.mac), [rootMac]);
      await tester.pump(const Duration(milliseconds: 199));
      expect(played, hasLength(1));
      await tester.pump(const Duration(milliseconds: 2));
      expect(played.map((t) => t.mac), [rootMac, boardMac]);
      viewer.dispose();
    });

    test('a missing batch asks for the snapshot again', () async {
      viewer.onConnected();
      String batch(int seq) => encodeMirrorFrames(
          seq: seq, t0: now, ticks: [(offsetMs: 0, tick: heartbeat(rootMac))]);

      now = now.add(const Duration(seconds: 10));
      repo.deliver(mirrorFramesTopic(id), batch(4));
      repo.deliver(mirrorFramesTopic(id), batch(5));
      await pumpEventQueue();
      expect(pings(), hasLength(1)); // in order: nothing asked

      repo.deliver(mirrorFramesTopic(id), batch(7));
      await pumpEventQueue();
      expect(pings().map((p) => decodeMirrorWatch(p)!.hello), [true, true]);
    });

    testWidgets('pings every 30 s, and not from the background',
        (tester) async {
      viewer.onConnected();
      expect(pings(), hasLength(1));
      await tester.pump(const Duration(seconds: 61));
      expect(pings(), hasLength(3));
      expect(decodeMirrorWatch(pings().last)!.hello, isFalse);

      viewer.setForeground(false); // says it left, then silence
      expect(pings(), hasLength(4));
      await tester.pump(const Duration(seconds: 120));
      expect(pings(), hasLength(4));

      viewer.setForeground(true);
      expect(pings(), hasLength(5));
      expect(decodeMirrorWatch(pings().last)!.hello, isTrue);
      viewer.dispose();
    });

    String events(int seq, List<MirrorEvent> events) => encodeMirrorFrames(
        seq: seq, t0: now, ticks: const [], events: events);

    test('Identificar: asked to the central, confirmed by its blink event',
        () async {
      viewer.onConnected();
      final outcome = viewer.sendIdentify(rootMac);
      final cmd = decodeMirrorIdentify(pings().last)!;
      expect(cmd.mac, rootMac);
      expect(cmd.sub, 'user');
      expect(cmd.name, 'ana@x.com');
      expect(blinks, isEmpty); // not before the root confirms

      repo.deliver(mirrorFramesTopic(id), events(1, const [
        (kind: MirrorEventKind.identify, mac: rootMac, arg: 10, text: null),
      ]));
      expect(await outcome, MirrorIdentifyOutcome.confirmed);
      expect(blinks, [(mac: rootMac, seconds: 10)]);
    });

    test('an Identificar started on the tablet blinks here too', () async {
      viewer.onConnected();
      repo.deliver(mirrorFramesTopic(id), events(1, const [
        (kind: MirrorEventKind.identify, mac: rootMac, arg: 10, text: null),
      ]));
      await pumpEventQueue();
      expect(blinks, [(mac: rootMac, seconds: 10)]);
    });

    test('Identificar the central could not confirm', () async {
      viewer.onConnected();
      final outcome = viewer.sendIdentify(rootMac);
      repo.deliver(mirrorFramesTopic(id), events(1, const [
        (kind: MirrorEventKind.identifyFailed, mac: rootMac, arg: 0, text: null),
      ]));
      expect(await outcome, MirrorIdentifyOutcome.notConfirmed);
      expect(blinks, isEmpty);
    });

    testWidgets('Identificar a central never answered: said so in 6 s',
        (tester) async {
      // A central off line, or one whose app does not know the request.
      viewer.onConnected();
      MirrorIdentifyOutcome? result;
      viewer.sendIdentify(rootMac).then((o) => result = o);
      await tester.pump(const Duration(seconds: 5));
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(result, MirrorIdentifyOutcome.noAnswer);
      viewer.dispose();
    });

    testWidgets('Identificar the central took but the root never confirmed',
        (tester) async {
      viewer.onConnected();
      MirrorIdentifyOutcome? result;
      viewer.sendIdentify(rootMac).then((o) => result = o);
      repo.deliver(mirrorFramesTopic(id), events(1, const [
        (kind: MirrorEventKind.identifySending, mac: rootMac, arg: 0, text: null),
      ]));
      await tester.pump(const Duration(seconds: 14));
      expect(result, isNull); // heard: the short wait no longer applies
      await tester.pump(const Duration(seconds: 2));
      expect(result, MirrorIdentifyOutcome.notConfirmed);
      viewer.dispose();
    });

    test('leaving the central unsubscribes from its stream', () {
      viewer.onConnected();
      viewer.dispose();
      expect(repo.unsubscribed, [
        mirrorStateTopic(id),
        mirrorFramesTopic(id),
        mirrorOtaTopic(id),
        mirrorOtaHistoryTopic(id),
      ]);
      // And says so, so the central stops streaming now, not at its timeout.
      final bye = decodeMirrorUnwatch(pings().last)!;
      expect(bye.sub, 'user');
      expect(bye.name, 'ana@x.com');
    });

    testWidgets('the background says it left; the foreground says hello',
        (tester) async {
      viewer.onConnected();
      viewer.setForeground(false);
      expect(decodeMirrorUnwatch(pings().last), isNotNull);
      final count = pings().length;
      await tester.pump(const Duration(seconds: 90));
      expect(pings(), hasLength(count));

      viewer.setForeground(true);
      expect(decodeMirrorWatch(pings().last)!.hello, isTrue);
      viewer.dispose();
      await tester.pump();
    });

    test('opening a central starts the watch at once; leaving it ends it',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final container = ProviderContainer(overrides: [
        iotMqttRepositoryProvider.overrideWithValue(repo),
        iotConnectionProvider.overrideWith(_Connected.new),
        authNotifierProvider.overrideWith(_SignedIn.new),
        safrTrafficProvider.overrideWithValue(bus),
      ]);
      addTearDown(container.dispose);
      // What MainScreen does for as long as the app runs in USER mode.
      final keep = container.listen(
          centralMirrorProvider.select((v) => v.connected), (_, __) {});
      addTearDown(keep.close);
      await container.read(authNotifierProvider.future); // signed in
      await pumpEventQueue();
      expect(pings(), isEmpty); // on the home page: nobody is watched

      // The user opens the central — no map screen has been built yet.
      container.read(viewedCentralProvider.notifier).state = id;
      await pumpEventQueue();
      final hello = decodeMirrorWatch(pings().single)!;
      expect(hello.hello, isTrue);
      expect(hello.name, 'ana@x.com');
      expect(repo.subscribed, contains(mirrorFramesTopic(id)));

      // Back to the home page.
      container.read(viewedCentralProvider.notifier).state = null;
      await pumpEventQueue();
      expect(decodeMirrorUnwatch(pings().last), isNotNull);
      expect(repo.unsubscribed, contains(mirrorFramesTopic(id)));
      // The alarm list is not part of the watch: it stays subscribed, so
      // the home page keeps hearing of alarms.
      expect(repo.unsubscribed, isNot(contains(mirrorAlarmTopic(id))));
    });

    test('the update on the tablet is the update on the phone, view only',
        () async {
      final container = ProviderContainer(overrides: [
        centralMirrorProvider.overrideWith((ref) => viewer),
      ]);
      addTearDown(container.dispose);
      container.read(viewedCentralProvider.notifier).state = id;
      viewer.onConnected();
      viewer.setCentralOnline(true);

      expect(container.read(deviceUpdateRunProvider), isNull);
      expect(container.read(otaPushViewProvider).running, isFalse);

      repo.deliver(mirrorOtaTopic(id),
          encodeMirrorOta(seq: 1, run: updateRun(), push: pushing));
      await pumpEventQueue();

      final run = container.read(deviceUpdateRunProvider)!;
      expect(run.units[rootMac]!.state, SafrOtaUnitState.downloading);
      expect(run.pausedBy, OtaPauseCause.alarm);
      expect(container.read(otaPushViewProvider).progress, 0.25);
      // The board's rollout table is not mirrored, and nothing of this
      // phone's own update machinery was started to answer.
      expect(container.read(otaRolloutViewProvider).families, isEmpty);
      expect(container.exists(deviceUpdateProvider), isFalse);

      // The tablet dismissed the run.
      repo.deliver(
          mirrorOtaTopic(id), encodeMirrorOta(seq: 2, run: null, push: null));
      await pumpEventQueue();
      expect(container.read(deviceUpdateRunProvider), isNull);
      expect(container.read(otaPushViewProvider).phase, OtaPushPhase.idle);
    });

    test('the history is asked for, and read from what the central sent',
        () async {
      final container = ProviderContainer(overrides: [
        centralMirrorProvider.overrideWith((ref) => viewer),
      ]);
      addTearDown(container.dispose);
      container.read(viewedCentralProvider.notifier).state = id;
      viewer.onConnected();

      viewer.requestOtaHistory();
      expect(isMirrorOtaHistoryRequest(pings().last), isTrue);
      expect(
          await container.read(deviceUpdateHistoryProvider).recent(), isEmpty);

      repo.deliver(
          mirrorOtaHistoryTopic(id), encodeMirrorOtaHistory([historyRun]));
      await pumpEventQueue();

      final history = container.read(deviceUpdateHistoryProvider);
      expect((await history.recent()).single.$1.runId, 'aaaa');
      final ofLeaf = await history.ofUnit(leafMac);
      expect(ofLeaf.single.$2.state, 'failed');
      expect(await history.ofUnit('00:00:00:00:00:00'), isEmpty);
    });

    test('the map shows the viewed central, and no unit alive when not live',
        () async {
      final container = ProviderContainer(overrides: [
        centralMirrorProvider.overrideWith((ref) => viewer),
      ]);
      addTearDown(container.dispose);
      container.read(viewedCentralProvider.notifier).state = id;

      viewer.onConnected();
      viewer.setCentralOnline(true);
      repo.deliver(mirrorStateTopic(id), snapshot());
      await pumpEventQueue();

      expect(container.read(mirrorViewOnlyProvider), isTrue);
      var map = container.read(topologyProvider);
      expect(map.map((n) => n.mac), [boardMac, rootMac]);
      expect(map.every((n) => n.online), isTrue);

      viewer.setCentralOnline(false);
      map = container.read(topologyProvider);
      expect(map, hasLength(2)); // still drawn
      expect(map.any((n) => n.online || n.heard), isFalse);
    });
  });
}

class _Connected extends IotConnectionNotifier {
  @override
  Future<bool> build() async => true;
}

class _SignedIn extends AuthNotifier {
  @override
  Future<AuthUserEntity?> build() async =>
      const AuthUserEntity(userId: 'ana@x.com');
}
