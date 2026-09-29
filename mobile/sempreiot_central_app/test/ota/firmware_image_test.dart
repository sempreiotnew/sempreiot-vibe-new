import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_image.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';

import 'fake_firmware.dart';

void main() {
  group('the image says what it is', () {
    test('board', () {
      final h = FirmwareImageHeader.parse(
          fakeFirmware(project: 'sempreiot-board', version: '0.2.0'));
      expect(h.family, SafrProductFamily.board);
      expect(h.family.wire, 0x01);
      expect(h.version, '0.2.0');
      expect(h.projectName, 'sempreiot-board');
    });

    test('node', () {
      final h = FirmwareImageHeader.parse(
          fakeFirmware(project: 'sempreiot-node', version: '0.10.3-rc.1'));
      expect(h.family.wire, 0x02);
      expect(h.version, '0.10.3-rc.1');
    });

    test('leaf', () {
      final h = FirmwareImageHeader.parse(
          fakeFirmware(project: 'sempreiot-leaf', version: '1.0.0'));
      expect(h.family.wire, 0x03);
    });

    test('a header of 256 bytes is enough', () {
      final image = fakeFirmware(size: 256);
      expect(image.length, 256);
      expect(FirmwareImageHeader.parse(image).version, '0.2.0');
    });

    test('the fields sit where esp_app_desc_t puts them', () {
      final image = fakeFirmware(project: 'sempreiot-node', version: '0.2.0');
      // magic_word 0xABCD5432, little-endian, at 32
      expect(image.sublist(32, 36), [0x32, 0x54, 0xCD, 0xAB]);
      expect(ascii.decode(image.sublist(48, 53)), '0.2.0');
      expect(image[53], 0);
      expect(ascii.decode(image.sublist(80, 94)), 'sempreiot-node');
      expect(image[94], 0);
    });

    test('a field that fills its 32 bytes has no terminator', () {
      final name = 'x' * 32;
      expect(
        () => FirmwareImageHeader.parse(fakeFirmware(project: name)),
        throwsA(isA<FirmwareImageException>()
            .having((e) => e.message, 'message', contains('outro produto'))),
      );
    });
  });

  group('a file that is refused', () {
    void refused(Uint8List image, String because) {
      expect(
        () => FirmwareImageHeader.parse(image),
        throwsA(isA<FirmwareImageException>()
            .having((e) => e.message, 'message', contains(because))),
      );
    }

    test('too short', () {
      refused(Uint8List(0), 'pequeno demais');
      refused(fakeFirmware().sublist(0, 111), 'pequeno demais');
    });

    test('wrong magic', () {
      refused(fakeFirmware()..[32] = 0x33, 'não é um firmware');
      refused(Uint8List(4096), 'não é um firmware');
      // big-endian magic is not the magic
      final swapped = fakeFirmware()
        ..setRange(32, 36, [0xAB, 0xCD, 0x54, 0x32]);
      refused(swapped, 'não é um firmware');
    });

    test('another project', () {
      refused(fakeFirmware(project: 'hello_world'), 'outro produto');
      refused(fakeFirmware(project: 'sempreiot-boardx'), 'outro produto');
      refused(fakeFirmware(project: 'Sempreiot-Board'), 'outro produto');
      refused(fakeFirmware(project: ''), 'não diz de que produto');
    });

    test('no version, or one that does not fit the wire', () {
      refused(fakeFirmware(version: ''), 'não tem versão');
      refused(fakeFirmware(version: '0.2.0-${'d' * 19}'), '24 caracteres');
      expect(
          FirmwareImageHeader.parse(fakeFirmware(version: '0.2.0-${'d' * 18}'))
              .version
              .length,
          24);
    });

    test('a version that is not text', () {
      final image = fakeFirmware()..[49] = 0x07;
      refused(image, 'não tem versão');
    });
  });

  group('FirmwareFile', () {
    FirmwareFile file(int size) {
      final bytes = fakeFirmware(size: size);
      return FirmwareFile(
        name: 'f.bin',
        bytes: bytes,
        header: FirmwareImageHeader.parse(bytes),
        sha256: Uint8List(32),
      );
    }

    test('chunks of 4096, the last one shorter', () {
      final f = file(4096 * 3 + 100);
      expect(f.chunkCount, 4);
      expect(f.chunk(0).length, 4096);
      expect(f.chunk(2).length, 4096);
      expect(f.chunk(3).length, 100);
      expect(f.chunk(1).first, f.bytes[4096]);
      expect(f.chunk(3).last, f.bytes.last);
      expect(f.bytesBefore(0), 0);
      expect(f.bytesBefore(3), 4096 * 3);
      expect(f.bytesBefore(4), f.size);
    });

    test('a file of whole chunks has no short one', () {
      final f = file(4096 * 2);
      expect(f.chunkCount, 2);
      expect(f.chunk(1).length, 4096);
    });

    test('the short SHA-256', () {
      final bytes = fakeFirmware();
      final f = FirmwareFile(
        name: 'f.bin',
        bytes: bytes,
        header: FirmwareImageHeader.parse(bytes),
        sha256: Uint8List.fromList([for (var i = 0; i < 32; i++) i]),
      );
      expect(f.sha256Hex.length, 64);
      expect(f.sha256Short, '00010203…1c1d1e1f');
    });
  });
}
