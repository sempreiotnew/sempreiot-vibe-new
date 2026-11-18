import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// Protocol v3.6 (2026-10-26): the downlink loss a node counts on the board's
/// heartbeats (§7.3 DL_HEARD) — a reading the central keeps and shows; the
/// "enlace fraco" flag and its trouble left the app on 2026-11-18.
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

  test('the mirror carries the count', () {
    final json = encodeMirrorState(
      seq: 1,
      at: t0,
      link: 'connected',
      nodes: [
        TopologyNode(
          mac: unit,
          role: SafrNodeRole.node,
          layer: 2,
          parentMac: parent,
          rssi: -88,
          batteryPct: null,
          online: true,
          lastSeenAt: t0,
          alarmLatched: false,
          dlHeard: 4,
        ),
      ],
    );
    expect(decodeMirrorState(json)!.nodes.single.dlHeard, 4);
  });
}
