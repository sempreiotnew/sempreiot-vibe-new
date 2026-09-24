// Prints the SAFR v3.2 lifecycle vectors (docs/safr/protocol-safr-v3.md
// Appendix A: V-SETINST, V-DEVTAB) as JSON for test/fixtures/setinst_vectors.json,
// replayed by test/safr/safr_v32_roundtrip_test.dart and the firmware host test.
// Run: dart run tool/print_setinst_vectors.dart > test/fixtures/setinst_vectors.json
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:pointycastle/export.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

void main() {
  const id = 'dev-00000001';
  const pop = '0123456789ABCDEF';
  // Same derivation as ProvisioningCrypto.deriveSetupKey (that file imports
  // flutter/foundation, which `dart run` cannot load).
  final hkdf = HKDFKeyDerivator(SHA256Digest())
    ..init(HkdfParameters(
      Uint8List.fromList(utf8.encode(pop)),
      16,
      Uint8List.fromList(utf8.encode(id)),
      Uint8List.fromList(utf8.encode('siot-setinst-v1')),
    ));
  final setupKey = Uint8List(16);
  hkdf.deriveKey(null, 0, setupKey, 0);

  final code = SafrInstallationCode(
    systemId: 0x1234,
    channel: 6,
    meshId: 0x34,
    netSsid: 'SIOT-1234',
    netPsk: 'QR2heszWr0mJjaDd',
    safrPsk: Uint8List.fromList([
      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, //
      0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    ]),
    name: 'Galpao 2',
  );
  final setInstArgs = code.build();
  final setInstPayload =
      SafrCommandPayload.build(cmd: SafrCommand.setInstallation, args: setInstArgs);

  // Setup channel: SYSTEM_ID 0x0000, key from the board sticker, central MAC.
  final setupEnc = SafrEncoder(bootCtr: 0x0001, systemId: 0x0000, key: setupKey);
  final setInstFrame = setupEnc.encode(
    msgType: SafrMsgType.command,
    payload: setInstPayload,
    dstMac: safrMacToBytes('7C:4F:AD:AE:85:90'),
    ackRequired: true,
    msgId: 1,
    msgCtr: 1,
  );

  final devtab = SafrDeviceTablePayload.build(
    page: 1,
    pageCount: 1,
    total: 2,
    entries: const [
      SafrDeviceTableEntry(
        mac: '5A:46:52:00:00:02',
        role: SafrNodeRole.node,
        state: SafrDeviceState.online,
        flags: SafrDeviceFlags.seenEver | SafrDeviceFlags.annotated,
        lastSeenAgeS: 12,
        name: 'Sirene 1',
        zone: 'Terreo',
      ),
      SafrDeviceTableEntry(
        mac: '5A:46:52:00:00:03',
        role: SafrNodeRole.unknown,
        state: SafrDeviceState.expected,
        flags: 0,
        lastSeenAgeS: null,
        name: 'Detector corredor',
        zone: '1 andar',
      ),
    ],
  );
  // Board -> central on the installation key (dev key here, SYSTEM_ID 0x5346).
  final boardEnc = SafrEncoder(
    srcMac: safrMacToBytes('7C:4F:AD:AE:85:90'),
    bootCtr: 0x0001,
  );
  final devtabFrame = boardEnc.encode(
    msgType: SafrMsgType.deviceTable,
    payload: devtab,
    dstMac: safrCentralMacBytes,
    msgId: 2,
    msgCtr: 2,
  );

  final out = {
    'setup_channel': {
      'id': id,
      'pop': pop,
      'info': 'siot-setinst-v1',
      'key_hex': hex(setupKey),
    },
    'V-SETINST': {
      'system_id': 0x0000,
      'src_mac': '00:00:00:00:00:01',
      'dst_mac': '7C:4F:AD:AE:85:90',
      'boot_ctr': 1,
      'msg_id': 1,
      'msg_ctr': 1,
      'flags': 0x03,
      'args_hex': hex(setInstArgs),
      'payload_hex': hex(setInstPayload),
      'frame_hex': hex(setInstFrame),
    },
    'V-DEVTAB': {
      'system_id': 0x5346,
      'key_hex': '25118BA1DD19B84509DF36E9416B8DBE',
      'src_mac': '7C:4F:AD:AE:85:90',
      'dst_mac': '00:00:00:00:00:01',
      'boot_ctr': 1,
      'msg_id': 2,
      'msg_ctr': 2,
      'flags': 0x01,
      'payload_hex': hex(devtab),
      'frame_hex': hex(devtabFrame),
    },
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
}
