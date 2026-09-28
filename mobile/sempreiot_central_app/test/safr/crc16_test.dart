import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/crc16.dart';

void main() {
  group('CRC-16/CCITT-FALSE', () {
    test('check value: "123456789" -> 0x29B1', () {
      final data = Uint8List.fromList(ascii.encode('123456789'));
      expect(safrCrc16(data), 0x29B1);
    });

    test('empty input -> init value 0xFFFF', () {
      expect(safrCrc16(Uint8List(0)), 0xFFFF);
    });

    test('single 0x00 byte', () {
      // Known CCITT-FALSE result for a single zero byte.
      expect(safrCrc16(Uint8List.fromList([0x00])), 0xE1F0);
    });

    test('range arguments restrict the window', () {
      final data = Uint8List.fromList([0xAA, ...ascii.encode('123456789'), 0xBB]);
      expect(safrCrc16(data, 1, data.length - 1), 0x29B1);
    });
  });
}
