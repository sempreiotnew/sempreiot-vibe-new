import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_parser.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/services/provisioning_crypto.dart';

Uint8List _hex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ]);

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

Map<String, dynamic> _fixture() => jsonDecode(
      File('test/fixtures/setinst_vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  group('SAFR v3.2 payload layouts (spec §7.6, §7.12–§7.15)', () {
    test('SET_INSTALLATION args / CODE round trip', () {
      final code = SafrInstallationCode(
        systemId: 0xBEEF,
        channel: 11,
        meshId: 0xEF,
        netSsid: 'SIOT-BEEF',
        netPsk: 'abcdefghijklmnop',
        safrPsk: Uint8List.fromList(List.generate(16, (i) => i)),
        name: 'Escola Bloco B',
      );
      final bytes = code.build();
      final back = SafrInstallationCode.parse(bytes)!;
      expect(back.systemId, 0xBEEF);
      expect(back.channel, 11);
      expect(back.meshId, 0xEF);
      expect(back.netSsid, 'SIOT-BEEF');
      expect(back.netPsk, 'abcdefghijklmnop');
      expect(back.safrPsk, List.generate(16, (i) => i));
      expect(back.name, 'Escola Bloco B');
      expect(SafrInstallationCode.parse(bytes.sublist(0, 20)), isNull);
    });

    test('SET_DEVICE, single-MAC and REPLACE args', () {
      final sd = const SafrSetDeviceArgs(
              mac: '5A:46:52:00:00:02', name: 'Sirene 1', zone: 'Térreo')
          .build();
      final back = SafrSetDeviceArgs.parse(sd)!;
      expect(back.mac, '5A:46:52:00:00:02');
      expect(back.name, 'Sirene 1');
      expect(back.zone, 'Térreo');

      expect(SafrMacArgs.parse(SafrMacArgs.build('5A:46:52:00:00:02')),
          '5A:46:52:00:00:02');
      final rep = SafrReplaceDeviceArgs.parse(SafrReplaceDeviceArgs.build(
          oldMac: '5A:46:52:00:00:02', newMac: '5A:46:52:00:00:09'))!;
      expect(rep.oldMac, '5A:46:52:00:00:02');
      expect(rep.newMac, '5A:46:52:00:00:09');
    });

    test('DEVICE_TABLE page round trip and flags', () {
      final page = SafrDeviceTablePayload.build(
        page: 2,
        pageCount: 3,
        total: 41,
        entries: const [
          SafrDeviceTableEntry(
            mac: '5A:46:52:00:00:02',
            role: SafrNodeRole.leaf,
            state: SafrDeviceState.retired,
            flags: SafrDeviceFlags.seenEver | SafrDeviceFlags.heardWhileRetired,
            lastSeenAgeS: 300,
            name: 'Detector 2º',
            zone: '2º andar',
          ),
        ],
      );
      final back = SafrDeviceTablePayload.parse(page)!;
      expect(back.page, 2);
      expect(back.pageCount, 3);
      expect(back.total, 41);
      expect(back.isLastPage, isFalse);
      final e = back.entries.single;
      expect(e.role, SafrNodeRole.leaf);
      expect(e.state, SafrDeviceState.retired);
      expect(e.seenEver, isTrue);
      expect(e.heardWhileRetired, isTrue);
      expect(e.pendingRename, isFalse);
      expect(e.lastSeenAgeS, 300);
      expect(e.name, 'Detector 2º');
      expect(e.zone, '2º andar');
    });

    test('ACK DETAIL byte and NAME_ANNOUNCE optional role', () {
      final ack = SafrAckPayload.parse(SafrAckPayload.build(
          ackedMsgId: 7,
          status: SafrAckStatus.error,
          detail: SafrAckDetail.notInSetupMode))!;
      expect(ack.detail, SafrAckDetail.notInSetupMode);
      // Pre-v3.2 ACK: byte 3 = 0 -> none.
      expect(SafrAckPayload.parse(Uint8List.fromList([0, 7, 0, 0]))!.detail,
          SafrAckDetail.none);

      final withRole = SafrNameAnnouncePayload.parse(SafrNameAnnouncePayload.build(
          name: 'Sirene', zone: 'T', role: SafrNodeRole.node))!;
      expect(withRole.role, SafrNodeRole.node);
      final without = SafrNameAnnouncePayload.parse(
          SafrNameAnnouncePayload.build(name: 'Sirene', zone: 'T'))!;
      expect(without.role, SafrNodeRole.unknown);
    });

    test('PARENT_PROBE / PARENT_OFFER', () {
      expect(SafrParentProbePayload.parse(SafrParentProbePayload.build(purpose: 1))!
          .isSurvey, isTrue);
      final offer = SafrParentOfferPayload.parse(SafrParentOfferPayload.build(
          purpose: 1, rssiSeen: -71, layer: null))!;
      expect(offer.rssiSeen, -71);
      expect(offer.layer, isNull);
    });

    test('unknown-to-old-parsers types still parse into the frame', () {
      final frame = SafrEncoder(
        srcMac: safrMacToBytes('7C:4F:AD:AE:85:90'),
        bootCtr: 1,
      ).encode(
        msgType: SafrMsgType.deviceTable,
        payload: SafrDeviceTablePayload.build(
            page: 1, pageCount: 1, total: 0, entries: const []),
      );
      final parsed = parseSafrWireFrame(frame);
      expect(parsed.isValid, isTrue, reason: '${parsed.error}');
      expect(parsed.payload, isA<SafrDeviceTablePayload>());
    });
  });

  group('Appendix A v3.2 vectors (test/fixtures/setinst_vectors.json)', () {
    test('setup-channel key derivation matches the fixture', () {
      final f = _fixture();
      final sc = f['setup_channel'] as Map<String, dynamic>;
      final key = ProvisioningCrypto.deriveSetupKey(
          id: sc['id'] as String, pop: sc['pop'] as String);
      expect(_toHex(key), sc['key_hex']);
    });

    test('V-SETINST frame is reproduced byte for byte and parses under the setup key',
        () {
      final f = _fixture();
      final sc = f['setup_channel'] as Map<String, dynamic>;
      final v = f['V-SETINST'] as Map<String, dynamic>;
      final key = _hex(sc['key_hex'] as String);

      final args = _hex(v['args_hex'] as String);
      final payload =
          SafrCommandPayload.build(cmd: SafrCommand.setInstallation, args: args);
      expect(_toHex(payload), v['payload_hex']);

      final frame = SafrEncoder(bootCtr: v['boot_ctr'] as int, systemId: 0, key: key)
          .encode(
        msgType: SafrMsgType.command,
        payload: payload,
        dstMac: safrMacToBytes(v['dst_mac'] as String),
        ackRequired: true,
        msgId: v['msg_id'] as int,
        msgCtr: v['msg_ctr'] as int,
      );
      expect(_toHex(frame), v['frame_hex']);

      final parsed = parseSafr(frame, key: key, expectedSystemId: 0);
      expect(parsed, isA<SafrWireResult>());
      final wf = (parsed as SafrWireResult).frame;
      expect(wf.isValid, isTrue, reason: '${wf.error}');
      expect(wf.systemId, 0);
      final cmd = wf.payload as SafrCommandPayload;
      expect(cmd.cmdRaw, SafrCommand.setInstallation.wire);
      expect(SafrInstallationCode.parse(cmd.args)!.systemId, 0x1234);
    });

    test('V-DEVTAB frame is reproduced byte for byte', () {
      final f = _fixture();
      final v = f['V-DEVTAB'] as Map<String, dynamic>;
      final payload = _hex(v['payload_hex'] as String);
      final table = SafrDeviceTablePayload.parse(payload)!;
      expect(table.total, 2);
      expect(table.entries[0].name, 'Sirene 1');
      expect(table.entries[1].state, SafrDeviceState.expected);
      expect(table.entries[1].lastSeenAgeS, isNull);

      final frame = SafrEncoder(
        srcMac: safrMacToBytes(v['src_mac'] as String),
        bootCtr: v['boot_ctr'] as int,
      ).encode(
        msgType: SafrMsgType.deviceTable,
        payload: payload,
        dstMac: safrCentralMacBytes,
        msgId: v['msg_id'] as int,
        msgCtr: v['msg_ctr'] as int,
      );
      expect(_toHex(frame), v['frame_hex']);
    });
  });
}
