import 'dart:typed_data';

/// CRC-32 (IEEE 802.3: reflected, polynomial 0xEDB88320, init and final XOR
/// 0xFFFFFFFF) of the raw bytes that follow an OTA_PUSH_CHUNK frame
/// (docs/safr/protocol-safr-v3.md §13.3). Check value:
/// `otaCrc32(ascii("123456789")) == 0xCBF43926`; of nothing, `0`.
///
/// Mirrors `siot_ota_crc32` (firmware/components/core/siot_ota_proto).
int otaCrc32(List<int> data, [int start = 0, int? end]) {
  final stop = end ?? data.length;
  var crc = 0xFFFFFFFF;
  for (var i = start; i < stop; i++) {
    crc = _table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final Uint32List _table = _buildTable();

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var bit = 0; bit < 8; bit++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}
