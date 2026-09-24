import 'dart:convert';
import 'dart:typed_data';

import 'safr_v2_frame.dart';

/// Payload models and per-MSG_TYPE fixed-layout codecs.
/// Layouts: docs/safr/protocol-safr-v3.md §7 (v2 §6 layouts decode-compatibly:
/// the only difference is EVENT gaining DEV_SEQ at bytes 15..16).

// "not available" sentinels (§6)
const safrNaU8 = 0xFF;
const safrNaU16 = 0xFFFF;
const safrNaI16 = 0x7FFF;

// EVENT_TYPE (§6.1.1)
enum SafrEventType {
  okRestore(0x01, severity: 0),
  alert(0x02, severity: 2),
  alarm(0x03, severity: 3),
  trouble(0x04, severity: 1),
  unknown(0x00, severity: 1);

  const SafrEventType(this.wire, {required this.severity});
  final int wire;

  /// 0 ok · 1 trouble · 2 alert · 3 alarm — matches DeviceEvents.severity.
  final int severity;

  static SafrEventType fromWire(int v) => values.firstWhere(
        (e) => e.wire == v,
        orElse: () => SafrEventType.unknown,
      );
}

// EVENT_CODE (§6.1.2)
enum SafrEventCode {
  none(0x00),
  smokeAlarm(0x01),
  heatAlarm(0x02),
  smokeRising(0x03),
  manualTest(0x04),
  tamper(0x05),
  battLow(0x06),
  battCritical(0x07),
  sensorFault(0x08),
  commFault(0x09),
  acLost(0x0A),
  restore(0x0B),
  rfInterference(0x0C),
  unknown(0xFF);

  const SafrEventCode(this.wire);
  final int wire;

  static SafrEventCode fromWire(int v) => values.firstWhere(
        (e) => e.wire == v,
        orElse: () => SafrEventCode.unknown,
      );
}

// PWR_FLAGS bits (§6.1.3)
const pwrAcOk = 0x01;
const pwrCharging = 0x02;
const pwrOnBattery = 0x04;
const pwrTamper = 0x08;
const pwrTestPressed = 0x10;

// FAULT_FLAGS bits (§6.1.4)
const fltSmokeSensor = 0x01;
const fltTempSensor = 0x02;
const fltBattCritical = 0x04;
const fltMeshLost = 0x08;
const fltRelayFail = 0x10;

enum SafrNodeRole {
  root(0),
  node(1),
  leaf(2),
  unknown(0xFF);

  const SafrNodeRole(this.wire);
  final int wire;

  static SafrNodeRole fromWire(int v) => values.firstWhere(
        (e) => e.wire == v,
        orElse: () => SafrNodeRole.unknown,
      );
}

enum SafrCommand {
  /// Downlink path supervision no-op (spec §9.3) — root just ACKs.
  linkCheck(0x00),
  silence(0x01),
  test(0x02),
  relaySet(0x03),
  identify(0x04),

  /// Operator alarm reset (spec §7.1.4) — the ONLY thing that clears a
  /// latched alarm (UL 864 / NFPA 72).
  reset(0x05),

  /// v3.1, POC round 1 (spec §7.6/§7.10): serial-link-only, board replies
  /// with INSTALLATION. Never relayed into the mesh.
  getInstallation(0x10),

  // ── v3.2 installation lifecycle (spec §7.6, lifecycle §5) ──────────────

  /// Case B: tablet writes the code into a board in SETUP. Setup channel
  /// only (SYSTEM_ID 0x0000, pop-derived key).
  setInstallation(0x11),

  /// Rename / re-zone a unit; board updates its table and relays.
  setDevice(0x12),

  /// Board-only: mark a MAC retired (its frames are dropped from now on).
  retireDevice(0x13),

  /// Board-only: undo retire.
  unretireDevice(0x14),

  /// Board-only: copy name/zone old → new, retire old, decommission if online.
  replaceDevice(0x15),

  /// Remote factory reset of one unit. Never broadcast.
  decommission(0x16),

  /// Board-only: delete a retired entry.
  forgetDevice(0x17),

  /// Board-only: reply with DEVICE_TABLE pages.
  getDeviceTable(0x18),

  /// Setup channel only, provisioned board: reply with CODE.
  getCode(0x19);

  const SafrCommand(this.wire);
  final int wire;

  /// Commands the board answers itself and never relays into the mesh.
  bool get isBoardOnly => switch (this) {
        SafrCommand.getInstallation ||
        SafrCommand.setInstallation ||
        SafrCommand.retireDevice ||
        SafrCommand.unretireDevice ||
        SafrCommand.replaceDevice ||
        SafrCommand.forgetDevice ||
        SafrCommand.getDeviceTable ||
        SafrCommand.getCode =>
          true,
        _ => false,
      };
}

enum SafrAckStatus {
  ok(0x00),
  error(0x01),
  unknownDst(0x02),
  unknown(0xFF);

  const SafrAckStatus(this.wire);
  final int wire;

  static SafrAckStatus fromWire(int v) => values.firstWhere(
        (e) => e.wire == v,
        orElse: () => SafrAckStatus.unknown,
      );
}

/// ACK byte 3 (spec §7.5, v3.2 `DETAIL`) — why a v3.2 command was refused.
enum SafrAckDetail {
  none(0x00),
  unknownMac(0x01),
  tableFull(0x02),
  notRetired(0x03),
  badArgs(0x04),
  refused(0x05),
  notInSetupMode(0x06),
  unknown(0xFF);

  const SafrAckDetail(this.wire);
  final int wire;

  static SafrAckDetail fromWire(int v) => values.firstWhere(
        (e) => e.wire == v,
        orElse: () => SafrAckDetail.unknown,
      );

  String get label => switch (this) {
        SafrAckDetail.none => '',
        SafrAckDetail.unknownMac => 'dispositivo desconhecido na placa',
        SafrAckDetail.tableFull => 'tabela de dispositivos da placa cheia',
        SafrAckDetail.notRetired => 'o dispositivo não está aposentado',
        SafrAckDetail.badArgs => 'argumentos inválidos',
        SafrAckDetail.refused => 'recusado pela placa',
        SafrAckDetail.notInSetupMode => 'a placa já está configurada',
        SafrAckDetail.unknown => 'motivo desconhecido',
      };
}

/// Device-table entry state (spec §7.12, lifecycle §3.2).
enum SafrDeviceState {
  expected(0),
  online(1),
  missing(2),
  retired(3),
  unknown(0xFF);

  const SafrDeviceState(this.wire);
  final int wire;

  static SafrDeviceState fromWire(int v) => values.firstWhere(
        (e) => e.wire == v,
        orElse: () => SafrDeviceState.unknown,
      );
}

/// Device-table entry flags (spec §7.12).
abstract final class SafrDeviceFlags {
  static const seenEver = 0x01;
  static const annotated = 0x02;
  static const pendingRename = 0x04;
  static const heardWhileRetired = 0x08;
  static const pendingDecommission = 0x10;
}

// ── Payload models ───────────────────────────────────────────────

sealed class SafrV2Payload {
  const SafrV2Payload();
}

class SafrEventPayload extends SafrV2Payload {
  const SafrEventPayload({
    required this.eventType,
    required this.eventTypeRaw,
    required this.eventCode,
    required this.eventCodeRaw,
    required this.timestamp,
    required this.pwrFlags,
    required this.batteryPct,
    required this.smokeRaw,
    required this.tempTenths,
    required this.humidityPct,
    required this.faultFlags,
    required this.faultCode,
    this.devSeq,
  });

  static const wireLengthV2 = 15;
  static const wireLength = 17; // v3: +DEV_SEQ (spec §7.1)

  final SafrEventType eventType;
  final int eventTypeRaw;
  final SafrEventCode eventCode;
  final int eventCodeRaw;
  final DateTime timestamp;
  final int pwrFlags;
  final int? batteryPct; // null when 0xFF
  final int? smokeRaw; // null when 0xFFFF
  final int? tempTenths; // °C × 10, null when 0x7FFF
  final int? humidityPct; // null when 0xFF
  final int faultFlags;
  final int faultCode;

  /// Event identity (spec §6): dedupe key across retransmissions and journal
  /// replay. Null on v2-decoded events, which predate it.
  final int? devSeq;

  bool get acOk => (pwrFlags & pwrAcOk) != 0;
  bool get charging => (pwrFlags & pwrCharging) != 0;
  bool get onBattery => (pwrFlags & pwrOnBattery) != 0;
  bool get tamper => (pwrFlags & pwrTamper) != 0;
  bool get testPressed => (pwrFlags & pwrTestPressed) != 0;

  /// Accepts both v3 (17 bytes, with DEV_SEQ) and v2 (15 bytes) layouts.
  static SafrEventPayload? parse(Uint8List p) {
    if (p.length < wireLengthV2) return null;
    final ts = (p[2] << 24) | (p[3] << 16) | (p[4] << 8) | p[5];
    final smoke = (p[8] << 8) | p[9];
    var temp = (p[10] << 8) | p[11];
    final tempNa = temp == safrNaI16;
    if (temp >= 0x8000) temp -= 0x10000;
    return SafrEventPayload(
      eventType: SafrEventType.fromWire(p[0]),
      eventTypeRaw: p[0],
      eventCode: SafrEventCode.fromWire(p[1]),
      eventCodeRaw: p[1],
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
      pwrFlags: p[6],
      batteryPct: p[7] == safrNaU8 ? null : p[7],
      smokeRaw: smoke == safrNaU16 ? null : smoke,
      tempTenths: tempNa ? null : temp,
      humidityPct: p[12] == safrNaU8 ? null : p[12],
      faultFlags: p[13],
      faultCode: p[14],
      devSeq: p.length >= wireLength ? (p[15] << 8) | p[16] : null,
    );
  }
}

class SafrHeartbeatPayload extends SafrV2Payload {
  const SafrHeartbeatPayload({
    required this.timestamp,
    required this.uptimeS,
    required this.pwrFlags,
    required this.batteryPct,
    required this.tempTenths,
    required this.rssiToParent,
    required this.parentMac,
    required this.layer,
  });

  static const wireLength = 20;

  final DateTime timestamp;
  final int uptimeS;
  final int pwrFlags;
  final int? batteryPct;
  final int? tempTenths;
  final int? rssiToParent; // dBm, null when 0x7F (root)
  final String parentMac;
  final int layer;

  static SafrHeartbeatPayload? parse(Uint8List p) {
    if (p.length < wireLength) return null;
    final ts = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
    final up = (p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7];
    var temp = (p[10] << 8) | p[11];
    final tempNa = temp == safrNaI16;
    if (temp >= 0x8000) temp -= 0x10000;
    return SafrHeartbeatPayload(
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
      uptimeS: up,
      pwrFlags: p[8],
      batteryPct: p[9] == safrNaU8 ? null : p[9],
      tempTenths: tempNa ? null : temp,
      rssiToParent: p[12] == 0x7F ? null : p[12].toSigned(8),
      parentMac: safrMacToString(p.sublist(13, 19)),
      layer: p[19],
    );
  }
}

class SafrTopologyChild {
  const SafrTopologyChild({required this.mac, required this.rssi});
  final String mac;
  final int rssi; // dBm (int8)
}

class SafrTopologyPayload extends SafrV2Payload {
  const SafrTopologyPayload({
    required this.timestamp,
    required this.role,
    required this.layer,
    required this.parentMac,
    required this.rssiToParent,
    required this.children,
  });

  static const minWireLength = 14;

  final DateTime timestamp;
  final SafrNodeRole role;
  final int layer;
  final String parentMac;
  final int? rssiToParent; // null when 0x7F
  final List<SafrTopologyChild> children;

  static SafrTopologyPayload? parse(Uint8List p) {
    if (p.length < minWireLength) return null;
    final ts = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
    final childCount = p[13];
    if (p.length < minWireLength + childCount * 7) return null;
    final children = <SafrTopologyChild>[];
    for (var i = 0; i < childCount; i++) {
      final off = minWireLength + i * 7;
      children.add(SafrTopologyChild(
        mac: safrMacToString(p.sublist(off, off + 6)),
        rssi: p[off + 6].toSigned(8),
      ));
    }
    return SafrTopologyPayload(
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
      role: SafrNodeRole.fromWire(p[4]),
      layer: p[5],
      parentMac: safrMacToString(p.sublist(6, 12)),
      rssiToParent: p[12] == 0x7F ? null : p[12].toSigned(8),
      children: children,
    );
  }
}

class SafrAckPayload extends SafrV2Payload {
  const SafrAckPayload({
    required this.ackedMsgId,
    required this.status,
    this.detail = SafrAckDetail.none,
  });

  static const wireLength = 4;

  final int ackedMsgId;
  final SafrAckStatus status;

  /// Byte 3 (spec §7.5 v3.2 `DETAIL`); always `none` from pre-v3.2 senders.
  final SafrAckDetail detail;

  static SafrAckPayload? parse(Uint8List p) {
    if (p.length < wireLength) return null;
    return SafrAckPayload(
      ackedMsgId: (p[0] << 8) | p[1],
      status: SafrAckStatus.fromWire(p[2]),
      detail: SafrAckDetail.fromWire(p[3]),
    );
  }

  static Uint8List build({
    required int ackedMsgId,
    SafrAckStatus status = SafrAckStatus.ok,
    SafrAckDetail detail = SafrAckDetail.none,
  }) {
    return Uint8List.fromList([
      (ackedMsgId >> 8) & 0xFF,
      ackedMsgId & 0xFF,
      status.wire,
      detail.wire,
    ]);
  }
}

class SafrCommandPayload extends SafrV2Payload {
  const SafrCommandPayload({required this.cmdRaw, required this.args});

  final int cmdRaw;
  final Uint8List args;

  static SafrCommandPayload? parse(Uint8List p) {
    if (p.length < 2) return null;
    final argLen = p[1];
    if (p.length < 2 + argLen) return null;
    return SafrCommandPayload(cmdRaw: p[0], args: p.sublist(2, 2 + argLen));
  }

  static Uint8List build(
      {required SafrCommand cmd, List<int> args = const []}) {
    return Uint8List.fromList([cmd.wire, args.length, ...args]);
  }
}

class SafrTimeSyncPayload extends SafrV2Payload {
  const SafrTimeSyncPayload(
      {required this.epoch, required this.tzOffsetQuarterHours});

  static const wireLength = 5;

  final int epoch;
  final int tzOffsetQuarterHours;

  static SafrTimeSyncPayload? parse(Uint8List p) {
    if (p.length < wireLength) return null;
    return SafrTimeSyncPayload(
      epoch: (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3],
      tzOffsetQuarterHours: p[4].toSigned(8),
    );
  }

  static Uint8List build(
      {required DateTime utcNow, Duration tzOffset = Duration.zero}) {
    final epoch = utcNow.millisecondsSinceEpoch ~/ 1000;
    final qh = tzOffset.inMinutes ~/ 15;
    return Uint8List.fromList([
      (epoch >> 24) & 0xFF,
      (epoch >> 16) & 0xFF,
      (epoch >> 8) & 0xFF,
      epoch & 0xFF,
      qh & 0xFF,
    ]);
  }
}

/// Backfill request (spec §7.8): "replay every journaled event after
/// SINCE_JRN_SEQ". Sent by the central on link-up — EN 54-25 "no alarm lost".
class SafrEventLogReqPayload extends SafrV2Payload {
  const SafrEventLogReqPayload({
    required this.sinceJrnSeq,
    required this.maxCount,
  });

  static const wireLength = 5;

  final int sinceJrnSeq;

  /// 0 = root's default batch (32 entries).
  final int maxCount;

  static SafrEventLogReqPayload? parse(Uint8List p) {
    if (p.length < wireLength) return null;
    return SafrEventLogReqPayload(
      sinceJrnSeq: (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3],
      maxCount: p[4],
    );
  }

  static Uint8List build({required int sinceJrnSeq, int maxCount = 0}) {
    return Uint8List.fromList([
      (sinceJrnSeq >> 24) & 0xFF,
      (sinceJrnSeq >> 16) & 0xFF,
      (sinceJrnSeq >> 8) & 0xFF,
      sinceJrnSeq & 0xFF,
      maxCount & 0xFF,
    ]);
  }
}

// LOG_FLAGS bits (spec §7.9)
const safrLogFlagLast = 0x01;
const safrLogFlagEmpty = 0x02;

/// One journaled event replayed by the root (spec §7.9). Carries the original
/// 17-byte EVENT payload untouched, so dedupe by (origSrcMac, DEV_SEQ) and the
/// event history behave exactly as if it had arrived live.
class SafrEventLogDataPayload extends SafrV2Payload {
  const SafrEventLogDataPayload({
    required this.jrnSeq,
    required this.logFlags,
    required this.origSrcMac,
    required this.event,
  });

  static const wireLength = 28;

  final int jrnSeq;
  final int logFlags;
  final String origSrcMac;

  /// Null only when logFlags has EMPTY set (journal had nothing newer).
  final SafrEventPayload? event;

  bool get isLast => (logFlags & safrLogFlagLast) != 0;
  bool get isEmpty => (logFlags & safrLogFlagEmpty) != 0;

  static SafrEventLogDataPayload? parse(Uint8List p) {
    if (p.length < wireLength) return null;
    final logFlags = p[4];
    final empty = (logFlags & safrLogFlagEmpty) != 0;
    final event = empty ? null : SafrEventPayload.parse(p.sublist(11, 11 + 17));
    if (!empty && event == null) return null;
    return SafrEventLogDataPayload(
      jrnSeq: (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3],
      logFlags: logFlags,
      origSrcMac: safrMacToString(p.sublist(5, 11)),
      event: event,
    );
  }

  static Uint8List build({
    required int jrnSeq,
    required int logFlags,
    required Uint8List origSrcMac,
    required Uint8List eventPayload17,
  }) {
    assert(origSrcMac.length == 6);
    assert(eventPayload17.length == SafrEventPayload.wireLength);
    return Uint8List.fromList([
      (jrnSeq >> 24) & 0xFF,
      (jrnSeq >> 16) & 0xFF,
      (jrnSeq >> 8) & 0xFF,
      jrnSeq & 0xFF,
      logFlags,
      ...origSrcMac,
      ...eventPayload17,
    ]);
  }
}

/// One enrolled device inside an INSTALLATION payload (spec §7.10).
class SafrEnrolledDevice {
  const SafrEnrolledDevice({
    required this.mac,
    required this.name,
    required this.zone,
  });
  final String mac;
  final String name;
  final String zone;
}

/// Reply to COMMAND GET_INSTALLATION (spec §7.6/§7.10, v3.1 POC round 1).
/// Board-only, serial-link-only. Never carries `net_psk`/`safr_psk`.
class SafrInstallationPayload extends SafrV2Payload {
  const SafrInstallationPayload({
    required this.systemId,
    required this.channel,
    required this.netSsid,
    required this.name,
    required this.enrolled,
  });

  final int systemId;
  final int channel;
  final String netSsid;
  final String name;
  final List<SafrEnrolledDevice> enrolled;

  static SafrInstallationPayload? parse(Uint8List p) {
    if (p.length < 6) return null;
    var off = 0;
    final systemId = (p[0] << 8) | p[1];
    final channel = p[2];
    off = 3;

    String readLenPrefixed(int maxLen) {
      if (off >= p.length) throw const FormatException('truncated');
      final len = p[off];
      off += 1;
      if (len > maxLen || off + len > p.length) {
        throw const FormatException('bad length prefix');
      }
      final s = utf8.decode(p.sublist(off, off + len));
      off += len;
      return s;
    }

    try {
      final netSsid = readLenPrefixed(32);
      final name = readLenPrefixed(32);
      if (off >= p.length) return null;
      final enrolledCount = p[off];
      off += 1;
      final enrolled = <SafrEnrolledDevice>[];
      for (var i = 0; i < enrolledCount; i++) {
        if (off + 6 > p.length) return null;
        final mac = safrMacToString(p.sublist(off, off + 6));
        off += 6;
        final devName = readLenPrefixed(32);
        final devZone = readLenPrefixed(16);
        enrolled.add(
          SafrEnrolledDevice(mac: mac, name: devName, zone: devZone),
        );
      }
      return SafrInstallationPayload(
        systemId: systemId,
        channel: channel,
        netSsid: netSsid,
        name: name,
        enrolled: enrolled,
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  static Uint8List build({
    required int systemId,
    required int channel,
    required String netSsid,
    required String name,
    List<SafrEnrolledDevice> enrolled = const [],
  }) {
    final ssidBytes = utf8.encode(netSsid);
    final nameBytes = utf8.encode(name);
    assert(ssidBytes.length <= 32);
    assert(nameBytes.length <= 32);
    final out = <int>[
      (systemId >> 8) & 0xFF,
      systemId & 0xFF,
      channel & 0xFF,
      ssidBytes.length,
      ...ssidBytes,
      nameBytes.length,
      ...nameBytes,
      enrolled.length,
    ];
    for (final d in enrolled) {
      final devName = utf8.encode(d.name);
      final devZone = utf8.encode(d.zone);
      assert(devName.length <= 32);
      assert(devZone.length <= 16);
      out
        ..addAll(safrMacToBytes(d.mac))
        ..add(devName.length)
        ..addAll(devName)
        ..add(devZone.length)
        ..addAll(devZone);
    }
    return Uint8List.fromList(out);
  }
}

/// Sent once by a node after boot, forwarded like any other frame (spec
/// §7.11, v3.1 POC round 1). `SRC_MAC` (header) identifies the device.
class SafrNameAnnouncePayload extends SafrV2Payload {
  const SafrNameAnnouncePayload({
    required this.name,
    required this.zone,
    this.role = SafrNodeRole.unknown,
  });

  final String name;
  final String zone;

  /// v3.2 optional trailing ROLE byte (spec §7.11); `unknown` when absent.
  final SafrNodeRole role;

  static SafrNameAnnouncePayload? parse(Uint8List p) {
    if (p.isEmpty) return null;
    try {
      var off = 0;
      final nameLen = p[off];
      off += 1;
      if (nameLen > 32 || off + nameLen > p.length) return null;
      final name = utf8.decode(p.sublist(off, off + nameLen));
      off += nameLen;
      if (off >= p.length) return null;
      final zoneLen = p[off];
      off += 1;
      if (zoneLen > 16 || off + zoneLen > p.length) return null;
      final zone = utf8.decode(p.sublist(off, off + zoneLen));
      off += zoneLen;
      final role =
          off < p.length ? SafrNodeRole.fromWire(p[off]) : SafrNodeRole.unknown;
      return SafrNameAnnouncePayload(name: name, zone: zone, role: role);
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List build({
    required String name,
    required String zone,
    SafrNodeRole? role,
  }) {
    final nameBytes = utf8.encode(name);
    final zoneBytes = utf8.encode(zone);
    assert(nameBytes.length <= 32);
    assert(zoneBytes.length <= 16);
    return Uint8List.fromList([
      nameBytes.length,
      ...nameBytes,
      zoneBytes.length,
      ...zoneBytes,
      if (role != null) role.wire,
    ]);
  }
}

// ── v3.2 installation lifecycle payloads (spec §7.6, §7.12–§7.15) ──────────

/// Shared length-prefixed string reader for the v3.2 layouts.
class _Reader {
  _Reader(this.p);
  final Uint8List p;
  int off = 0;

  int u8() {
    if (off >= p.length) throw const FormatException('truncated');
    return p[off++];
  }

  int u16() => (u8() << 8) | u8();

  Uint8List bytes(int n) {
    if (off + n > p.length) throw const FormatException('truncated');
    final out = p.sublist(off, off + n);
    off += n;
    return out;
  }

  String str(int maxLen) {
    final len = u8();
    if (len > maxLen) throw const FormatException('bad length prefix');
    return utf8.decode(bytes(len));
  }

  bool get atEnd => off >= p.length;
}

List<int> _str(String s, int maxLen) {
  final b = utf8.encode(s);
  if (b.length > maxLen) {
    throw ArgumentError('string longer than $maxLen bytes: "$s"');
  }
  return [b.length, ...b];
}

/// The installation code as carried by `SET_INSTALLATION` ARGS (CMD 0x11)
/// and by the `CODE` reply (0x0C): `system_id u16 ‖ channel u8 ‖ mesh_id u8 ‖
/// ssid ‖ psk ‖ safr_psk[16] ‖ name` (spec §7.6/§7.13). Setup channel only.
class SafrInstallationCode {
  const SafrInstallationCode({
    required this.systemId,
    required this.channel,
    required this.meshId,
    required this.netSsid,
    required this.netPsk,
    required this.safrPsk,
    required this.name,
  });

  final int systemId;
  final int channel;
  final int meshId;
  final String netSsid;
  final String netPsk;
  final Uint8List safrPsk; // 16 bytes
  final String name;

  static SafrInstallationCode? parse(Uint8List p) {
    try {
      final r = _Reader(p);
      final systemId = r.u16();
      final channel = r.u8();
      final meshId = r.u8();
      final ssid = r.str(31);
      final psk = r.str(31);
      final key = r.bytes(16);
      final name = r.str(32);
      return SafrInstallationCode(
        systemId: systemId,
        channel: channel,
        meshId: meshId,
        netSsid: ssid,
        netPsk: psk,
        safrPsk: key,
        name: name,
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  Uint8List build() {
    assert(safrPsk.length == 16);
    assert(systemId > 0 && systemId <= 0xFFFF);
    return Uint8List.fromList([
      (systemId >> 8) & 0xFF,
      systemId & 0xFF,
      channel & 0xFF,
      meshId & 0xFF,
      ..._str(netSsid, 31),
      ..._str(netPsk, 31),
      ...safrPsk,
      ..._str(name, 32),
    ]);
  }
}

/// `CODE` (0x0C): the board's reply to GET_CODE on the setup channel.
class SafrCodePayload extends SafrV2Payload {
  const SafrCodePayload(this.code);
  final SafrInstallationCode code;

  static SafrCodePayload? parse(Uint8List p) {
    final c = SafrInstallationCode.parse(p);
    return c == null ? null : SafrCodePayload(c);
  }
}

/// `SET_DEVICE` ARGS (CMD 0x12): `mac[6] ‖ name ‖ zone`.
class SafrSetDeviceArgs {
  const SafrSetDeviceArgs(
      {required this.mac, required this.name, required this.zone});
  final String mac;
  final String name;
  final String zone;

  static SafrSetDeviceArgs? parse(Uint8List p) {
    try {
      final r = _Reader(p);
      final mac = safrMacToString(r.bytes(6));
      return SafrSetDeviceArgs(mac: mac, name: r.str(32), zone: r.str(16));
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  Uint8List build() => Uint8List.fromList([
        ...safrMacToBytes(mac),
        ..._str(name, 32),
        ..._str(zone, 16),
      ]);
}

/// ARGS for the single-MAC board commands: RETIRE (0x13), UNRETIRE (0x14),
/// DECOMMISSION (0x16), FORGET (0x17).
abstract final class SafrMacArgs {
  static Uint8List build(String mac) => safrMacToBytes(mac);

  static String? parse(Uint8List p) =>
      p.length == 6 ? safrMacToString(p) : null;
}

/// `REPLACE_DEVICE` ARGS (CMD 0x15): `old_mac[6] ‖ new_mac[6]`.
abstract final class SafrReplaceDeviceArgs {
  static Uint8List build({required String oldMac, required String newMac}) =>
      Uint8List.fromList([...safrMacToBytes(oldMac), ...safrMacToBytes(newMac)]);

  static ({String oldMac, String newMac})? parse(Uint8List p) => p.length == 12
      ? (
          oldMac: safrMacToString(p.sublist(0, 6)),
          newMac: safrMacToString(p.sublist(6, 12)),
        )
      : null;
}

/// One entry of `DEVICE_TABLE` (spec §7.12).
class SafrDeviceTableEntry {
  const SafrDeviceTableEntry({
    required this.mac,
    required this.role,
    required this.state,
    required this.flags,
    required this.lastSeenAgeS,
    required this.name,
    required this.zone,
  });

  final String mac;
  final SafrNodeRole role;
  final SafrDeviceState state;
  final int flags;

  /// Seconds since the board last heard it; null = never (`0xFFFF`).
  final int? lastSeenAgeS;
  final String name;
  final String zone;

  bool get seenEver => flags & SafrDeviceFlags.seenEver != 0;
  bool get annotated => flags & SafrDeviceFlags.annotated != 0;
  bool get pendingRename => flags & SafrDeviceFlags.pendingRename != 0;
  bool get heardWhileRetired =>
      flags & SafrDeviceFlags.heardWhileRetired != 0;
  bool get pendingDecommission =>
      flags & SafrDeviceFlags.pendingDecommission != 0;
}

/// `DEVICE_TABLE` (0x0B): one page of the board's device table (spec §7.12).
class SafrDeviceTablePayload extends SafrV2Payload {
  const SafrDeviceTablePayload({
    required this.page,
    required this.pageCount,
    required this.total,
    required this.entries,
  });

  final int page; // 1-based
  final int pageCount;
  final int total;
  final List<SafrDeviceTableEntry> entries;

  bool get isLastPage => page >= pageCount;

  static SafrDeviceTablePayload? parse(Uint8List p) {
    try {
      final r = _Reader(p);
      final page = r.u8();
      final pageCount = r.u8();
      final total = r.u16();
      final count = r.u8();
      final entries = <SafrDeviceTableEntry>[];
      for (var i = 0; i < count; i++) {
        final mac = safrMacToString(r.bytes(6));
        final role = SafrNodeRole.fromWire(r.u8());
        final state = SafrDeviceState.fromWire(r.u8());
        final flags = r.u8();
        final age = r.u16();
        final name = r.str(32);
        final zone = r.str(16);
        entries.add(SafrDeviceTableEntry(
          mac: mac,
          role: role,
          state: state,
          flags: flags,
          lastSeenAgeS: age == 0xFFFF ? null : age,
          name: name,
          zone: zone,
        ));
      }
      return SafrDeviceTablePayload(
        page: page,
        pageCount: pageCount,
        total: total,
        entries: entries,
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  static Uint8List build({
    required int page,
    required int pageCount,
    required int total,
    required List<SafrDeviceTableEntry> entries,
  }) {
    final out = <int>[
      page & 0xFF,
      pageCount & 0xFF,
      (total >> 8) & 0xFF,
      total & 0xFF,
      entries.length,
    ];
    for (final e in entries) {
      final age = e.lastSeenAgeS ?? 0xFFFF;
      out
        ..addAll(safrMacToBytes(e.mac))
        ..add(e.role.wire)
        ..add(e.state.wire)
        ..add(e.flags & 0xFF)
        ..add((age >> 8) & 0xFF)
        ..add(age & 0xFF)
        ..addAll(_str(e.name, 32))
        ..addAll(_str(e.zone, 16));
    }
    return Uint8List.fromList(out);
  }
}

/// `PARENT_PROBE` (0x0D, spec §7.14): 1 byte, `purpose` 0 = parent
/// discovery, 1 = survey. ESP-NOW only; decoded here for diagnostics.
class SafrParentProbePayload extends SafrV2Payload {
  const SafrParentProbePayload({required this.purpose});
  final int purpose;
  bool get isSurvey => purpose == 1;

  static SafrParentProbePayload? parse(Uint8List p) =>
      p.isEmpty ? null : SafrParentProbePayload(purpose: p[0]);

  static Uint8List build({required int purpose}) =>
      Uint8List.fromList([purpose & 0xFF]);
}

/// `PARENT_OFFER` (0x0E, spec §7.15): `purpose ‖ rssi_seen int8 ‖ layer`.
class SafrParentOfferPayload extends SafrV2Payload {
  const SafrParentOfferPayload({
    required this.purpose,
    required this.rssiSeen,
    required this.layer,
  });
  final int purpose;
  final int rssiSeen;

  /// null = answering unit is not on a mesh (`0xFF`).
  final int? layer;

  static SafrParentOfferPayload? parse(Uint8List p) => p.length < 3
      ? null
      : SafrParentOfferPayload(
          purpose: p[0],
          rssiSeen: p[1].toSigned(8),
          layer: p[2] == 0xFF ? null : p[2],
        );

  static Uint8List build(
          {required int purpose, required int rssiSeen, int? layer}) =>
      Uint8List.fromList([purpose & 0xFF, rssiSeen & 0xFF, layer ?? 0xFF]);
}

/// Raw payload kept when the MSG_TYPE is unknown or the layout mismatches.
class SafrUnknownPayload extends SafrV2Payload {
  const SafrUnknownPayload(this.bytes);
  final Uint8List bytes;
}
