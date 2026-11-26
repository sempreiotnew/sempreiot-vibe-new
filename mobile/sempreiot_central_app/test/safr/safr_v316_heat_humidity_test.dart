import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// Protocol 3.16 (§7.1.2, §7.1.5, §7.3): the two new EVENT_CODEs, the
/// SENSOR_WET fault bit / code, and HUMIDITY appended to the HEARTBEAT.
/// No firmware sends these yet: the frames are built here, as §7 lays
/// them out.

/// HEARTBEAT §7.3, cut to [length] bytes (20–24).
Uint8List heartbeat(
  int length, {
  int temp = 245,
  int dlHeard = 7,
  int dlMap = 0xFE,
  int boardRssi = 0xC4, // −60
  int humidity = 56,
}) =>
    Uint8List.fromList([
      0x68, 0x6E, 0x2F, 0x01, // TIMESTAMP
      0x00, 0x00, 0x0E, 0x10, // UPTIME_S 3600
      0x01, // PWR_FLAGS AC_OK
      0xFF, // BATTERY n/a
      (temp >> 8) & 0xFF, temp & 0xFF, // TEMP
      0xBE, // RSSI_TO_PARENT −66
      0x5A, 0x46, 0x52, 0x00, 0x00, 0x02, // PARENT_MAC
      0x02, // LAYER
      dlHeard, dlMap, boardRssi, humidity,
    ].sublist(0, length));

/// EVENT §7.1 (17 bytes).
Uint8List event({
  required int type,
  required int code,
  int temp = 0x7FFF,
  int humidity = 0xFF,
  int faultFlags = 0,
  int faultCode = 0,
  int devSeq = 7,
}) =>
    Uint8List.fromList([
      type, code,
      0x68, 0x6E, 0x2F, 0x00, // TIMESTAMP
      0x01, // PWR_FLAGS
      0xFF, // BATTERY n/a
      0xFF, 0xFF, // SMOKE n/a
      (temp >> 8) & 0xFF, temp & 0xFF,
      humidity,
      faultFlags, faultCode,
      (devSeq >> 8) & 0xFF, devSeq & 0xFF,
    ]);

void main() {
  group('EVENT_CODE 0x0D / 0x0E', () {
    test('HEAT_RISE_ALARM is an ALARM with its reading', () {
      final p = SafrEventPayload.parse(
          event(type: 0x03, code: 0x0D, temp: 412, humidity: 40))!;
      expect(p.eventType, SafrEventType.alarm);
      expect(p.eventCode, SafrEventCode.heatRiseAlarm);
      expect(p.eventCode.isHeat, isTrue);
      expect(p.tempTenths, 412);
      expect(p.humidityPct, 40);
      expect(p.eventType.severity, 3);
    });

    test('HEAT_ALARM stays the fixed-temperature alarm', () {
      final p =
          SafrEventPayload.parse(event(type: 0x03, code: 0x02, temp: 580))!;
      expect(p.eventCode, SafrEventCode.heatAlarm);
      expect(p.eventCode.isHeat, isTrue);
      expect(SafrEventCode.smokeAlarm.isHeat, isFalse);
    });

    test('SENSOR_WET is a TROUBLE with fault bit5', () {
      final p = SafrEventPayload.parse(event(
          type: 0x04,
          code: 0x0E,
          temp: 230,
          humidity: 100,
          faultFlags: 0x20,
          faultCode: 6))!;
      expect(p.eventType, SafrEventType.trouble);
      expect(p.eventCode, SafrEventCode.sensorWet);
      expect(p.faultFlags & fltSensorWet, isNot(0));
      expect(p.faultCode, safrFaultCodeSensorWet);
      expect(p.humidityPct, 100);
    });

    test('its RESTORE carries FAULT_CODE 6', () {
      final p = SafrEventPayload.parse(event(
          type: 0x01, code: 0x0B, temp: 230, humidity: 80, faultCode: 6))!;
      expect(p.eventType, SafrEventType.okRestore);
      expect(p.eventCode, SafrEventCode.restore);
      expect(p.faultCode, safrFaultCodeSensorWet);
      expect(p.faultFlags & fltSensorWet, 0);
    });

    test('the wire values', () {
      expect(SafrEventCode.fromWire(0x0D), SafrEventCode.heatRiseAlarm);
      expect(SafrEventCode.fromWire(0x0E), SafrEventCode.sensorWet);
      expect(SafrEventCode.fromWire(0x0F), SafrEventCode.unknown);
      expect(fltSensorWet, 1 << 5);
    });
  });

  group('HEARTBEAT lengths 20–24', () {
    test('20 bytes: nothing after LAYER', () {
      final p = SafrHeartbeatPayload.parse(heartbeat(20))!;
      expect(p.tempTenths, 245);
      expect(p.layer, 2);
      expect(p.dlHeard, isNull);
      expect(p.dlMap, isNull);
      expect(p.boardRssi, isNull);
      expect(p.humidityPct, isNull);
    });

    test('21 and 22 bytes: DL_HEARD, then DL_MAP', () {
      final a = SafrHeartbeatPayload.parse(heartbeat(21))!;
      expect(a.dlHeard, 7);
      expect(a.dlMap, isNull);
      expect(a.humidityPct, isNull);
      final b = SafrHeartbeatPayload.parse(heartbeat(22))!;
      expect(b.dlMap, 0xFE);
      expect(b.boardRssi, isNull);
      expect(b.humidityPct, isNull);
    });

    test('23 bytes (v3.11): BOARD_RSSI, no humidity', () {
      final p = SafrHeartbeatPayload.parse(heartbeat(23))!;
      expect(p.dlHeard, 7);
      expect(p.dlMap, 0xFE);
      expect(p.boardRssi, -60);
      expect(p.humidityPct, isNull);
    });

    test('24 bytes from a mains unit: everything', () {
      final p = SafrHeartbeatPayload.parse(heartbeat(24))!;
      expect(p.dlHeard, 7);
      expect(p.dlMap, 0xFE);
      expect(p.boardRssi, -60);
      expect(p.humidityPct, 56);
      expect(p.tempTenths, 245);
    });

    test('24 bytes from a battery unit: 20–22 say nothing', () {
      final p = SafrHeartbeatPayload.parse(heartbeat(24,
          dlHeard: 0xFF, dlMap: 0, boardRssi: 0x7F, humidity: 61))!;
      expect(p.dlHeard, isNull);
      expect(p.dlMap, isNull);
      expect(p.boardRssi, isNull);
      expect(p.humidityPct, 61);
    });

    test('HUMIDITY 0xFF is no humidity', () {
      final p = SafrHeartbeatPayload.parse(heartbeat(24, humidity: 0xFF))!;
      expect(p.humidityPct, isNull);
    });

    test('19 bytes is not a heartbeat; 25 reads the 24 it knows', () {
      expect(SafrHeartbeatPayload.parse(heartbeat(19)), isNull);
      final longer = Uint8List.fromList([...heartbeat(24), 0x00]);
      expect(SafrHeartbeatPayload.parse(longer)!.humidityPct, 56);
    });

    test('through the wire: encrypted frame, parsed back', () {
      final frame = SafrEncoder(
        srcMac: safrMacToBytes('5A:46:52:00:00:03'),
        bootCtr: 3,
      ).encode(msgType: SafrMsgType.heartbeat, payload: heartbeat(24));
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isValid, isTrue, reason: '${parsed.error}');
      expect((parsed.payload as SafrHeartbeatPayload).humidityPct, 56);
    });
  });
}
