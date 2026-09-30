part of 'safr_v2_payloads.dart';

// ── v3.5 firmware update: the rollout (docs/safr/protocol-safr-v3.md §13.4,
// §13.6) ─────────────────────────────────────────────────────────────────────
//
// What the tablet says to the board to steer a rollout (OTA_CONTROL,
// GET_ROLLOUT), what the board says back (OTA_ROLLOUT) and what every unit
// says on its way (OTA_STATUS, OTA_RESULT — relayed unchanged by the board).
// Byte layouts mirror firmware/components/core/siot_ota_proto and are
// asserted against its host-test vectors in
// test/ota/safr_ota_rollout_codec_test.dart. All integers big-endian.

/// Longest zone of an OTA_CONTROL zone filter, in bytes (`SIOT_OTA_ZONE_MAX`).
const safrOtaZoneMaxLen = 16;

/// `AGE_S` of a rollout entry that never changed.
const safrOtaAgeNever = 0xFFFF;

/// A unit's `STATE` in OTA_STATUS and in a rollout entry (§13.4).
enum SafrOtaUnitState {
  waiting(0),
  offered(1),
  downloading(2),
  verifying(3),
  rebooting(4),
  selfTest(5),
  done(6),
  failed(7),
  skipped(8);

  const SafrOtaUnitState(this.wire);
  final int wire;

  static SafrOtaUnitState? fromWire(int v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }

  /// The unit has the offer and the matter is not settled: for this long it
  /// is UPDATING, not missing (§13.4 `DEADLINE_S`).
  bool get active => switch (this) {
        SafrOtaUnitState.offered ||
        SafrOtaUnitState.downloading ||
        SafrOtaUnitState.verifying ||
        SafrOtaUnitState.rebooting ||
        SafrOtaUnitState.selfTest =>
          true,
        _ => false,
      };

  /// Nothing more happens to this unit in this rollout.
  bool get settled => switch (this) {
        SafrOtaUnitState.done ||
        SafrOtaUnitState.failed ||
        SafrOtaUnitState.skipped =>
          true,
        _ => false,
      };
}

/// The rollout's `STATE` in the OTA_ROLLOUT header (§13.6).
enum SafrOtaRolloutState {
  /// No rollout, nothing stored.
  idle(0),

  /// An image is stored on the board and no rollout was started.
  staged(1),
  rolling(2),
  paused(3),
  done(4),

  /// It ended and some unit failed.
  partial(5);

  const SafrOtaRolloutState(this.wire);
  final int wire;

  static SafrOtaRolloutState? fromWire(int v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }

  /// Units are being updated, or will be when the operator says `resume`.
  bool get running =>
      this == SafrOtaRolloutState.rolling ||
      this == SafrOtaRolloutState.paused;

  bool get ended =>
      this == SafrOtaRolloutState.done || this == SafrOtaRolloutState.partial;
}

/// `ACTION` of OTA_CONTROL (§13.6).
enum SafrOtaAction {
  start(1),
  pause(2),
  resume(3),
  abort(4);

  const SafrOtaAction(this.wire);
  final int wire;

  static SafrOtaAction? fromWire(int v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

/// `FILTER` of OTA_CONTROL (§13.6): which units of the family a rollout
/// reaches.
enum SafrOtaFilterKind {
  all(0),
  product(1),
  zone(2),
  unit(3);

  const SafrOtaFilterKind(this.wire);
  final int wire;

  static SafrOtaFilterKind? fromWire(int v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

/// The filter of a rollout with its data.
class SafrOtaFilter {
  const SafrOtaFilter.all()
      : kind = SafrOtaFilterKind.all,
        product = safrProductUnknown,
        zone = '',
        mac = '';

  /// One product of the family: "only the sirens" = `0x0201`.
  const SafrOtaFilter.product(this.product)
      : kind = SafrOtaFilterKind.product,
        zone = '',
        mac = '';

  const SafrOtaFilter.zone(this.zone)
      : kind = SafrOtaFilterKind.zone,
        product = safrProductUnknown,
        mac = '';

  /// One unit, by its MAC (`AA:BB:CC:DD:EE:FF`); never broadcast.
  const SafrOtaFilter.unit(this.mac)
      : kind = SafrOtaFilterKind.unit,
        product = safrProductUnknown,
        zone = '';

  final SafrOtaFilterKind kind;
  final int product;
  final String zone;
  final String mac;

  @override
  bool operator ==(Object other) =>
      other is SafrOtaFilter &&
      other.kind == kind &&
      other.product == product &&
      other.zone == zone &&
      other.mac == mac;

  @override
  int get hashCode => Object.hash(kind, product, zone, mac);

  @override
  String toString() => switch (kind) {
        SafrOtaFilterKind.all => 'all',
        SafrOtaFilterKind.product => 'product ${safrProductCodeHex(product)}',
        SafrOtaFilterKind.zone => 'zone "$zone"',
        SafrOtaFilterKind.unit => 'unit $mac',
      };
}

const _broadcastMac = 'FF:FF:FF:FF:FF:FF';

/// ARGS of `COMMAND 0x1D` OTA_CONTROL, tablet → board, `F_ACK_REQ`:
/// `ACTION u8 ‖ FAMILY u8 ‖ FILTER u8 ‖ filter data` — nothing for `all`,
/// `PRODUCT u16`, `ZONE_LEN u8 ‖ ZONE` or `MAC[6]` (§13.6).
class SafrOtaControlArgs {
  const SafrOtaControlArgs({
    required this.action,
    required this.family,
    this.filter = const SafrOtaFilter.all(),
  });

  final SafrOtaAction action;

  /// 0x01 board · 0x02 node · 0x03 leaf: which stored image.
  final int family;
  final SafrOtaFilter filter;

  Uint8List build() {
    final out = <int>[action.wire, family & 0xFF, filter.kind.wire];
    switch (filter.kind) {
      case SafrOtaFilterKind.all:
        break;
      case SafrOtaFilterKind.product:
        out
          ..add((filter.product >> 8) & 0xFF)
          ..add(filter.product & 0xFF);
      case SafrOtaFilterKind.zone:
        out.addAll(_str(filter.zone, safrOtaZoneMaxLen));
      case SafrOtaFilterKind.unit:
        out.addAll(safrMacToBytes(filter.mac));
    }
    return Uint8List.fromList(out);
  }

  /// Null = short, long or out of range, by the rules of the board
  /// (`siot_ota_control_decode`): a product of another family, an empty
  /// zone and the broadcast address are refused.
  static SafrOtaControlArgs? parse(Uint8List p) {
    if (p.length < 3) return null;
    final action = SafrOtaAction.fromWire(p[0]);
    final family = p[1];
    final kind = SafrOtaFilterKind.fromWire(p[2]);
    if (action == null || kind == null || !_otaFamilyOk(family)) return null;
    var off = 3;
    SafrOtaFilter filter;
    switch (kind) {
      case SafrOtaFilterKind.all:
        filter = const SafrOtaFilter.all();
      case SafrOtaFilterKind.product:
        if (off + 2 > p.length) return null;
        final product = (p[off] << 8) | p[off + 1];
        off += 2;
        if (product == safrProductUnknown || (product >> 8) != family) {
          return null;
        }
        filter = SafrOtaFilter.product(product);
      case SafrOtaFilterKind.zone:
        if (off >= p.length) return null;
        final n = p[off];
        if (n == 0 || n > safrOtaZoneMaxLen || off + 1 + n > p.length) {
          return null;
        }
        final String zone;
        try {
          zone = utf8.decode(p.sublist(off + 1, off + 1 + n));
        } on FormatException {
          return null;
        }
        off += 1 + n;
        filter = SafrOtaFilter.zone(zone);
      case SafrOtaFilterKind.unit:
        if (off + 6 > p.length) return null;
        final mac = safrMacToString(p.sublist(off, off + 6));
        off += 6;
        if (mac == _broadcastMac) return null;
        filter = SafrOtaFilter.unit(mac);
    }
    if (off != p.length) return null;
    return SafrOtaControlArgs(action: action, family: family, filter: filter);
  }
}

/// ARGS of `COMMAND 0x1C` GET_ROLLOUT: `PAGE u8`, `0` = all pages (§13.6).
abstract final class SafrGetRolloutArgs {
  static Uint8List build({int page = 0}) => Uint8List.fromList([page & 0xFF]);

  static int? parse(Uint8List args) => args.isEmpty ? null : args[0];
}

/// Reads `VER_LEN ‖ VERSION` at [off]. Null = past the end, too long or not
/// printable ASCII; otherwise the version and the offset behind it.
({String version, int next})? _readOtaVersionAt(Uint8List p, int off) {
  if (off >= p.length) return null;
  final n = p[off];
  if (n > safrFwVersionMaxLen || off + 1 + n > p.length) return null;
  final bytes = p.sublist(off + 1, off + 1 + n);
  if (bytes.any((c) => c < 0x20 || c > 0x7E)) return null;
  return (version: ascii.decode(bytes), next: off + 1 + n);
}

/// One unit of a rollout: `MAC[6] ‖ PRODUCT u16 ‖ STATE u8 ‖ PERCENT u8 ‖
/// ATTEMPTS u8 ‖ REASON u8 ‖ AGE_S u16 ‖ VER_LEN u8 ‖ VERSION` (§13.6), 15
/// to 39 bytes.
class SafrOtaRolloutEntry {
  const SafrOtaRolloutEntry({
    required this.mac,
    required this.productCode,
    required this.state,
    this.percent = 0,
    this.attempts = 0,
    this.reasonRaw = 0,
    this.ageS,
    this.version = '',
  });

  final String mac;
  final int productCode;
  final SafrOtaUnitState state;

  /// 0…100.
  final int percent;

  /// Offers made to this unit in this rollout.
  final int attempts;
  final int reasonRaw;

  /// Seconds since this entry last changed; null = never (`0xFFFF`).
  final int? ageS;

  /// What the unit runs now; empty = the board does not know.
  final String version;

  SafrOtaReason get reason => SafrOtaReason.fromWire(reasonRaw);

  static const minLength = 6 + 2 + 4 + 2 + 1;

  int get wireLength => minLength + ascii.encode(version).length;

  List<int> encode() {
    final age = ageS ?? safrOtaAgeNever;
    return [
      ...safrMacToBytes(mac),
      (productCode >> 8) & 0xFF,
      productCode & 0xFF,
      state.wire,
      percent > 100 ? 100 : percent,
      attempts & 0xFF,
      reasonRaw & 0xFF,
      (age >> 8) & 0xFF,
      age & 0xFF,
      ..._otaVersion(version),
    ];
  }

  /// The entry at [off] and the offset behind it; null = short or out of
  /// range (`siot_ota_rollout_entry_decode`).
  static ({SafrOtaRolloutEntry entry, int next})? decodeAt(
      Uint8List p, int off) {
    if (p.length - off < minLength) return null;
    final state = SafrOtaUnitState.fromWire(p[off + 8]);
    final percent = p[off + 9];
    final version = _readOtaVersionAt(p, off + 14);
    if (state == null || percent > 100 || version == null) return null;
    final age = (p[off + 12] << 8) | p[off + 13];
    return (
      entry: SafrOtaRolloutEntry(
        mac: safrMacToString(p.sublist(off, off + 6)),
        productCode: (p[off + 6] << 8) | p[off + 7],
        state: state,
        percent: percent,
        attempts: p[off + 10],
        reasonRaw: p[off + 11],
        ageS: age == safrOtaAgeNever ? null : age,
        version: version.version,
      ),
      next: version.next,
    );
  }
}

/// OTA_ROLLOUT — `MSG_TYPE 0x15`, board → tablet, paged like DEVICE_TABLE:
/// `PAGE u8 ‖ PAGE_COUNT u8 ‖ TOTAL u16 ‖ COUNT u8 ‖ STATE u8 ‖ FAMILY u8 ‖
/// VER_LEN u8 ‖ TARGET`, then `COUNT` entries (§13.6).
///
/// `STATE` staged with `TOTAL` 0 = the board holds the image of `FAMILY`,
/// version `TARGET`, and no rollout was started: how the tablet learns what
/// the board holds.
class SafrOtaRolloutPayload extends SafrV2Payload {
  const SafrOtaRolloutPayload({
    required this.page,
    required this.pageCount,
    required this.total,
    required this.state,
    required this.family,
    required this.target,
    this.entries = const [],
  });

  /// 1-based.
  final int page;
  final int pageCount;

  /// Units in the rollout, over all pages.
  final int total;
  final SafrOtaRolloutState state;

  /// As it came; [productFamily] names it.
  final int family;

  /// The version being rolled out (or stored).
  final String target;
  final List<SafrOtaRolloutEntry> entries;

  SafrProductFamily get productFamily => SafrProductFamily.fromWire(family);

  bool get isLastPage => page >= pageCount;

  static const minLength = 7 + 1;

  Uint8List build() {
    final out = <int>[
      page & 0xFF,
      pageCount & 0xFF,
      (total >> 8) & 0xFF,
      total & 0xFF,
      entries.length & 0xFF,
      state.wire,
      family & 0xFF,
      ..._otaVersion(target),
    ];
    for (final e in entries) {
      out.addAll(e.encode());
    }
    return Uint8List.fromList(out);
  }

  /// Null = a header or an entry that is short or out of range, fewer
  /// entries than `COUNT` says, or bytes behind the last one.
  static SafrOtaRolloutPayload? parse(Uint8List p) {
    if (p.length < minLength) return null;
    final page = p[0];
    final pageCount = p[1];
    final count = p[4];
    final state = SafrOtaRolloutState.fromWire(p[5]);
    final target = _readOtaVersionAt(p, 7);
    if (state == null || target == null) return null;
    if (page == 0 || page > pageCount) return null;
    var off = target.next;
    final entries = <SafrOtaRolloutEntry>[];
    for (var i = 0; i < count; i++) {
      final e = SafrOtaRolloutEntry.decodeAt(p, off);
      if (e == null) return null;
      entries.add(e.entry);
      off = e.next;
    }
    if (off != p.length) return null;
    return SafrOtaRolloutPayload(
      page: page,
      pageCount: pageCount,
      total: (p[2] << 8) | p[3],
      state: state,
      family: p[6],
      target: target.version,
      entries: entries,
    );
  }
}

/// OTA_STATUS — `MSG_TYPE 0x13`, unit → board, relayed to the tablet:
/// `STATE u8 ‖ PERCENT u8`. On every state change and every 10 % while
/// downloading; never acknowledged (§13.4).
class SafrOtaStatusPayload extends SafrV2Payload {
  const SafrOtaStatusPayload({required this.state, this.percent = 0});

  final SafrOtaUnitState state;

  /// 0…100.
  final int percent;

  static const wireLength = 2;

  Uint8List build() =>
      Uint8List.fromList([state.wire, percent > 100 ? 100 : percent]);

  static SafrOtaStatusPayload? parse(Uint8List p) {
    if (p.length != wireLength) return null;
    final state = SafrOtaUnitState.fromWire(p[0]);
    if (state == null || p[1] > 100) return null;
    return SafrOtaStatusPayload(state: state, percent: p[1]);
  }
}

/// OTA_RESULT — `MSG_TYPE 0x14`, unit → board, relayed to the tablet,
/// `F_ACK_REQ`: `OK u8 ‖ REASON u8 ‖ AWAKE_S u16 ‖ VER_LEN u8 ‖ VERSION`.
/// Once per offer, by the image that runs when the matter is settled (§13.4).
class SafrOtaResultPayload extends SafrV2Payload {
  const SafrOtaResultPayload({
    required this.ok,
    required this.version,
    this.reasonRaw = 0,
    this.awakeS = 0,
    this.detail = 0,
  });

  final bool ok;
  final int reasonRaw;

  /// Optional trailing byte (§13.4). With [SafrOtaReason.notValidated]: the
  /// chip's reset reason that ended the new image (`esp_reset_reason_t`).
  /// 0 = absent.
  final int detail;

  /// Seconds a battery unit stayed awake for this update; 0 on a mains unit.
  final int awakeS;

  /// What the unit runs NOW.
  final String version;

  SafrOtaReason get reason => SafrOtaReason.fromWire(reasonRaw);

  static const minLength = 2 + 2 + 1;

  Uint8List build() => Uint8List.fromList([
        ok ? 1 : 0,
        reasonRaw & 0xFF,
        (awakeS >> 8) & 0xFF,
        awakeS & 0xFF,
        ..._otaVersion(version),
        if (detail != 0) detail & 0xFF,
      ]);

  static SafrOtaResultPayload? parse(Uint8List p) {
    if (p.length < minLength || p[0] > 1) return null;
    final v = _readOtaVersionAt(p, 4);
    if (v == null) return null;
    final rest = p.length - v.next;
    if (rest > 1) return null;
    return SafrOtaResultPayload(
      ok: p[0] == 1,
      reasonRaw: p[1],
      awakeS: (p[2] << 8) | p[3],
      version: v.version,
      detail: rest == 1 ? p[v.next] : 0,
    );
  }
}
