import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/application/supervision_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// Protocol v3.6 (2026-10-26): the downlink loss a node counts on the board's
/// heartbeats (§7.3 DL_HEARD) and what the central does with it (§9.4).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const unit = '5A:46:52:00:00:07';
  const parent = '5A:46:52:00:00:01';
  final t0 = DateTime.utc(2026, 10, 26, 15);

  Uint8List heartbeat(
      {int layer = 2, int rssi = -90, int? dlHeard, int? dlMap}) {
    final p = Uint8List(dlHeard == null ? 20 : (dlMap == null ? 21 : 22));
    p[12] = rssi & 0xFF;
    final mac = safrMacToBytes(parent);
    p.setRange(13, 19, mac);
    p[19] = layer;
    if (dlHeard != null) p[20] = dlHeard;
    if (dlHeard != null && dlMap != null) p[21] = dlMap;
    return p;
  }

  group('SafrHeartbeatPayload.dlHeard', () {
    test('20 bytes: nothing said (a leaf, or older firmware)', () {
      expect(SafrHeartbeatPayload.parse(heartbeat())!.dlHeard, isNull);
    });
    test('21 bytes: the count, 0xFF = not 120 s on the link yet', () {
      expect(SafrHeartbeatPayload.parse(heartbeat(dlHeard: 5))!.dlHeard, 5);
      expect(SafrHeartbeatPayload.parse(heartbeat(dlHeard: 0))!.dlHeard, 0);
      expect(SafrHeartbeatPayload.parse(heartbeat(dlHeard: 0xFF))!.dlHeard,
          isNull);
      // A jittery board can never read as more than expected.
      expect(SafrHeartbeatPayload.parse(heartbeat(dlHeard: 9))!.dlHeard, 8);
    });
    test('22 bytes (v3.7): the map of which were heard, bit 0 the newest',
        () {
      final p = SafrHeartbeatPayload.parse(heartbeat(dlHeard: 7, dlMap: 0xFB))!;
      expect(p.dlMap, 0xFB);
      expect(SafrHeartbeatPayload.heardAt(p.dlMap!, 0), isTrue);
      expect(SafrHeartbeatPayload.heardAt(p.dlMap!, 2), isFalse);
      // No map without a count: 21 bytes, or a window not yet 120 s old.
      expect(SafrHeartbeatPayload.parse(heartbeat(dlHeard: 7))!.dlMap, isNull);
      expect(SafrHeartbeatPayload.parse(heartbeat(dlHeard: 0xFF, dlMap: 0xFB))!
              .dlMap,
          isNull);
    });
  });

  group('ingest writes it to the registry', () {
    late AppDatabase db;
    late SafrIngestService ingest;
    final enc = SafrEncoder(srcMac: safrMacToBytes(unit), bootCtr: 2);

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      ingest = SafrIngestService(db: db, onAckReceived: (_, __) {});
    });
    tearDown(() => db.close());

    Future<MeshDevice> row() =>
        (db.select(db.meshDevices)..where((t) => t.mac.equals(unit)))
            .getSingle();

    test('the last heartbeat rules: a count, then a silent one clears it',
        () async {
      await ingest.handleFrame(
          enc.encode(
              msgType: SafrMsgType.heartbeat, payload: heartbeat(dlHeard: 6)),
          deviceId: 't');
      expect((await row()).dlHeard, 6);
      expect((await row()).lastRssi, -90);
      await ingest.handleFrame(
          enc.encode(msgType: SafrMsgType.heartbeat, payload: heartbeat()),
          deviceId: 't');
      expect((await row()).dlHeard, isNull);
    });
  });

  group('supervision: the degraded-link trouble (§9.4)', () {
    late AppDatabase db;
    SupervisionNotifier? s;

    Future<void> device({int? dlHeard, int degraded = 0}) => db
        .into(db.meshDevices)
        .insertOnConflictUpdate(MeshDevicesCompanion.insert(
          mac: unit,
          role: Value(SafrNodeRole.node.wire),
          layer: const Value(2),
          firstSeenAt: t0.subtract(const Duration(days: 1)),
          lastSeenAt: t0,
          lastRssi: const Value(-90),
          dlHeard: Value(dlHeard),
          linkDegraded: Value(degraded),
        ));

    Future<List<String>> kinds() async => [
          for (final r in await db.select(db.deviceEvents).get())
            (r.detailJson.contains('link_degraded')
                ? 'link_degraded'
                : r.detailJson.contains('link_restored')
                    ? 'link_restored'
                    : 'other'),
        ];

    Future<int> flag() async =>
        (await (db.select(db.meshDevices)..where((t) => t.mac.equals(unit)))
                .getSingle())
            .linkDegraded;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() async {
      s?.dispose();
      s = null;
      await db.close();
    });

    test('nothing reported: nothing raised', () async {
      await device();
      s = SupervisionNotifier(db, clock: () => t0);
      await s!.evaluate();
      expect(await kinds(), isEmpty);
      expect(await flag(), 0);
    });

    test('7 of 8 is jitter, 6 of 8 is the trouble, 8 of 8 restores it',
        () async {
      await device(dlHeard: 7);
      s = SupervisionNotifier(db, clock: () => t0);
      await s!.evaluate();
      expect(await kinds(), isEmpty);

      await device(dlHeard: 6);
      await s!.evaluate();
      expect(await kinds(), ['link_degraded']);
      expect(await flag(), 1);
      expect(s!.state.single.online, isTrue,
          reason: 'online is the silence rule');

      // Still degraded at 7: the trouble is not raised twice, nor restored.
      await device(dlHeard: 7, degraded: 1);
      await s!.evaluate();
      expect(await kinds(), ['link_degraded']);

      await device(dlHeard: 8, degraded: 1);
      await s!.evaluate();
      expect(await kinds(), ['link_degraded', 'link_restored']);
      expect(await flag(), 0);
    });

    test('a window that restarted (no count) keeps the state as it is',
        () async {
      await device(dlHeard: null, degraded: 1);
      s = SupervisionNotifier(db, clock: () => t0);
      await s!.evaluate();
      expect(await kinds(), isEmpty);
      expect(await flag(), 1);
    });
  });

  group('TopologyNode', () {
    TopologyNode node({
      SafrNodeRole role = SafrNodeRole.node,
      int layer = 2,
      int? rssi,
      int? dlHeard,
      bool degraded = false,
    }) =>
        TopologyNode(
          mac: unit,
          role: role,
          layer: layer,
          parentMac: parent,
          rssi: rssi,
          batteryPct: null,
          online: true,
          lastSeenAt: t0,
          alarmLatched: false,
          dlHeard: dlHeard,
          linkDegraded: degraded,
        );

    test('weak link: a powered unit below −85 dBm, the root\'s hop too', () {
      expect(node(rssi: -84).weakPoweredLink, isFalse);
      expect(node(rssi: -86).weakPoweredLink, isTrue);
      expect(node(rssi: -86, layer: 1).weakPoweredLink, isTrue);
      expect(node(rssi: -86, role: SafrNodeRole.leaf).weakPoweredLink, isFalse,
          reason: 'a leaf has its own walk-test flag');
      expect(node(rssi: null).weakPoweredLink, isFalse);
    });

    test('lost = expected − heard; attention = weak or degraded', () {
      expect(node().dlLost, isNull);
      expect(node(dlHeard: 5).dlLost, 3);
      expect(node(rssi: -70).linkAttention, isFalse);
      expect(node(rssi: -70, degraded: true).linkAttention, isTrue);
      expect(node(rssi: -90).linkAttention, isTrue);
    });

    test('the mirror carries the count and the trouble', () {
      final json = encodeMirrorState(
        seq: 1,
        at: t0,
        link: 'connected',
        nodes: [node(rssi: -88, dlHeard: 4, degraded: true)],
      );
      final back = decodeMirrorState(json)!.nodes.single;
      expect(back.dlHeard, 4);
      expect(back.linkDegraded, isTrue);
      expect(back.linkAttention, isTrue);
    });
  });
}
