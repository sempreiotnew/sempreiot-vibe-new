import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/heartbeat_log_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/heartbeat_widgets.dart';

/// The heart that beats when a HEARTBEAT arrives, the log behind it, and
/// the bedside monitor of the board's beats as the unit heard them
/// (protocol v3.7 DL_MAP, 2026-10-27).
void main() {
  const board = '7C:4F:AD:AE:85:90';
  const unit = '5A:46:52:00:00:07';

  SafrTrafficTick beat(String mac,
          {SafrMsgType type = SafrMsgType.heartbeat,
          SafrTrafficDirection dir = SafrTrafficDirection.uplink,
          int? dlHeard,
          int? dlMap}) =>
      SafrTrafficTick(
          mac: mac,
          direction: dir,
          severity: 0,
          msgType: type,
          dlHeard: dlHeard,
          dlMap: dlMap);

  group('HeartbeatLog', () {
    test('counts the HEARTBEATs of each sender inside the window', () {
      var now = DateTime.utc(2026, 10, 27, 10);
      final log = HeartbeatLog(traffic: const Stream.empty(), clock: () => now);
      for (var i = 0; i < 9; i++) {
        if (i > 0) now = now.add(const Duration(seconds: 15));
        log.onTick(beat(board));
      }
      // 9 beats, 15 s apart: the first is exactly 120 s old and out of the
      // window, the other 8 are in it.
      expect(log.beatsIn(board), 8);
      expect(log.total(board), 9);
      expect(log.lastBeatAt(board), now);
      expect(log.beatsIn(unit), 0);
      expect(log.lastBeatAt(unit), isNull);
    });

    test('only an uplink HEARTBEAT is a beat', () {
      final now = DateTime.utc(2026, 10, 27, 10);
      final log = HeartbeatLog(traffic: const Stream.empty(), clock: () => now);
      log.onTick(beat(unit, type: SafrMsgType.event));
      log.onTick(beat(unit, type: SafrMsgType.topology));
      log.onTick(beat(unit, dir: SafrTrafficDirection.downlink));
      expect(log.beatsIn(unit), 0);
      log.onTick(beat(unit));
      expect(log.beatsIn(unit), 1);
    });

    test('keeps what each beat said of the board\'s: count and map', () {
      final now = DateTime.utc(2026, 10, 27, 10);
      final log = HeartbeatLog(traffic: const Stream.empty(), clock: () => now);
      log.onTick(beat(unit, dlHeard: 7, dlMap: 0xFB));
      final b = log.recent(unit).single;
      expect(b.dlHeard, 7);
      expect(b.dlMap, 0xFB);
      expect(b.at, now);
    });
  });

  group('HeartbeatHeart', () {
    testWidgets('outline at rest, filled for one beat when the frame arrives',
        (tester) async {
      final bus = SafrTrafficBus();
      addTearDown(bus.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [safrTrafficProvider.overrideWithValue(bus)],
          child: const MaterialApp(
            home: Scaffold(body: HeartbeatHeart(mac: unit)),
          ),
        ),
      );
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);

      bus.emit(beat(unit));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

      await tester.pump(HeartbeatHeart.beat + const Duration(milliseconds: 50));
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    });

    testWidgets('another unit\'s frame is not this unit\'s beat',
        (tester) async {
      final bus = SafrTrafficBus();
      addTearDown(bus.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [safrTrafficProvider.overrideWithValue(bus)],
          child: const MaterialApp(
            home: Scaffold(body: HeartbeatHeart(mac: unit)),
          ),
        ),
      );
      bus.emit(beat(board));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.favorite_rounded), findsNothing);
    });
  });

  group('MonitorPicture: the board\'s beats as the unit heard them', () {
    final now = DateTime.utc(2026, 10, 27, 10, 10);
    // The board's beats every 15 s; the i-th was sent i*15 s ago.
    List<HeartbeatBeat> boardBeats(int n) => [
          for (var i = n - 1; i >= 0; i--)
            HeartbeatBeat(at: now.subtract(Duration(seconds: 15 * i))),
        ];
    // The unit's heartbeat [secondsAgo], carrying its map of the 8 before.
    HeartbeatBeat report(int secondsAgo, int map) => HeartbeatBeat(
        at: now.subtract(Duration(seconds: secondsAgo)),
        dlHeard: 8,
        dlMap: map);

    test('a spike per beat heard, a gap per beat lost, where the map says', () {
      // 21 board beats (the newest just now); the unit reported 5 s ago
      // with slot 2 (the beat 30 s before its report → sent 35 s ago,
      // i.e. the one 30 s ago) lost: 0b11111011.
      final pic = MonitorPicture.build(
        unitBeats: [report(5, 0xFB)],
        boardBeats: boardBeats(21),
        now: now,
      );
      expect(pic.hasMaps, isTrue);
      expect(pic.slots.length, 21, reason: 'every beat sent in 5 min');
      final byAge = {
        for (final s in pic.slots) now.difference(s.at).inSeconds: s.state
      };
      expect(byAge[0], SlotState.pending, reason: 'sent after the report');
      expect(byAge[15], SlotState.heard);
      expect(byAge[30], SlotState.heard);
      expect(byAge[45], SlotState.lost);
      expect(byAge[60], SlotState.heard);
      expect(byAge[120], SlotState.heard, reason: 'the 8th slot of the map');
      expect(byAge[135], SlotState.pending, reason: 'older than the map');
    });

    test(
        'a later report resolves a slot an earlier one left, older reports fill the left',
        () {
      // Two reports: 65 s ago (covers the beats 75..180 s ago) and 5 s ago
      // (covers 15..120 s ago) — the newer wins where both speak.
      final pic = MonitorPicture.build(
        unitBeats: [report(65, 0x7F), report(5, 0xFF)],
        boardBeats: boardBeats(21),
        now: now,
      );
      final byAge = {
        for (final s in pic.slots) now.difference(s.at).inSeconds: s.state
      };
      expect(byAge[180], SlotState.lost, reason: 'the older map\'s 8th slot');
      expect(byAge[165], SlotState.heard);
      expect(byAge[75], SlotState.heard, reason: 'the newer map says heard');
      expect(byAge[195], SlotState.pending, reason: 'nobody spoke of it');
      // Two maps of 8 overlapping on 4: 12 slots spoken for, one lost.
      expect(
          pic.caption, '11 batimentos da placa ouvidos em 5 min · 1 perdido');
    });

    test('a link-up double shares its slot; the caption flags a quiet unit',
        () {
      final beats = boardBeats(3)
        ..add(HeartbeatBeat(at: now.subtract(const Duration(seconds: 28))));
      beats.sort((a, b) => a.at.compareTo(b.at));
      final pic = MonitorPicture.build(
        unitBeats: [report(40, 0xFF)],
        boardBeats: beats,
        now: now,
      );
      expect(pic.slots.length, 3, reason: 'the beat 28 s ago is the 30 s one');
      expect(
          pic.caption,
          '0 batimentos da placa ouvidos em 5 min · 0 perdidos · sem sinal '
          'da unidade há 40 s');
    });

    test('no map (older firmware): the unit\'s own beats, and it says so', () {
      final pic = MonitorPicture.build(
        unitBeats: [
          HeartbeatBeat(
              at: now.subtract(const Duration(seconds: 10)), dlHeard: 7),
        ],
        boardBeats: boardBeats(4),
        now: now,
      );
      expect(pic.hasMaps, isFalse);
      expect(pic.slots.every((s) => s.state == SlotState.pending), isTrue);
      expect(pic.unitBeats.length, 1);
      expect(pic.caption,
          '1 batimento da unidade em 5 min · firmware sem mapa, mostra só os dela');
    });

    test('nothing yet', () {
      expect(
          MonitorPicture.build(
                  unitBeats: const [], boardBeats: const [], now: now)
              .caption,
          'aguardando o primeiro batimento');
    });
  });

  group('HeartbeatMonitor widget', () {
    testWidgets('draws from the log and keeps up with new frames',
        (tester) async {
      final bus = SafrTrafficBus();
      addTearDown(bus.dispose);
      final n = TopologyNode(
        mac: unit,
        role: SafrNodeRole.node,
        layer: 2,
        parentMac: '5A:46:52:00:00:01',
        rssi: -70,
        batteryPct: null,
        online: true,
        lastSeenAt: DateTime.now().toUtc(),
        alarmLatched: false,
        dlHeard: 8,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [safrTrafficProvider.overrideWithValue(bus)],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: HeartbeatMonitor(node: n, boardMac: board),
              ),
            ),
          ),
        ),
      );
      expect(find.text('aguardando o primeiro batimento'), findsOneWidget);
      expect(find.textContaining('BATIMENTOS DA PLACA'), findsOneWidget);
      bus.emit(beat(board));
      await tester.pump();
      bus.emit(beat(unit, dlHeard: 7, dlMap: 0xFE));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final paint =
          tester.widget<CustomPaint>(find.byKey(HeartbeatMonitor.monitorKey));
      final picture = (paint.painter as HeartbeatMonitorPainter).picture;
      expect(picture.hasMaps, isTrue);
      expect(picture.slots.single.state, SlotState.lost,
          reason: 'bit 0 of 0xFE: the newest beat, lost');
      expect(
          find.textContaining('0 batimentos da placa ouvidos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test(
      'the mirror carries DL_HEARD and DL_MAP on the tick, and reads nine without',
      () {
    final t0 = DateTime.utc(2026, 10, 27, 10);
    final frames = decodeMirrorFrames(encodeMirrorFrames(
      seq: 1,
      t0: t0,
      ticks: [
        (offsetMs: 0, tick: beat(unit, dlHeard: 7, dlMap: 0xFB)),
      ],
    ))!;
    expect(frames.ticks.single.tick.dlHeard, 7);
    expect(frames.ticks.single.tick.dlMap, 0xFB);
    final nine = decodeMirrorFrames(
        '{"v":$mirrorVersion,"seq":2,"t0":0,"ticks":[[0,"$unit",0,0,0,null,2,null,10]]}')!;
    expect(nine.ticks.single.tick.dlHeard, isNull);
    expect(nine.ticks.single.tick.dlMap, isNull);
    expect(nine.ticks.single.tick.uptimeS, 10);
  });
}
