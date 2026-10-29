import 'dart:convert';

import '../../../central/domain/safr/safr_product.dart';

/// Credentials printed on the device's factory sticker (written by
/// `tools/make_sticker.py`, POC-BRIEF.md §3/§4.1).
/// Format: {"id":"...","mac":"AA:BB:CC:DD:EE:FF","pop":"...",
///          "model":"SIOT-SIREN-01","family":"node"}
/// `model` (the product, reference §2.1) and `family` (its type: board /
/// node / leaf) ride on the QR since 2026-10-29 so the wizard can draw the
/// unit's real picture and name its type before the phone joins its setup
/// network. Both are optional: an older sticker has neither, and the unit
/// then says what it is on `GET /info`.
class DeviceQrPayload {
  final String id;
  final String mac;
  final String pop;

  /// The product's model string as printed, e.g. `SIOT-SIREN-01`; null on
  /// a sticker without it.
  final String? model;

  /// `board` / `node` / `leaf` as printed; null on a sticker without it.
  final String? family;

  const DeviceQrPayload({
    required this.id,
    required this.mac,
    required this.pop,
    this.model,
    this.family,
  });

  /// The catalogue entry for [model]; null without one or for a model this
  /// app does not know.
  SafrProduct? get product => SafrProduct.fromModel(model);

  /// The unit's type: the printed family, else the product's family, else
  /// [SafrProductFamily.unknown]. A sticker that prints both must agree;
  /// the printed family wins so a model this app does not know still shows
  /// its type.
  SafrProductFamily get productFamily {
    final printed = SafrProductFamily.fromName(family);
    if (printed != SafrProductFamily.unknown) return printed;
    return product?.family ?? SafrProductFamily.unknown;
  }

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
      final model = decoded['model'];
      final family = decoded['family'];
      return DeviceQrPayload(
        id: id,
        mac: mac,
        pop: pop,
        model: model is String && model.trim().isNotEmpty
            ? model.trim().toUpperCase()
            : null,
        family: family is String && family.trim().isNotEmpty
            ? family.trim().toLowerCase()
            : null,
      );
    } on FormatException {
      return null;
    }
  }
}
