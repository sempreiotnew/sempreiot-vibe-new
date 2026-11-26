import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/core/theme/app_colors.dart';
import 'package:sempreiot_central_app/features/central/application/alarm_latch_provider.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_viewer.dart';
import 'package:sempreiot_central_app/features/central/application/device_labels_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_readings_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/panel_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/readings/temp_reading.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/device_readings_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/device_settings_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/devices_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_menu.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_state_tile.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_temp_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/state_devices.dart';

import '../safr/safr_v316_heat_humidity_test.dart' show event, heartbeat;

/// Heat and humidity on the tablet (phase 5 brief §4.6, §8; protocol 3.16):
/// the readings history, the "subindo" rule, the words of the two heat
/// alarms and of the wet sensor, the pill and the device screen. No
/// firmware sends this yet: every frame here is built as §7 lays it out.
void main() {
  const unit = '5A:46:52:00:00:03';
  const board = '00:00:00:00:00:B0';
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('ingest', () {
    late AppDatabase db;
    late SafrIngestService ingest;
    late SafrEncoder encoder;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      ingest = SafrIngestService(db: db);
      encoder = SafrEncoder(srcMac: safrMacToBytes(unit), bootCtr: 10);
    });
    tearDown(() => db.close());

    Future<void> send(SafrMsgType type, Uint8List payload,
            {bool ack = false, bool retx = false}) =>
        ingest.handleFrame(
          encoder.encode(
              msgType: type, payload: payload, ackRequired: ack, retx: retx),
          deviceId: 'test',
        );

    Future<MeshDevice> device() => db.select(db.meshDevices).getSingle();

    test('a heartbeat with a temperature is one reading', () async {
      await send(SafrMsgType.heartbeat, heartbeat(24, temp: 245, humidity: 56));
      final rows = await db.select(db.deviceReadings).get();
      expect(rows, hasLength(1));
      expect(rows.single.deviceMac, unit);
      expect(rows.single.tempTenths, 245);
      expect(rows.single.humidityPct, 56);
      expect(
          DateTime.now().toUtc().difference(rows.single.at).inSeconds.abs() < 5,
          isTrue);
    });

    test('an older heartbeat (20 or 23 bytes): the reading, no humidity',
        () async {
      await send(SafrMsgType.heartbeat, heartbeat(20, temp: 231));
      await send(SafrMsgType.heartbeat, heartbeat(23, temp: 232));
      final rows = await db.select(db.deviceReadings).get();
      expect(rows.map((r) => r.tempTenths), [231, 232]);
      expect(rows.map((r) => r.humidityPct), [null, null]);
    });

    test('TEMP n/a is no reading', () async {
      await send(SafrMsgType.heartbeat, heartbeat(24, temp: 0x7FFF));
      await send(SafrMsgType.event, event(type: 0x02, code: 0x04), ack: true);
      expect(await db.select(db.deviceReadings).get(), isEmpty);
    });

    test('an event with a temperature is a reading; its re-announcement is not',
        () async {
      final alarm =
          event(type: 0x03, code: 0x02, temp: 581, humidity: 30, devSeq: 9);
      await send(SafrMsgType.event, alarm, ack: true);
      await send(SafrMsgType.event, alarm, ack: true, retx: true);
      final rows = await db.select(db.deviceReadings).get();
      expect(rows, hasLength(1));
      expect(rows.single.tempTenths, 581);
      expect(rows.single.humidityPct, 30);
    });

    test('24 hours per unit: older rows leave on insert, others stay',
        () async {
      final now = DateTime.utc(2026, 11, 26, 12);
      await db.addReading(
          mac: unit,
          at: now.subtract(const Duration(hours: 24, minutes: 1)),
          tempTenths: 200);
      await db.addReading(
          mac: unit,
          at: now.subtract(const Duration(hours: 23, minutes: 59)),
          tempTenths: 210);
      await db.addReading(
          mac: board,
          at: now.subtract(const Duration(hours: 30)),
          tempTenths: 190);
      await db.addReading(mac: unit, at: now, tempTenths: 220);
      final rows = await db.select(db.deviceReadings).get();
      expect(rows.where((r) => r.deviceMac == unit).map((r) => r.tempTenths),
          [210, 220]);
      // Another unit's old row is not this insert's business…
      expect(rows.where((r) => r.deviceMac == board), hasLength(1));
      // …it leaves at startup.
      expect(await db.pruneReadings(now), 1);
      expect(await db.select(db.deviceReadings).get(), hasLength(2));
    });

    test('leaving the installation forgets the readings', () async {
      await db.addReading(
          mac: unit, at: DateTime.now().toUtc(), tempTenths: 220);
      await db.forgetInstallationUnits();
      expect(await db.select(db.deviceReadings).get(), isEmpty);
    });

    test('HEAT_RISE_ALARM latches and says why', () async {
      await send(SafrMsgType.event,
          event(type: 0x03, code: 0x0D, temp: 412, devSeq: 5),
          ack: true);
      final d = await device();
      expect(d.alarmLatched, 1);
      expect(d.alarmCode, SafrEventCode.heatRiseAlarm.wire);
      expect(d.alarmTempTenths, 412);
      final ev = await db.select(db.deviceEvents).getSingle();
      expect(ev.severity, 3);
      expect(ev.eventCode, 0x0D);
    });

    test(
        'smoke, then heat: the newest alarm is the cause; a re-announcement '
        'of the first does not bring it back; the reset clears it', () async {
      final smoke = event(type: 0x03, code: 0x01, temp: 300, devSeq: 5);
      await send(SafrMsgType.event, smoke, ack: true);
      expect((await device()).alarmCode, SafrEventCode.smokeAlarm.wire);
      await send(SafrMsgType.event,
          event(type: 0x03, code: 0x02, temp: 580, devSeq: 6),
          ack: true);
      await send(SafrMsgType.event, smoke, ack: true, retx: true);
      var d = await device();
      expect(d.alarmCode, SafrEventCode.heatAlarm.wire);
      expect(d.alarmTempTenths, 580);
      // The RESTORE of the heat alarm is a line, never the end of the latch.
      await send(SafrMsgType.event,
          event(type: 0x01, code: 0x0B, temp: 530, devSeq: 7),
          ack: true);
      d = await device();
      expect(d.alarmLatched, 1);
      expect(d.alarmCode, SafrEventCode.heatAlarm.wire);
      await db.clearAlarmLatch(mac: unit);
      d = await device();
      expect(d.alarmLatched, 0);
      expect(d.alarmCode, isNull);
      expect(d.alarmTempTenths, isNull);
    });

    test('SENSOR_WET holds until the RESTORE with FAULT_CODE 6', () async {
      final wet = event(
          type: 0x04,
          code: 0x0E,
          temp: 230,
          humidity: 100,
          faultFlags: 0x20,
          faultCode: 6,
          devSeq: 5);
      await send(SafrMsgType.event, wet, ack: true);
      var d = await device();
      expect(d.sensorWet, 1);
      expect(d.alarmLatched, 0);
      // A RESTORE of something else leaves it.
      await send(SafrMsgType.event,
          event(type: 0x01, code: 0x0B, faultCode: 2, devSeq: 6),
          ack: true);
      expect((await device()).sensorWet, 1);
      // Heartbeats leave it.
      await send(SafrMsgType.heartbeat, heartbeat(24));
      expect((await device()).sensorWet, 1);
      await send(SafrMsgType.event,
          event(type: 0x01, code: 0x0B, humidity: 80, faultCode: 6, devSeq: 7),
          ack: true);
      expect((await device()).sensorWet, 0);
      // A late retry of the trouble does not bring it back.
      await send(SafrMsgType.event, wet, ack: true, retx: true);
      d = await device();
      expect(d.sensorWet, 0);
      final feed = await db.select(db.deviceEvents).get();
      expect(feed.map((e) => e.severity), [1, 0, 0]);
    });

    test('the latest reading of each unit, with "subindo"', () async {
      final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)]);
      addTearDown(container.dispose);
      final sub = container.listen(latestReadingsProvider, (_, __) {});
      addTearDown(sub.close);
      final now = DateTime.now().toUtc();
      await db.addReading(
          mac: unit,
          at: now.subtract(const Duration(seconds: 45)),
          tempTenths: 240,
          humidityPct: 50);
      await db.addReading(
          mac: unit,
          at: now.subtract(const Duration(seconds: 15)),
          tempTenths: 262);
      await db.addReading(
          mac: board,
          at: now.subtract(const Duration(minutes: 10)),
          tempTenths: 200,
          humidityPct: 40);
      await db.addReading(mac: unit, at: now, tempTenths: 281, humidityPct: 48);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final latest = container.read(latestReadingsProvider).value!;
      expect(latest[unit]!.tempTenths, 281);
      expect(latest[unit]!.humidityPct, 48);
      expect(latest[unit]!.at, isNotNull);
      expect(latest[unit]!.rising, isTrue); // 24,0 → 28,1 in 45 s
      expect(latest[board]!.tempTenths, 200);
      expect(latest[board]!.rising, isFalse);
    });
  });

  test('the chart\'s points: the unit\'s last hour, oldest first', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    final sub = container.listen(deviceChartProvider(unit), (_, __) {});
    addTearDown(sub.close);
    final now = DateTime.now().toUtc();
    Future<void> add(String mac, Duration ago, int t) =>
        db.addReading(mac: mac, at: now.subtract(ago), tempTenths: t);
    await add(unit, const Duration(minutes: 90), 200);
    await add(unit, const Duration(minutes: 30), 231);
    await add(board, const Duration(minutes: 20), 999);
    await add(unit, const Duration(seconds: 40), 245);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final points = container.read(deviceChartProvider(unit)).value!;
    expect(points.map((p) => p.tenths), [231, 245]);
  });

  group('"subindo": ≥ 4,0 °C within 60 s, on the points that arrived', () {
    final now = DateTime.utc(2026, 11, 26, 12);
    TempPoint p(int secondsAgo, int tenths) => TempPoint(
        at: now.subtract(Duration(seconds: secondsAgo)), tenths: tenths);

    test('4,0 °C in 45 s', () {
      expect(tempRising([p(45, 240), p(30, 250), p(0, 280)], now), isTrue);
    });
    test('3,9 °C is not', () {
      expect(tempRising([p(45, 240), p(0, 279)], now), isFalse);
    });
    test('4 °C, but over more than 60 s', () {
      expect(tempRising([p(61, 240), p(30, 260), p(0, 280)], now), isFalse);
    });
    test('exactly 60 s apart counts', () {
      expect(tempRising([p(60, 240), p(0, 280)], now), isTrue);
    });
    test('it went up and came back: not rising now', () {
      expect(tempRising([p(50, 240), p(30, 290), p(0, 245)], now), isFalse);
    });
    test('falling is not rising', () {
      expect(tempRising([p(40, 300), p(0, 240)], now), isFalse);
    });
    test('one point, or none', () {
      expect(tempRising([p(0, 500)], now), isFalse);
      expect(tempRising(const [], now), isFalse);
    });
    test('an old rise is not "now": the newest point is over 60 s old', () {
      expect(tempRising([p(120, 240), p(90, 290)], now), isFalse);
    });
    test('the order of the points does not matter', () {
      expect(tempRising([p(0, 280), p(45, 240)], now), isTrue);
    });
  });

  group('words', () {
    test('the two heat alarms, with the reading of the event', () {
      expect(heatAlarmWords(SafrEventCode.heatAlarm, 580), 'Calor — 58 °C');
      expect(heatAlarmWords(SafrEventCode.heatAlarm, 575), 'Calor — 58 °C');
      expect(heatAlarmWords(SafrEventCode.heatRiseAlarm, 412),
          'Calor — subida rápida, 41 °C');
      expect(heatAlarmWords(SafrEventCode.heatAlarm, null), 'Calor');
      expect(heatAlarmWords(SafrEventCode.heatRiseAlarm, null),
          'Calor — subida rápida');
      expect(heatAlarmWords(SafrEventCode.smokeAlarm, 300), isNull);
      expect(sensorWetWords, 'Sensor molhado');
    });

    test('numbers: one decimal, whole percent, the age', () {
      expect(tempText(245), '24,5 °C');
      expect(tempText(-5), '-0,5 °C');
      expect(tempText(570), '57,0 °C');
      expect(humidityText(56), '56 %');
      final now = DateTime.utc(2026, 11, 26, 12);
      String age(Duration d) => readingAgeText(now.subtract(d), now);
      expect(age(const Duration(seconds: 2)), 'agora');
      expect(age(const Duration(seconds: 40)), 'há 40 s');
      expect(age(const Duration(minutes: 3, seconds: 20)), 'há 3 min');
      expect(age(const Duration(hours: 2, minutes: 5)), 'há 2 h');
      expect(age(const Duration(days: 3)), 'há 3 d');
    });

    test('the alarm tile of Principal', () {
      expect(alarmStatusText(code: 0x02, tempTenths: 580), 'Calor — 58 °C');
      expect(alarmStatusText(code: 0x0D, tempTenths: 412),
          'Calor — subida rápida, 41 °C');
      expect(alarmStatusText(code: 0x01, tempTenths: 300), 'em alarme');
      expect(alarmStatusText(), 'em alarme');
    });

    test('the event lines (Principal, Eventos, the mirror)', () {
      DeviceEvent row(int severity, int code, String detail) => DeviceEvent(
            id: 1,
            receivedAt: DateTime.utc(2026, 11, 26, 12),
            deviceMac: unit,
            msgType: 1,
            eventCode: code,
            severity: severity,
            detailJson: detail,
          );
      String name(String mac) => 'Hall';
      expect(panelEventOf(row(3, 0x02, '{"temp_tenths":580}'), name)!.text,
          'Hall — calor — 58 °C');
      expect(panelEventOf(row(3, 0x0D, '{"temp_tenths":412}'), name)!.text,
          'Hall — calor — subida rápida, 41 °C');
      expect(panelEventOf(row(3, 0x02, '{}'), name)!.text, 'Hall — calor');
      final wet = panelEventOf(row(1, 0x0E, '{"fault_code":6}'), name)!;
      expect(wet.text, 'Hall — sensor molhado');
      expect(wet.kind, PanelEventKind.trouble);
      final dry = panelEventOf(row(0, 0x0B, '{"fault_code":6}'), name)!;
      expect(dry.text, 'Hall — sensor não está mais molhado');
      expect(dry.kind, PanelEventKind.ok);
      expect(panelEventOf(row(0, 0x0B, '{"fault_code":2}'), name)!.text,
          'Hall — voltou ao normal');
      expect(panelEventOf(row(3, 0x0D, '{"temp_tenths":412}'), name)!.kind,
          PanelEventKind.alarm);
    });
  });

  final seen = DateTime.now().toUtc();
  TopologyNode node(
    String mac, {
    bool online = true,
    bool alarm = false,
    int? temp,
    int? humidity,
    DateTime? readingAt,
    bool rising = false,
    SafrEventCode? alarmCode,
    int? alarmTemp,
    bool wet = false,
    bool leaf = false,
    String? name,
  }) =>
      TopologyNode(
        mac: mac,
        role: leaf ? SafrNodeRole.leaf : SafrNodeRole.node,
        layer: 2,
        parentMac: board,
        rssi: -60,
        batteryPct: leaf ? 87 : null,
        online: online,
        lastSeenAt: seen,
        alarmLatched: alarm,
        alarmLatchedAt: alarm ? seen : null,
        name: name,
        tempTenths: temp,
        humidityPct: humidity,
        readingAt: temp == null ? null : (readingAt ?? seen),
        tempRising: rising,
        alarmCode: alarmCode,
        alarmTempTenths: alarmTemp,
        sensorWet: wet,
      );

  group('the pill', () {
    test('no reading, no pill', () {
      expect(tempPillState(node(unit)), isNull);
    });
    test('neutral, amber, red, grey', () {
      expect(tempPillState(node(unit, temp: 245)), TempPillState.normal);
      expect(tempPillState(node(unit, temp: 290, rising: true)),
          TempPillState.rising);
      expect(
          tempPillState(node(unit,
              temp: 580,
              rising: true,
              alarm: true,
              alarmCode: SafrEventCode.heatAlarm)),
          TempPillState.alarm);
      expect(
          tempPillState(node(unit,
              temp: 412, alarm: true, alarmCode: SafrEventCode.heatRiseAlarm)),
          TempPillState.alarm);
      // Held for smoke: the pill is not the alarm's.
      expect(
          tempPillState(node(unit,
              temp: 245, alarm: true, alarmCode: SafrEventCode.smokeAlarm)),
          TempPillState.normal);
      // Not heard: grey, whatever else.
      expect(
          tempPillState(node(unit,
              temp: 580,
              online: false,
              rising: true,
              alarm: true,
              alarmCode: SafrEventCode.heatAlarm)),
          TempPillState.offline);
    });
  });

  group('Principal: a wet sensor is a problem', () {
    test('counted and listed with its reason; an alarm comes first', () {
      const other = '5A:46:52:00:00:04';
      const third = '5A:46:52:00:00:05';
      final container = ProviderContainer(overrides: [
        topologyProvider.overrideWithValue([
          node(unit, wet: true, name: 'Hall'),
          node(other, name: 'Sala 2'),
          // In alarm and wet: listed as the alarm it is, not twice.
          node(third, wet: true, alarm: true, name: 'Copa'),
        ]),
        latchedAlarmsProvider.overrideWith((ref) => Stream.value([
              MeshDevice(
                mac: third,
                role: 1,
                layer: 2,
                firstSeenAt: seen,
                lastSeenAt: seen,
                lastBootCtr: 0,
                lastMsgCtr: 0,
                supervisionState: 0,
                linkKind: 0,
                lastDevSeq: 0,
                alarmLatched: 1,
                boardFlags: 0,
                sensorWet: 1,
              ),
            ])),
        localPanelEventsProvider.overrideWith((ref, limit) => const []),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(latchedAlarmsProvider, (_, __) {});
      addTearDown(sub.close);
      return Future<void>.delayed(Duration.zero).then((_) {
        final view = container.read(localPanelProvider);
        expect(view.total, 3);
        expect(view.alarms, 1);
        expect(view.troubles, 1);
        expect(view.troubleList.single.name, 'Hall');
        expect(view.troubleList.single.why, MirrorTrouble.wet);
      });
    });

    testWidgets('its tile says "Sensor molhado"', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: TroubleDeviceTile(
            trouble: MirrorTrouble(name: 'Hall', why: MirrorTrouble.wet),
          ),
        ),
      ));
      expect(find.text('Sensor molhado'), findsOneWidget);
      expect(find.text('sem comunicação'), findsNothing);
      expect(find.text('bateria baixa'), findsNothing);
    });
  });

  group('the mirror', () {
    test('a unit\'s reading, its "subindo", why it is in alarm, wet', () {
      final at = DateTime.utc(2026, 11, 26, 12, 0, 5);
      final nodes = [
        node(unit,
            temp: 580,
            humidity: 31,
            readingAt: at,
            rising: true,
            alarm: true,
            alarmCode: SafrEventCode.heatAlarm,
            alarmTemp: 578,
            wet: true),
        node(board),
      ];
      final back = decodeMirrorState(
          encodeMirrorState(seq: 1, at: at, link: 'connected', nodes: nodes))!;
      final u = back.nodes.first;
      expect(u.tempTenths, 580);
      expect(u.humidityPct, 31);
      expect(u.readingAt, at);
      expect(u.tempRising, isTrue);
      expect(u.alarmCode, SafrEventCode.heatAlarm);
      expect(u.alarmTempTenths, 578);
      expect(u.heatAlarm, isTrue);
      expect(u.sensorWet, isTrue);
      final other = back.nodes.last;
      expect(other.tempTenths, isNull);
      expect(other.readingAt, isNull);
      expect(other.tempRising, isFalse);
      expect(other.sensorWet, isFalse);
      // A unit marked by the viewer keeps all of it.
      expect(asSuggestedRoot(u).tempTenths, 580);
      expect(asSuggestedRoot(u).sensorWet, isTrue);
      expect(asSuggestedRoot(u).alarmCode, SafrEventCode.heatAlarm);
    });

    test('a new number alone is not a new map; "subindo" and wet are', () {
      String sig(TopologyNode n) => mirrorStateSignature('connected', [n]);
      final base = sig(node(unit, temp: 245, humidity: 50));
      expect(sig(node(unit, temp: 251, humidity: 49)), base);
      expect(sig(node(unit, temp: 245, rising: true)), isNot(base));
      expect(sig(node(unit, temp: 245, wet: true)), isNot(base));
    });

    test('the alarm message says why; a wet sensor is a trouble', () {
      final at = DateTime.utc(2026, 11, 26, 12);
      final back = decodeMirrorAlarms(encodeMirrorAlarms(
        at: at,
        alarms: const [
          MirrorAlarm(mac: unit, name: 'Hall', code: 0x0D, tempTenths: 412),
          MirrorAlarm(mac: board),
        ],
        panel: const MirrorPanel(total: 2, troubles: 1, troubleList: [
          MirrorTrouble(name: 'Sala 2', why: MirrorTrouble.wet, mac: board),
        ]),
      ))!;
      expect(back.alarms.first.code, 0x0D);
      expect(back.alarms.first.tempTenths, 412);
      expect(back.alarms.last.code, isNull);
      expect(back.panel!.troubleList.single.why, MirrorTrouble.wet);
    });
  });

  group('the chart draws what arrived', () {
    final now = DateTime.utc(2026, 11, 26, 12);
    TempPoint p(int secondsAgo, int tenths) => TempPoint(
        at: now.subtract(Duration(seconds: secondsAgo)), tenths: tenths);

    test('only the last hour', () {
      final g = TempChartGeometry(
          points: [p(3700, 200), p(3500, 210), p(10, 220)], now: now);
      expect(g.points.map((e) => e.tenths), [210, 220]);
    });

    test('a line only between points at most 150 s apart', () {
      final g = TempChartGeometry(points: [
        p(600, 200),
        p(540, 205), // 60 s: joined
        p(390, 210), // 150 s: joined
        p(239, 215), // 151 s: a gap
        p(180, 220), // joined
      ], now: now);
      expect(g.segments, [(0, 1), (1, 2), (3, 4)]);
      expect(g.points, hasLength(5)); // every point is still drawn
    });

    test('the 57 °C line is always inside; no point is moved', () {
      final cool = TempChartGeometry(points: [p(60, 215), p(0, 232)], now: now);
      expect(cool.minTenths, 200);
      expect(cool.maxTenths, 600);
      expect(cool.yOf(570), inInclusiveRange(0, 1));
      expect(cool.xOf(now), 1);
      expect(cool.xOf(now.subtract(const Duration(minutes: 30))), 0.5);
      final hot = TempChartGeometry(points: [p(0, 655)], now: now);
      expect(hot.maxTenths, 700);
      expect(hot.yOf(655), inInclusiveRange(0, 1));
      final cold = TempChartGeometry(points: [p(0, -55)], now: now);
      expect(cold.minTenths, -100);
      expect(cold.yOf(-55), inInclusiveRange(0, 1));
    });

    test('humidity: its own scale, a line only where both ends carry one', () {
      TempPoint h(int secondsAgo, int? pct) => TempPoint(
          at: now.subtract(Duration(seconds: secondsAgo)),
          tenths: 250,
          humidityPct: pct);
      final g = TempChartGeometry(
          points: [h(180, 52), h(120, 59), h(60, null), h(0, 61)], now: now);
      expect(g.hasHumidity, isTrue);
      expect(g.segments, [(0, 1), (1, 2), (2, 3)]);
      expect(g.humiditySegments, [(0, 1)]);
      expect(g.minHumidity, 50);
      expect(g.maxHumidity, 70);
      expect(g.yOfHumidity(52), inInclusiveRange(0, 1));
      expect(g.yOfHumidity(61), inInclusiveRange(0, 1));
      final wet = TempChartGeometry(points: [h(0, 100)], now: now);
      expect(wet.maxHumidity, 100); // saturated air stays inside 0…100 %
      expect(wet.minHumidity, 80);
      expect(TempChartGeometry(points: [p(0, 250)], now: now).hasHumidity,
          isFalse);
    });

    test('the pinch: apart = less time, together = more, inside the limits',
        () {
      const hour = Duration(hours: 1);
      expect(pinchedChartWindow(hour, 1), hour);
      expect(pinchedChartWindow(hour, 2), const Duration(minutes: 30));
      expect(pinchedChartWindow(hour, 0.5), const Duration(hours: 2));
      expect(pinchedChartWindow(hour, 1000), tempChartZoomMin);
      expect(pinchedChartWindow(hour, 0.001), tempChartZoomMax);
      expect(pinchedChartWindow(hour, 0), hour);
    });

    test('closer in: less time and narrower scales; every point stays inside',
        () {
      TempPoint h(int secondsAgo, int tenths, int pct) => TempPoint(
          at: now.subtract(Duration(seconds: secondsAgo)),
          tenths: tenths,
          humidityPct: pct);
      final pts = [
        h(7200, 230, 50),
        h(240, 252, 58),
        h(60, 254, 59),
        h(0, 255, 59)
      ];
      TempChartGeometry at(Duration w) =>
          TempChartGeometry(points: pts, now: now, window: w, fit: true);
      final close = at(tempChartZoomMin);
      expect(close.points.map((e) => e.tenths), [252, 254, 255]);
      expect(close.tempStepTenths, lessThan(10)); // tenths of a degree
      expect(close.maxTenths - close.minTenths, lessThanOrEqualTo(20));
      expect(close.maxHumidity - close.minHumidity, lessThanOrEqualTo(6));
      expect(close.showsLimit, isFalse); // 57 °C is not in what is shown
      expect(close.xOf(now.subtract(const Duration(seconds: 150))), 0.5);
      final far = at(tempChartZoomMax);
      expect(far.points, hasLength(4));
      expect(far.xOf(now.subtract(const Duration(hours: 12))), 0.5);
      final hot = TempChartGeometry(
          points: [h(60, 480, 30), h(0, 590, 28)],
          now: now,
          window: const Duration(minutes: 30),
          fit: true);
      expect(hot.showsLimit, isTrue);
      for (final g in [close, far, hot]) {
        for (final e in g.points) {
          expect(g.yOf(e.tenths), inInclusiveRange(0, 1));
          expect(g.yOfHumidity(e.humidityPct!), inInclusiveRange(0, 1));
        }
      }
    });

    test('the words of the span and of the time axis', () {
      expect(chartWindowText(const Duration(hours: 1)), 'última hora');
      expect(chartWindowText(const Duration(minutes: 15)), 'últimos 15 min');
      expect(chartWindowText(const Duration(hours: 6)), 'últimas 6 h');
      expect(chartWindowText(const Duration(minutes: 150)), 'últimas 2,5 h');
    });

    test('the time axis: the tablet\'s clock on round times, and the day', () {
      // on the tablet's own clock, whatever its zone
      final end = DateTime(2026, 11, 26, 14, 7, 30).toUtc();
      List<DateTime> ticks(Duration w, int most) =>
          chartTimeTicks(end.subtract(w), end, most);

      final hour = ticks(const Duration(hours: 1), 6);
      expect(hour.map(chartClockText),
          ['13:10', '13:20', '13:30', '13:40', '13:50', '14:00']);
      final close = ticks(const Duration(minutes: 5), 6);
      expect(close.map(chartClockText),
          ['14:03', '14:04', '14:05', '14:06', '14:07']);
      // a narrow chart: fewer marks, never more than fit
      expect(ticks(const Duration(hours: 1), 3).map(chartClockText),
          ['13:30', '14:00']);
      // a day: every 6 h, and the midnight says which day begins
      final day = ticks(const Duration(hours: 24), 6);
      expect(day.map(chartClockText), ['18:00', '00:00', '06:00', '12:00']);
      expect(chartDayText(day[1]), '26/11');
      for (final w in [5, 37, 240, 1440]) {
        final t = ticks(Duration(minutes: w), 5);
        expect(t.length, inInclusiveRange(1, 6));
        expect(t.every((e) => !e.isAfter(end)), isTrue);
      }

      expect(chartDateText(end.subtract(const Duration(hours: 1)), end),
          '26/11/2026');
      expect(chartDateText(end.subtract(const Duration(hours: 24)), end),
          '25/11 – 26/11/2026');
    });

    test('nothing in the last hour', () {
      final g = TempChartGeometry(points: const [], now: now);
      expect(g.points, isEmpty);
      expect(g.segments, isEmpty);
    });
  });

  const sizes = <String, Size>{
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(360, 640),
    'phone landscape': Size(640, 360),
  };

  // The database's live queries are checked above, without widgets (a
  // drift stream closing leaves a timer behind in a widget test): here the
  // screens get their points and labels as values.
  Future<void> pump(
    WidgetTester tester,
    Size size,
    List<TopologyNode> mesh,
    Widget home, {
    String? viewedCentral,
    List<TempPoint> chart = const [],
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          topologyProvider.overrideWithValue(mesh),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          otaPushViewProvider.overrideWithValue(const OtaPushState()),
          labelIndexProvider.overrideWithValue(const LabelIndex.empty()),
          deviceChartProvider.overrideWith((ref, mac) => Stream.value(chart)),
          deviceChartAllProvider
              .overrideWith((ref, mac) => Stream.value(chart)),
          if (viewedCentral != null)
            mirrorViewOnlyProvider.overrideWithValue(true),
        ],
        child: MaterialApp(home: home),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Color pillColor(WidgetTester tester, String mac) {
    final text = tester.widget<Text>(find.descendant(
        of: find.byKey(DevicesScreen.tempPillKey(mac)),
        matching: find.byType(Text)));
    return text.style!.color!;
  }

  group('Dispositivos: the temperature pill', () {
    const a = '5A:46:52:00:00:0A';
    const b = '5A:46:52:00:00:0B';
    const c = '5A:46:52:00:00:0C';
    const d = '5A:46:52:00:00:0D';
    const e = '5A:46:52:00:00:0E';
    final mesh = [
      node(a, temp: 245, humidity: 56, name: 'Normal', leaf: true),
      node(b, temp: 291, rising: true, name: 'Subindo'),
      node(c,
          temp: 583,
          alarm: true,
          alarmCode: SafrEventCode.heatAlarm,
          alarmTemp: 580,
          name: 'Calor'),
      node(d, temp: 222, online: false, name: 'Mudo'),
      node(e, name: 'Sem sensor'),
    ];

    for (final s in sizes.entries) {
      testWidgets('one per unit with a reading — ${s.key}', (tester) async {
        await pump(tester, s.value, mesh,
            const Scaffold(body: SafeArea(child: DevicesScreen())));
        expect(tester.takeException(), isNull);
        final shown = [
          for (final mac in [a, b, c, d, e])
            if (find
                .byKey(DevicesScreen.tempPillKey(mac))
                .evaluate()
                .isNotEmpty)
              mac,
        ];
        // The grid builds what fits; a unit with no reading never has one.
        expect(shown, isNot(contains(e)));
        expect(shown, isNotEmpty);
        // No humidity on a card.
        expect(find.textContaining('56 %'), findsNothing);
        expect(find.textContaining('56%'), findsNothing);
      });
    }

    testWidgets('neutral, amber, red, grey — and none without a reading',
        (tester) async {
      await pump(tester, const Size(1280, 800), mesh,
          const Scaffold(body: DevicesScreen()));
      expect(find.text('24,5 °C'), findsOneWidget);
      expect(find.text('29,1 °C'), findsOneWidget);
      expect(find.text('58,3 °C'), findsOneWidget);
      expect(find.text('22,2 °C'), findsOneWidget);
      expect(find.byKey(DevicesScreen.tempPillKey(e)), findsNothing);
      final neutral = pillColor(tester, a);
      expect(pillColor(tester, b), AppColors.warning);
      expect(pillColor(tester, c), AppColors.error);
      final grey = pillColor(tester, d);
      expect(neutral, isNot(AppColors.warning));
      expect(neutral, isNot(AppColors.error));
      expect(grey, isNot(neutral));
      expect(grey.a, lessThan(neutral.a));
      expect(tester.takeException(), isNull);
    });
  });

  group('The unit\'s popover: the TEMPERATURA E UMIDADE tile', () {
    final at = DateTime.now().toUtc().subtract(const Duration(seconds: 40));
    // A screen with one thing to tap: it opens the popover of [unit].
    Widget opener() => Scaffold(
          body: Center(
            child: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showDeviceMenuFor(context, ref, unit),
                child: const Text('abrir'),
              ),
            ),
          ),
        );

    for (final s in sizes.entries) {
      testWidgets('both readings in one tile; a tap opens the chart — ${s.key}',
          (tester) async {
        final now = DateTime.now().toUtc();
        await pump(
            tester,
            s.value,
            [node(unit, temp: 245, humidity: 56, readingAt: at, name: 'Hall')],
            opener(),
            chart: [
              for (final (ago, t) in [(600, 240), (40, 245)])
                TempPoint(at: now.subtract(Duration(seconds: ago)), tenths: t),
            ]);
        await tester.tap(find.text('abrir'));
        await tester.pumpAndSettle();
        final tile = find.text('TEMPERATURA E UMIDADE');
        await tester.scrollUntilVisible(tile, 60,
            scrollable: find.byType(Scrollable).last);
        expect(tile, findsOneWidget);
        expect(find.text('24,5 °C'), findsOneWidget);
        expect(find.text('56 %'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.byType(DeviceReadingsScreen), findsOneWidget);
        await tester.scrollUntilVisible(
            find.byKey(DeviceTempSection.keyChart), 80,
            scrollable: find.byType(Scrollable).first);
        final chart =
            tester.widget<TempChart>(find.byKey(DeviceTempSection.keyChart));
        expect(chart.points.map((p) => p.tenths), [240, 245]);
        expect(tester.takeException(), isNull);
      });
    }

    test('the thermometer takes the colour of the reading', () {
      expect(readingsGaugeColor(273), AppColors.success);
      expect(readingsGaugeColor(300), AppColors.warning);
      expect(readingsGaugeColor(499), AppColors.warning);
      expect(readingsGaugeColor(500), AppColors.error);
    });

    test('the drop fills with the humidity', () {
      expect(humidityDropFill(null), 0);
      expect(humidityDropFill(0), 0);
      expect(humidityDropFill(59), closeTo(0.59, 1e-9));
      expect(humidityDropFill(100), 1);
    });

    testWidgets('the thermometer beside the temperature, a blue drop',
        (tester) async {
      await pump(
          tester,
          sizes['tablet landscape']!,
          [node(unit, temp: 273, humidity: 59, readingAt: at, name: 'Hall')],
          opener());
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      final thermo = find.byKey(const ValueKey('device-menu-thermometer'));
      expect(tester.widget<Icon>(thermo).color, AppColors.success);
      // left of the number, on its line
      final t = tester.getRect(thermo),
          v = tester.getRect(find.text('27,3 °C'));
      expect(t.right, lessThanOrEqualTo(v.left));
      expect((t.center.dy - v.center.dy).abs(), lessThan(4));
      final drop = find.byKey(const ValueKey('device-menu-humidity-drop'));
      final icons = tester.widgetList<Icon>(
          find.descendant(of: drop, matching: find.byType(Icon)));
      expect(icons.map((i) => i.color).toSet(), {AppColors.info});
      expect(tester.takeException(), isNull);
    });

    testWidgets('the readings screen: two fingers zoom the chart',
        (tester) async {
      for (final size in sizes.values) {
        await pump(
            tester,
            size,
            [node(unit, temp: 245, humidity: 56, readingAt: at, name: 'Hall')],
            // a fresh screen per size: the zoom is the screen's own state
            DeviceReadingsScreen(key: ValueKey(size), mac: unit));
        TempChart chart() =>
            tester.widget<TempChart>(find.byKey(DeviceTempSection.keyChart));
        Text span() =>
            tester.widget<Text>(find.byKey(DeviceTempSection.keySpan));
        await tester.scrollUntilVisible(
            find.byKey(DeviceTempSection.keyChart), 80,
            scrollable: find.byType(Scrollable).first);
        await tester.pump(const Duration(milliseconds: 50));
        expect(chart().window, const Duration(hours: 1));
        expect(span().data, startsWith('Última hora · '));

        // fingers apart: closer
        final c = tester.getCenter(find.byKey(DeviceTempSection.keyChart));
        var a = await tester.startGesture(c - const Offset(30, 0), pointer: 1);
        var b = await tester.startGesture(c + const Offset(30, 0), pointer: 2);
        await tester.pump();
        await a.moveBy(const Offset(-60, 0));
        await b.moveBy(const Offset(60, 0));
        await tester.pump();
        await a.up();
        await b.up();
        await tester.pump(const Duration(milliseconds: 50));
        final closer = chart().window!;
        expect(closer, lessThan(const Duration(hours: 1)));
        expect(span().data, startsWith('Últimos'));

        // fingers together: further
        a = await tester.startGesture(c - const Offset(120, 0), pointer: 3);
        b = await tester.startGesture(c + const Offset(120, 0), pointer: 4);
        await tester.pump();
        await a.moveBy(const Offset(100, 0));
        await b.moveBy(const Offset(-100, 0));
        await tester.pump();
        await a.up();
        await b.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(chart().window!, greaterThan(closer));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a unit that sent no reading has no such tile', (tester) async {
      await pump(tester, sizes['tablet landscape']!, [node(unit, name: 'Hall')],
          opener());
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('ENDEREÇAMENTO'), findsOneWidget);
      expect(find.text('TEMPERATURA E UMIDADE'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Dispositivo: temperatura e umidade', () {
    final at = DateTime.now().toUtc().subtract(const Duration(seconds: 40));

    for (final s in sizes.entries) {
      testWidgets('values, age and chart — ${s.key}', (tester) async {
        final now = DateTime.now().toUtc();
        await pump(
            tester,
            s.value,
            [node(unit, temp: 245, humidity: 56, readingAt: at)],
            const DeviceSettingsScreen(mac: unit),
            chart: [
              for (final (ago, t) in [
                (1800, 231),
                (1740, 236),
                (600, 240),
                (40, 245)
              ])
                TempPoint(at: now.subtract(Duration(seconds: ago)), tenths: t),
            ]);
        await tester.scrollUntilVisible(
            find.byKey(DeviceTempSection.keyChart), 80,
            scrollable: find.byType(Scrollable).first);
        expect(find.text('TEMPERATURA E UMIDADE'), findsOneWidget);
        expect(find.text('24,5 °C'), findsOneWidget);
        expect(find.text('56 %'), findsOneWidget);
        final age = tester.widget<Text>(find.byKey(DeviceTempSection.keyAge));
        expect(age.data, matches(RegExp(r'^Leitura há 4\d s$')));
        final chart =
            tester.widget<TempChart>(find.byKey(DeviceTempSection.keyChart));
        expect(chart.points.map((p) => p.tenths), [231, 236, 240, 245]);
        expect(chart.muted, isFalse);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the age counts by itself', (tester) async {
      await pump(
          tester,
          const Size(800, 1280),
          [node(unit, temp: 245, humidity: 56, readingAt: at)],
          const DeviceSettingsScreen(mac: unit));
      String age() =>
          tester.widget<Text>(find.byKey(DeviceTempSection.keyAge)).data!;
      expect(age(), matches(RegExp(r'^Leitura há 4\d s$')));
      // The widget's own clock is the wall clock: what is checked is that
      // it repaints every second without anything else changing.
      final before = tester.binding.clock.now();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.clock.now().difference(before).inSeconds, 2);
      expect(age(), startsWith('Leitura há '));
      expect(tester.takeException(), isNull);
    });

    testWidgets('not heard: the last reading, grey, said so', (tester) async {
      await pump(
          tester,
          const Size(800, 1280),
          [node(unit, temp: 245, readingAt: at, online: false)],
          const DeviceSettingsScreen(mac: unit));
      await tester.scrollUntilVisible(
          find.byKey(DeviceTempSection.keyChart), 80,
          scrollable: find.byType(Scrollable).first);
      final age = tester.widget<Text>(find.byKey(DeviceTempSection.keyAge));
      expect(age.data, startsWith('Última leitura há '));
      expect(age.data, endsWith('sem comunicação'));
      // No humidity was sent: a dash, never a number.
      expect(
          find.descendant(
              of: find.byKey(DeviceTempSection.keyHumidity),
              matching: find.text('—')),
          findsOneWidget);
      expect(
          tester
              .widget<TempChart>(find.byKey(DeviceTempSection.keyChart))
              .muted,
          isTrue);
      expect(find.text('Nenhuma leitura na última hora.'), findsOneWidget);
    });

    testWidgets('a unit that never sent a reading has no block',
        (tester) async {
      await pump(tester, const Size(800, 1280), [node(unit)],
          const DeviceSettingsScreen(mac: unit));
      expect(find.text('TEMPERATURA E UMIDADE'), findsNothing);
      expect(find.byType(DeviceTempSection), findsNothing);
    });

    testWidgets('a phone: the values, and the chart is at the central',
        (tester) async {
      await pump(
          tester,
          const Size(360, 640),
          [node(unit, temp: 245, humidity: 56, readingAt: at)],
          const DeviceSettingsScreen(mac: unit),
          viewedCentral: 'us-east-1:central');
      await tester.scrollUntilVisible(
          find.text('O gráfico da última hora fica na central.'), 80,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('24,5 °C'), findsOneWidget);
      expect(find.text('56 %'), findsOneWidget);
      expect(find.byKey(DeviceTempSection.keyChart), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('in a heat alarm and wet: said under Estado', (tester) async {
      await pump(
          tester,
          const Size(800, 1280),
          [
            node(unit,
                temp: 583,
                readingAt: at,
                alarm: true,
                alarmCode: SafrEventCode.heatRiseAlarm,
                alarmTemp: 412,
                wet: true)
          ],
          const DeviceSettingsScreen(mac: unit));
      await tester.scrollUntilVisible(find.text('Alarme retido'), 80,
          scrollable: find.byType(Scrollable).first);
      expect(
          find.textContaining('Calor — subida rápida, 41 °C'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('Sensor molhado'), 80,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Sensor molhado'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
