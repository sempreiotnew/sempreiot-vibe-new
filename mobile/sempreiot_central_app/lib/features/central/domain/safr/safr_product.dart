/// Product catalogue (SAFR v3.5): the 16-bit PRODUCT code a unit reports in
/// NAME_ANNOUNCE (spec §7.11) and the board mirrors in DEVICE_TABLE (§7.12).
///
/// High byte = family (the firmware image), low byte = product within the
/// family. The catalogue is a contract: a code is never reused or renumbered.
/// `0x0000` = unknown / not reported (firmware older than v3.5).
library;

/// The firmware image a product runs (PRODUCT high byte).
enum SafrProductFamily {
  board(0x01, 'placa'),
  node(0x02, 'rede elétrica'),
  leaf(0x03, 'bateria'),
  unknown(0x00, '');

  const SafrProductFamily(this.wire, this.label);
  final int wire;

  /// pt-BR, lower case; empty for [unknown].
  final String label;

  static SafrProductFamily fromWire(int v) => values.firstWhere(
        (e) => e.wire == v && e != SafrProductFamily.unknown,
        orElse: () => SafrProductFamily.unknown,
      );

  /// Family of a PRODUCT code (its high byte).
  static SafrProductFamily ofCode(int code) => fromWire((code >> 8) & 0xFF);
}

/// PRODUCT value meaning "unknown / not reported".
const safrProductUnknown = 0x0000;

/// Longest firmware version string on the wire (FW_LEN, spec §7.11/§7.12).
const safrFwVersionMaxLen = 24;

/// One product: a catalogue entry, or a code this app does not know yet
/// (kept and shown as such — a newer unit on an older app).
class SafrProduct {
  const SafrProduct._(this.code, this.model, this.label);

  /// The PRODUCT code, 0x0001..0xFFFF.
  final int code;

  /// Model string printed on the unit, e.g. `SIOT-SIREN-01`; null when the
  /// code is not in the catalogue.
  final String? model;

  /// pt-BR name for the UI; "Produto desconhecido 0x0206" when not in the
  /// catalogue.
  final String label;

  bool get isKnown => model != null;

  /// From the high byte; [SafrProductFamily.unknown] when that is not
  /// 0x01/0x02/0x03.
  SafrProductFamily get family => SafrProductFamily.ofCode(code);

  /// `0x0201`.
  String get codeHex => safrProductCodeHex(code);

  /// What the "Produto" fact shows: "Sirene · SIOT-SIREN-01"; for a code
  /// outside the catalogue, the label plus the family when the high byte
  /// names one ("Produto desconhecido 0x0206 · rede elétrica").
  String get display {
    if (model != null) return '$label · $model';
    final f = family;
    return f == SafrProductFamily.unknown ? label : '$label · ${f.label}';
  }

  /// Null for null / 0x0000 (not reported); otherwise the catalogue entry or
  /// an unknown-product placeholder that keeps the code.
  static SafrProduct? fromCode(int? code) {
    if (code == null) return null;
    final c = code & 0xFFFF;
    if (c == safrProductUnknown) return null;
    return _byCode[c] ??
        SafrProduct._(c, null, 'Produto desconhecido ${safrProductCodeHex(c)}');
  }

  /// The catalogue entry for a model string as the unit reports it on its
  /// setup network (`/info.model`), e.g. `SIOT-SIREN-01`; null when the
  /// model is empty or not in the catalogue.
  static SafrProduct? fromModel(String? model) {
    if (model == null || model.isEmpty) return null;
    final m = model.trim().toUpperCase();
    for (final p in catalogue) {
      if (p.model == m) return p;
    }
    return null;
  }

  /// Every catalogue entry, in code order.
  static const List<SafrProduct> catalogue = [
    SafrProduct._(0x0100, 'SIOT-BOARD-01', 'Central (placa)'),
    SafrProduct._(0x0201, 'SIOT-SIREN-01', 'Sirene'),
    SafrProduct._(0x0202, 'SIOT-PBS-01', 'Acionador manual'),
    SafrProduct._(0x0203, 'SIOT-IO-01', 'Módulo de E/S'),
    SafrProduct._(0x0204, 'SIOT-REPEATER-01', 'Repetidor'),
    SafrProduct._(
        0x0205, 'SIOT-SMOKE-AC-01', 'Detector de fumaça (rede elétrica)'),
    SafrProduct._(
        0x02FF, 'SIOT-NODE-01', 'Unidade de bancada (rede elétrica)'),
    SafrProduct._(0x0301, 'SIOT-SMOKE-01', 'Detector de fumaça (bateria)'),
    SafrProduct._(0x0302, 'SIOT-HEAT-01', 'Detector de temperatura (bateria)'),
    SafrProduct._(0x03FF, 'SIOT-LEAF-01', 'Unidade de bancada (bateria)'),
  ];

  static final Map<int, SafrProduct> _byCode = {
    for (final p in catalogue) p.code: p,
  };

  @override
  bool operator ==(Object other) => other is SafrProduct && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'SafrProduct($codeHex, ${model ?? '?'})';
}

/// `0x0206` — four upper-case hex digits.
String safrProductCodeHex(int code) =>
    '0x${(code & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0')}';
