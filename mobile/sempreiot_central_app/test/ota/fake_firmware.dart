import 'dart:convert';
import 'dart:typed_data';

/// A file that looks like an ESP-IDF application image where it matters to
/// the tablet: `esp_app_desc_t` at offset 32 (magic, version at 48,
/// project_name at 80). The rest is a pattern that changes from chunk to
/// chunk, so a chunk written in the wrong place shows.
Uint8List fakeFirmware({
  String project = 'sempreiot-board',
  String version = '0.2.0',
  int size = 4096,
}) {
  final image = Uint8List(size);
  for (var i = 0; i < size; i++) {
    image[i] = (i * 31 + (i >> 12) * 7 + 5) & 0xFF;
  }
  image[0] = 0xE9; // esp_image_header_t.magic
  image.fillRange(32, 112, 0);
  // magic_word 0xABCD5432, little-endian
  image.setRange(32, 36, [0x32, 0x54, 0xCD, 0xAB]);
  void field(int offset, String text) {
    final b = ascii.encode(text);
    image.setRange(offset, offset + (b.length > 32 ? 32 : b.length), b);
  }

  field(48, version);
  field(80, project);
  return image;
}
