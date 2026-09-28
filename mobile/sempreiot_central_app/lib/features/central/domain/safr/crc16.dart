import 'dart:typed_data';

/// CRC-16/CCITT-FALSE — poly 0x1021, init 0xFFFF, no reflection, no xorout.
/// Check value: safrCrc16("123456789" as bytes) == 0x29B1.
/// See docs/safr/protocol-safr-v3.md §5.
final Uint16List _table = _buildTable();

Uint16List _buildTable() {
  final t = Uint16List(256);
  for (var i = 0; i < 256; i++) {
    var crc = i << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
    t[i] = crc;
  }
  return t;
}

int safrCrc16(Uint8List data, [int start = 0, int? end]) {
  final stop = end ?? data.length;
  var crc = 0xFFFF;
  for (var i = start; i < stop; i++) {
    crc = ((crc << 8) ^ _table[((crc >> 8) ^ data[i]) & 0xFF]) & 0xFFFF;
  }
  return crc;
}
