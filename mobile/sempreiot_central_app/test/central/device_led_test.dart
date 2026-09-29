import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/device_led_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/led/led_language.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// The on-screen LED must follow the firmware (siot_ui_led.c): same colours,
/// same durations, same queue.
void main() {
  const boardMac = 'BB:00:00:00:00:00';
  const rootMac = 'AA:00:00:00:00:01';
  const childMac = 'AA:00:00:00:00:02';
  const leafMac = 'CC:00:00:00:00:03';

  late DateTime now;
  late List<TopologyNode> nodes;
  late DeviceLedEngine engine;
  late StreamController<SafrTrafficTick> traffic;

  TopologyNode node(String mac, SafrNodeRole role, int layer,
          {bool online = true, bool alarm = false}) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: null,
        rssi: -60,
        batteryPct: null,
        online: online,
        lastSeenAt: DateTime.now().toUtc(),
        alarmLatched: alarm,
      );

  TopologyNode find(String mac) => nodes.firstWhere((n) => n.mac == mac);
  LedColor? at(String mac, int ms) {
    now = DateTime(2026, 1, 1).add(Duration(milliseconds: ms));
    return engine.look(find(mac)).color;
  }

  void tickAt(int ms, SafrTrafficTick t) {
    now = DateTime(2026, 1, 1).add(Duration(milliseconds: ms));
    engine.onTick(t);
  }

  SafrTrafficTick up(String mac, SafrMsgType type, {SafrEventCode? code}) =>
      SafrTrafficTick(
        mac: mac,
        direction: SafrTrafficDirection.uplink,
        severity: 0,
        msgType: type,
        eventCode: code,
      );

  SafrTrafficTick ackDown(String mac) => SafrTrafficTick(
        mac: mac,
        direction: SafrTrafficDirection.downlink,
        severity: 0,
        ack: true,
        msgType: SafrMsgType.ack,
      );

  setUp(() {
    now = DateTime(2026, 1, 1);
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(rootMac, SafrNodeRole.root, 1),
      node(childMac, SafrNodeRole.node, 2),
      node(leafMac, SafrNodeRole.leaf, 3),
    ];
    traffic = StreamController<SafrTrafficTick>.broadcast();
    engine = DeviceLedEngine(
      traffic: traffic.stream,
      nodes: () => nodes,
      clock: () => now,
    );
  });

  tearDown(() {
    engine.dispose();
    traffic.close();
  });

  test('a HEARTBEAT is a 100 ms blue tick on the unit and on the board', () {
    tickAt(0, up(childMac, SafrMsgType.heartbeat));
    expect(at(childMac, 50), LedColor.blue);
    expect(at(childMac, 150), isNull);
    expect(at(boardMac, 50), LedColor.blue);
    expect(at(boardMac, 150), isNull);
  });

  test('ticks fold: two heartbeats inside 100 ms light one pulse', () {
    tickAt(0, up(childMac, SafrMsgType.heartbeat));
    tickAt(40, up(childMac, SafrMsgType.heartbeat));
    expect(at(childMac, 90), LedColor.blue);
    expect(at(childMac, 110), isNull);
  });

  test('an EVENT is blue 500 ms, then the tablet ACK queues cyan 500 ms', () {
    tickAt(0, up(childMac, SafrMsgType.event));
    tickAt(20, ackDown(childMac));
    expect(at(childMac, 400), LedColor.blue);
    expect(at(childMac, 700), LedColor.cyan);
    expect(at(childMac, 1100), isNull);
  });

  test('a leaf stays dark for routine frames', () {
    tickAt(0, up(leafMac, SafrMsgType.heartbeat));
    tickAt(10, up(leafMac, SafrMsgType.event, code: SafrEventCode.smokeAlarm));
    expect(at(leafMac, 50), isNull);
    expect(at(leafMac, 300), isNull);
  });

  test('leaf walk test: blue 100, blue 500, cyan when the ACK is in time', () {
    tickAt(0, up(leafMac, SafrMsgType.event, code: SafrEventCode.manualTest));
    tickAt(50, ackDown(leafMac));
    expect(at(leafMac, 50), LedColor.blue); // "heard you"
    expect(at(leafMac, 300), LedColor.blue); // the MANUAL_TEST left
    expect(at(leafMac, 800), LedColor.cyan); // central confirmed
    expect(at(leafMac, 1200), isNull);
  });

  test('leaf walk test: no cyan when the ACK is later than 3 s', () {
    tickAt(0, up(leafMac, SafrMsgType.event, code: SafrEventCode.manualTest));
    tickAt(3100, ackDown(leafMac));
    expect(at(leafMac, 3200), isNull);
  });

  test('IDENTIFY blinks blue 1 s and keeps traffic pulses out', () {
    now = DateTime(2026, 1, 1);
    engine.identify(childMac, 3);
    tickAt(100, up(childMac, SafrMsgType.heartbeat));
    expect(at(childMac, 200), LedColor.blue);
    expect(at(childMac, 700), isNull); // off half
    expect(at(childMac, 1200), LedColor.blue);
    expect(at(childMac, 3100), isNull); // done, no queued tick
  });

  test('root: 250 ms green flash every 5 s, 4.5 s after a pulse ends', () {
    expect(at(rootMac, 100), LedColor.green);
    expect(at(rootMac, 400), isNull);
    expect(at(rootMac, 5100), LedColor.green);
    tickAt(6000, up(rootMac, SafrMsgType.event));
    expect(at(rootMac, 6400), LedColor.blue); // the role colour is off
    expect(at(rootMac, 10400), isNull);
    expect(at(rootMac, 11050), LedColor.green); // 6500 + 4500
  });

  test('board: magenta slow flash; child node: dark', () {
    expect(at(boardMac, 100), LedColor.magenta);
    expect(at(childMac, 100), isNull);
  });

  SafrTrafficTick alarmUp(String mac) => SafrTrafficTick(
        mac: mac,
        direction: SafrTrafficDirection.uplink,
        severity: 3,
        msgType: SafrMsgType.event,
        eventCode: SafrEventCode.smokeAlarm,
      );

  test('red follows the device: on while its ALARM re-announces arrive', () {
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2, alarm: true),
    ];
    tickAt(0, alarmUp(childMac));
    expect(at(childMac, 600), LedColor.red); // after the blue 500 ms
    tickAt(60000, alarmUp(childMac)); // re-announce (ALARM_RETX_MS)
    expect(at(childMac, 120000), LedColor.red);
  });

  test('device normalised (re-announces stopped): LED off, latch/badge kept',
      () {
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2, alarm: true),
    ];
    tickAt(0, alarmUp(childMac));
    expect(at(childMac, 69000), LedColor.red);
    expect(at(childMac, 71000), isNull);
    expect(find(childMac).alarmLatched, isTrue); // the ALARME label stays
  });

  test('Rearmar confirmed (latch cleared): LED off at once', () {
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2, alarm: true),
    ];
    tickAt(0, alarmUp(childMac));
    expect(at(childMac, 1000), LedColor.red);
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2),
    ];
    expect(at(childMac, 1100), isNull);
  });

  test('the ALARM frame arrives before the latch is written: still red', () {
    // The bug: the LED was redrawn between the frame and the DB write,
    // read "not latched" as "reset" and dropped the alarm for 60 s.
    tickAt(100000, alarmUp(childMac)); // not latched yet
    expect(at(childMac, 100010), LedColor.blue);
    expect(at(childMac, 100600),
        LedColor.red); // redraw in the gap: red, like the unit
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2, alarm: true),
    ];
    expect(at(childMac, 100700), LedColor.red); // latch written
  });

  test('latched before the app listened: red until one re-announce period', () {
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2, alarm: true),
    ];
    expect(at(childMac, 0), LedColor.red);
    expect(at(childMac, 69000), LedColor.red);
    expect(at(childMac, 71000), isNull); // no re-announce came: normalised
  });

  SafrTrafficTick heartbeat(String mac, int uptimeS) => SafrTrafficTick(
        mac: mac,
        direction: SafrTrafficDirection.uplink,
        severity: 0,
        msgType: SafrMsgType.heartbeat,
        uptimeS: uptimeS,
      );

  test('the unit reboots out of alarm: red clears on its first heartbeat', () {
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2, alarm: true),
    ];
    tickAt(0, alarmUp(childMac));
    tickAt(15000, heartbeat(childMac, 600)); // still up: still in alarm
    expect(at(childMac, 15200), LedColor.red);
    tickAt(20000, heartbeat(childMac, 3)); // booted at ~17 s, after the alarm
    expect(at(childMac, 20200), isNull);
    expect(find(childMac).alarmLatched, isTrue); // ALARME badge stays
    tickAt(25000, alarmUp(childMac)); // alarms again after the reboot
    expect(at(childMac, 25600), LedColor.red);
  });

  test('latched at app start, then the unit reboots: no red', () {
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(childMac, SafrNodeRole.node, 2, alarm: true),
    ];
    expect(at(childMac, 0), LedColor.red);
    tickAt(10000, heartbeat(childMac, 4));
    expect(at(childMac, 10200), isNull);
  });

  test('a leaf never shows the alarm red (its firmware has none)', () {
    nodes = [
      node(boardMac, SafrNodeRole.root, 0),
      node(leafMac, SafrNodeRole.leaf, 3, alarm: true),
    ];
    tickAt(0, alarmUp(leafMac));
    expect(at(leafMac, 1000), isNull);
  });

  test('an offline unit shows no LED (the app keeps its red look)', () {
    nodes = [node(rootMac, SafrNodeRole.root, 1, online: false)];
    tickAt(0, up(rootMac, SafrMsgType.event));
    expect(at(rootMac, 100), isNull);
    expect(engine.animating(find(rootMac)), isFalse);
  });

  test('the queue holds 8 pulses behind the lit one, the rest are dropped', () {
    for (var i = 0; i < 12; i++) {
      tickAt(0, up(childMac, SafrMsgType.event));
    }
    expect(at(childMac, 9 * 500 - 10), LedColor.blue); // 1 lit + 8 queued
    expect(at(childMac, 9 * 500 + 10), isNull);
  });
}
