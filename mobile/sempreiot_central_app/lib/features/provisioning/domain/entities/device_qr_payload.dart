import 'dart:convert';

/// Credentials printed on the device's factory sticker (written by
/// `tools/make_sticker.py`, POC-BRIEF.md §3/§4.1).
/// Format: {"id":"...","mac":"AA:BB:CC:DD:EE:FF","pop":"..."}
class DeviceQrPayload {
  final String id;
  final String mac;
  final String pop;

  const DeviceQrPayload({
    required this.id,
    required this.mac,
    required this.pop,
  });

  /// Null on anything that isn't a valid device sticker QR.
  static DeviceQrPayload? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is! Map<String, dynamic>) return null;
      final id = decoded['id'] as String?;
      final mac = decoded['mac'] as String?;
      final pop = decoded['pop'] as String?;
      if (id == null || id.isEmpty) return null;
      if (mac == null || mac.isEmpty) return null;
      if (pop == null || pop.isEmpty) return null;
      return DeviceQrPayload(id: id, mac: mac, pop: pop);
    } on FormatException {
      return null;
    }
  }
}
