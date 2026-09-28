import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_parser.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

SafrEncoder _nodeEncoder() => SafrEncoder(
      srcMac: safrMacToBytes('5A:46:52:00:00:01'),
      bootCtr: 0x0001,
    );

Uint8List _eventPayload({int type = 0x03, int code = 0x01, int devSeq = 7}) =>
    Uint8List.fromList([
      type, code, 0x68, 0x6E, 0x2F, 0x00, // ts 0x686E2F00
      0x05, 0x55, // pwr, batt 85
      0x10, 0x68, // smoke 4200
      0x02, 0x26, // temp 55.0
      0x2A, // hum 42
      0x00, 0x00, // no fault
      (devSeq >> 8) & 0xFF, devSeq & 0xFF, // DEV_SEQ (spec §6)
    ]);

void main() {
  group('SAFR v3 roundtrip', () {
    test('EVENT encode -> parse (encrypted, ack required)', () {
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(),
        ackRequired: true,
      );

      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isValid, isTrue, reason: '${parsed.error}');
      expect(parsed.ver, safrVer3);
      expect(parsed.systemId, safrDevSystemId);
      expect(parsed.msgType, SafrMsgType.event);
      expect(parsed.srcMac, '5A:46:52:00:00:01');
      expect(parsed.dstMac, 'FF:FF:FF:FF:FF:FF');
      expect(parsed.isEncrypted, isTrue);
      expect(parsed.ackRequired, isTrue);
      expect(parsed.isRetx, isFalse);

      final p = parsed.payload as SafrEventPayload;
      expect(p.eventType, SafrEventType.alarm);
      expect(p.eventCode, SafrEventCode.smokeAlarm);
      expect(p.eventType.severity, 3);
      expect(p.batteryPct, 85);
      expect(p.smokeRaw, 0x1068);
      expect(p.tempTenths, 550);
      expect(p.humidityPct, 42);
      expect(p.acOk, isTrue);
      expect(p.onBattery, isTrue);
      expect(p.devSeq, 7);
      expect(p.timestamp.millisecondsSinceEpoch ~/ 1000, 0x686E2F00);
    });

    test('F_RETX re-announcement flag survives the roundtrip (spec §7.2)', () {
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(),
        ackRequired: true,
        retx: true,
      );
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isRetx, isTrue);
      expect(parsed.ackRequired, isTrue);
    });

    test('HEARTBEAT roundtrip with n/a sentinels', () {
      final payload = Uint8List.fromList([
        0x68, 0x6E, 0x2F, 0x01, // ts
        0x00, 0x00, 0x0E, 0x10, // uptime 3600
        0x01, // pwr AC_OK
        0xFF, // battery n/a
        0x7F, 0xFF, // temp n/a
        0x7F, // rssi n/a (root)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // parent = central
        0x00, // layer 0
      ]);
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.heartbeat,
        payload: payload,
      );

      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isValid, isTrue, reason: '${parsed.error}');
      final p = parsed.payload as SafrHeartbeatPayload;
      expect(p.uptimeS, 3600);
      expect(p.batteryPct, isNull);
      expect(p.tempTenths, isNull);
      expect(p.rssiToParent, isNull);
      expect(p.parentMac, safrCentralMac);
      expect(p.layer, 0);
    });

    test('HEARTBEAT negative temperature and RSSI decode as signed', () {
      final payload = Uint8List.fromList([
        0x68, 0x6E, 0x2F, 0x01,
        0x00, 0x00, 0x00, 0x3C,
        0x04, // ON_BATTERY
        0x32, // 50%
        0xFF, 0x9C, // -100 => -10.0 °C
        0xBE, // -66 dBm
        0x5A, 0x46, 0x52, 0x00, 0x00, 0x02,
        0x02,
      ]);
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.heartbeat,
        payload: payload,
      );
      final p = parseSafrWireFrame(frame).payload as SafrHeartbeatPayload;
      expect(p.tempTenths, -100);
      expect(p.rssiToParent, -66);
      expect(p.layer, 2);
    });

    test('TOPOLOGY roundtrip with children', () {
      final payload = Uint8List.fromList([
        0x68, 0x6E, 0x2F, 0x02,
        0x00, // root
        0x00, // layer 0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // parent = central
        0x7F, // rssi n/a
        0x02, // 2 children
        0x5A, 0x46, 0x52, 0x00, 0x00, 0x02, 0xBE, // child 1, -66 dBm
        0x5A, 0x46, 0x52, 0x00, 0x00, 0x03, 0xC4, // child 2, -60 dBm
      ]);
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.topology,
        payload: payload,
      );
      final p = parseSafrWireFrame(frame).payload as SafrTopologyPayload;
      expect(p.role, SafrNodeRole.root);
      expect(p.children, hasLength(2));
      expect(p.children[0].mac, '5A:46:52:00:00:02');
      expect(p.children[0].rssi, -66);
      expect(p.children[1].rssi, -60);
    });

    test('ACK build -> parse', () {
      final frame = SafrEncoder().encode(
        msgType: SafrMsgType.ack,
        payload: SafrAckPayload.build(ackedMsgId: 0x1234),
        dstMac: safrMacToBytes('5A:46:52:00:00:01'),
      );
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.srcMac, safrCentralMac);
      final p = parsed.payload as SafrAckPayload;
      expect(p.ackedMsgId, 0x1234);
      expect(p.status, SafrAckStatus.ok);
    });

    test('COMMAND build -> parse (incl. LINK_CHECK and RESET)', () {
      for (final cmd in [
        SafrCommand.linkCheck,
        SafrCommand.reset,
        SafrCommand.identify,
      ]) {
        final frame = SafrEncoder().encode(
          msgType: SafrMsgType.command,
          payload: SafrCommandPayload.build(
              cmd: cmd, args: cmd == SafrCommand.identify ? [10] : const []),
          dstMac: safrMacToBytes('5A:46:52:00:00:05'),
          ackRequired: true,
        );
        final parsed = parseSafrWireFrame(frame);
        expect(parsed.ackRequired, isTrue);
        final p = parsed.payload as SafrCommandPayload;
        expect(p.cmdRaw, cmd.wire, reason: cmd.name);
      }
    });

    test('TIME_SYNC build -> parse', () {
      final now = DateTime.utc(2026, 7, 6, 12, 0, 0);
      final frame = SafrEncoder().encode(
        msgType: SafrMsgType.timeSync,
        payload: SafrTimeSyncPayload.build(
          utcNow: now,
          tzOffset: const Duration(hours: -3),
        ),
      );
      final p = parseSafrWireFrame(frame).payload as SafrTimeSyncPayload;
      expect(p.epoch, now.millisecondsSinceEpoch ~/ 1000);
      expect(p.tzOffsetQuarterHours, -12);
    });

    test('EVENT_LOG_REQ build -> parse (spec §7.8)', () {
      final frame = SafrEncoder().encode(
        msgType: SafrMsgType.eventLogReq,
        payload: SafrEventLogReqPayload.build(sinceJrnSeq: 0x00012345),
      );
      final p = parseSafrWireFrame(frame).payload as SafrEventLogReqPayload;
      expect(p.sinceJrnSeq, 0x00012345);
      expect(p.maxCount, 0);
    });

    test('EVENT_LOG_DATA roundtrip carries the original event (spec §7.9)',
        () {
      final inner = _eventPayload(devSeq: 42);
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.eventLogData,
        payload: SafrEventLogDataPayload.build(
          jrnSeq: 9,
          logFlags: safrLogFlagLast,
          origSrcMac: safrMacToBytes('5A:46:52:00:00:03'),
          eventPayload17: inner,
        ),
      );
      final p = parseSafrWireFrame(frame).payload as SafrEventLogDataPayload;
      expect(p.jrnSeq, 9);
      expect(p.isLast, isTrue);
      expect(p.isEmpty, isFalse);
      expect(p.origSrcMac, '5A:46:52:00:00:03');
      expect(p.event!.devSeq, 42);
      expect(p.event!.eventType, SafrEventType.alarm);
    });

    test('EVENT_LOG_DATA EMPTY marker parses without an event', () {
      final payload = Uint8List(SafrEventLogDataPayload.wireLength);
      payload[3] = 5; // jrnSeq = root's current top
      payload[4] = safrLogFlagLast | safrLogFlagEmpty;
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.eventLogData,
        payload: payload,
      );
      final p = parseSafrWireFrame(frame).payload as SafrEventLogDataPayload;
      expect(p.isEmpty, isTrue);
      expect(p.jrnSeq, 5);
      expect(p.event, isNull);
    });

    test('INSTALLATION build -> parse (spec §7.10, v3.1)', () {
      final frame = SafrEncoder().encode(
        msgType: SafrMsgType.installation,
        payload: SafrInstallationPayload.build(
          systemId: 0x1234,
          channel: 6,
          netSsid: 'SIOT-ABCD',
          name: 'Instalação Teste',
          enrolled: const [
            SafrEnrolledDevice(
              mac: '5A:46:52:00:00:02',
              name: 'Sirene 1',
              zone: 'Térreo',
            ),
            SafrEnrolledDevice(
              mac: '5A:46:52:00:00:03',
              name: 'Sirene 2',
              zone: '1º andar',
            ),
          ],
        ),
      );
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isValid, isTrue, reason: '${parsed.error}');
      final p = parsed.payload as SafrInstallationPayload;
      expect(p.systemId, 0x1234);
      expect(p.channel, 6);
      expect(p.netSsid, 'SIOT-ABCD');
      expect(p.name, 'Instalação Teste');
      expect(p.enrolled, hasLength(2));
      expect(p.enrolled[0].mac, '5A:46:52:00:00:02');
      expect(p.enrolled[0].name, 'Sirene 1');
      expect(p.enrolled[0].zone, 'Térreo');
      expect(p.enrolled[1].zone, '1º andar');
    });

    test('INSTALLATION build -> parse with no enrolled devices', () {
      final frame = SafrEncoder().encode(
        msgType: SafrMsgType.installation,
        payload: SafrInstallationPayload.build(
          systemId: 1,
          channel: 1,
          netSsid: 'SIOT-0001',
          name: 'Board A',
        ),
      );
      final p =
          parseSafrWireFrame(frame).payload as SafrInstallationPayload;
      expect(p.enrolled, isEmpty);
    });

    test('NAME_ANNOUNCE build -> parse (spec §7.11, v3.1)', () {
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.nameAnnounce,
        payload: SafrNameAnnouncePayload.build(
          name: 'Sirene 1',
          zone: 'Térreo',
        ),
      );
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isValid, isTrue, reason: '${parsed.error}');
      final p = parsed.payload as SafrNameAnnouncePayload;
      expect(p.name, 'Sirene 1');
      expect(p.zone, 'Térreo');
    });

    test('GET_INSTALLATION command build -> parse (spec §7.6, v3.1)', () {
      final frame = SafrEncoder().encode(
        msgType: SafrMsgType.command,
        payload: SafrCommandPayload.build(cmd: SafrCommand.getInstallation),
        ackRequired: true,
      );
      final p = parseSafrWireFrame(frame).payload as SafrCommandPayload;
      expect(p.cmdRaw, SafrCommand.getInstallation.wire);
      expect(p.cmdRaw, 0x10);
    });

    test('plaintext debug mode (F_ENC = 0) still parses and CRC-protects', () {
      final frame = _nodeEncoder().encode(
        msgType: SafrMsgType.event,
        payload: _eventPayload(),
        encrypt: false,
      );
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isValid, isTrue);
      expect(parsed.isEncrypted, isFalse);
      expect(parsed.payload, isA<SafrEventPayload>());

      final tampered = Uint8List.fromList(frame)..[32] ^= 0xFF;
      expect(parseSafrWireFrame(tampered).error, SafrWireError.crcFailed);
    });
  });

  group('SAFR v3 error taxonomy', () {
    Uint8List valid() => _nodeEncoder().encode(
          msgType: SafrMsgType.event,
          payload: _eventPayload(),
        );

    test('tampered ciphertext byte -> crcFailed (link corruption wins)', () {
      final f = Uint8List.fromList(valid())..[34] ^= 0x01;
      expect(parseSafrWireFrame(f).error, SafrWireError.crcFailed);
    });

    test('tampered tag with recomputed CRC -> authFailed', () {
      final f = Uint8List.fromList(valid());
      f[f.length - 4] ^= 0x01; // inside the CCM tag
      // Recompute CRC so only the crypto check can fail.
      _fixCrc(f);
      expect(parseSafrWireFrame(f).error, SafrWireError.authFailed);
    });

    test('wrong key -> authFailed', () {
      final f = valid();
      final wrongKey = Uint8List(16); // all zeros
      expect(
          parseSafrWireFrame(f, key: wrongKey).error, SafrWireError.authFailed);
    });

    test('tampered header (nonce counter) with fixed CRC -> authFailed', () {
      final f = Uint8List.fromList(valid());
      f[29] ^= 0x01; // MSG_CTR low byte — changes nonce AND AAD
      _fixCrc(f);
      expect(parseSafrWireFrame(f).error, SafrWireError.authFailed);
    });

    test('tampered SYSTEM_ID with fixed CRC -> authFailed (header is AAD)',
        () {
      final f = Uint8List.fromList(valid());
      f[8] ^= 0x01; // SYSTEM_ID low byte
      _fixCrc(f);
      // Still our expected id? No — but even without the expectation check,
      // the AAD no longer matches what was authenticated.
      expect(parseSafrWireFrame(f).error, SafrWireError.authFailed);
    });

    test('foreign SYSTEM_ID -> foreignSystem when expectation given', () {
      final f = valid();
      expect(parseSafrWireFrame(f, expectedSystemId: 0xBEEF).error,
          SafrWireError.foreignSystem);
    });

    test('truncated frame -> truncated', () {
      final f = valid();
      expect(
        parseSafrWireFrame(Uint8List.sublistView(f, 0, f.length - 5)).error,
        SafrWireError.truncated,
      );
    });

    test('unknown version byte -> badVersion', () {
      final f = Uint8List.fromList(valid())..[1] = 0x04;
      expect(parseSafrWireFrame(f).error, SafrWireError.badVersion);
    });

    test('failed frames still expose header fields for diagnostics', () {
      final f = Uint8List.fromList(valid())..[42] ^= 0xFF;
      final parsed = parseSafrWireFrame(f);
      expect(parsed.error, SafrWireError.crcFailed);
      expect(parsed.srcMac, '5A:46:52:00:00:01');
      expect(parsed.msgType, SafrMsgType.event);
    });
  });

  group('parseSafr facade', () {
    test('dispatches v3 frames', () {
      final f = _nodeEncoder()
          .encode(msgType: SafrMsgType.event, payload: _eventPayload());
      expect(parseSafr(f), isA<SafrWireResult>());
    });

    test('rejects non-SAFR bytes', () {
      expect(parseSafr(Uint8List.fromList([0x00, 0x01, 0x02])),
          isA<SafrInvalidResult>());
    });
  });
}

void _fixCrc(Uint8List f) {
  var crc = 0xFFFF;
  for (var i = 0; i < f.length - 2; i++) {
    crc ^= f[i] << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  f[f.length - 2] = (crc >> 8) & 0xFF;
  f[f.length - 1] = crc & 0xFF;
}
