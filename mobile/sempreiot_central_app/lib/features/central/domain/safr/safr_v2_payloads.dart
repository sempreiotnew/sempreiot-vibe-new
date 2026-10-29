import 'dart:convert';
import 'dart:typed_data';

import 'safr_product.dart';
import 'safr_v2_frame.dart';

part 'safr_ota_payloads.dart';
part 'safr_ota_rollout_payloads.dart';

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

  /// Rename a unit; board updates its table and relays. The zone slot is
  /// reserved since v3.8 (sent empty): a unit's zone / endereçamento go in
  /// [setDeviceIds], never to the unit.
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
  getCode(0x19),

  // ── v3.5 firmware update (spec §13) ────────────────────────────────────

  /// Board-only: line speed of the tablet link, ARGS `BAUD u32` (§13.3).
  otaBaud(0x1A),

  /// Board → one unit: the image the board offers it (§13.4). The tablet
  /// never sends it.
  otaOffer(0x1B),

  /// Board-only: reply with OTA_ROLLOUT pages (§13.6).
  getRollout(0x1C),

  /// Board-only: start / pause / resume / abort a rollout (§13.6).
  otaControl(0x1D),

  // ── v3.8 labels (spec §14.1 / §14.2) ───────────────────────────────────

  /// Board-only: create / rename a zone or endereçamento label.
  setLabel(0x20),

  /// Board-only: delete a label (refused while a unit still carries it).
  delLabel(0x21),

  /// Board-only: reply with LABEL_TABLE pages.
  getLabels(0x22),

  /// Board-only: a unit's zone and endereçamento ids; never reaches the unit.
  setDeviceIds(0x26);

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
        SafrCommand.getCode ||
        SafrCommand.otaBaud ||
        SafrCommand.getRollout ||
        SafrCommand.otaControl ||
        SafrCommand.setLabel ||
        SafrCommand.delLabel ||
        SafrCommand.getLabels ||
        SafrCommand.setDeviceIds =>
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

  /// v3.8: a zone / endereçamento id the board's table does not hold.
  unknownId(0x07),

  /// v3.8: a label a unit (or a rule) still references.
  inUse(0x08),
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
        SafrAckDetail.unknownId => 'zona ou endereçamento desconhecido na placa',
        SafrAckDetail.inUse => 'ainda usado por um dispositivo',
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
    this.dlHeard,
    this.dlMap,
  });

  static const wireLength = 20;

  /// v3.6 DL_HEARD (spec §7.3): board heartbeats heard in the last 120 s,
  /// 0..[dlHeardExpected]. Null = not sent (20-byte heartbeat: a leaf, or
  /// a node on older firmware) or 0xFF (not 120 s on this link yet).
  static const dlHeardExpected = 8;
  static const dlHeardNa = 0xFF;

  final DateTime timestamp;
  final int uptimeS;
  final int pwrFlags;
  final int? batteryPct;
  final int? tempTenths;
  final int? rssiToParent; // dBm, null when 0x7F (root)
  final String parentMac;
  final int layer;
  final int? dlHeard;

  /// v3.7 DL_MAP (spec §7.3): the last 8 board-heartbeat slots, bit 0 the
  /// most recent, 1 = heard, 0 = lost. Null when not sent (a 20- or
  /// 21-byte heartbeat) or while [dlHeard] is not there yet (0xFF).
  final int? dlMap;

  /// Heard (true) / lost (false) for slot [i] of [dlMap], 0 = the newest.
  static bool heardAt(int map, int i) => (map >> i) & 1 == 1;

  static SafrHeartbeatPayload? parse(Uint8List p) {
    if (p.length < wireLength) return null;
    int? dlHeard;
    int? dlMap;
    if (p.length > wireLength && p[20] != dlHeardNa) {
      dlHeard = p[20] > dlHeardExpected ? dlHeardExpected : p[20];
      if (p.length > wireLength + 1) dlMap = p[21];
    }
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
      dlHeard: dlHeard,
      dlMap: dlMap,
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
    this.detailRaw = 0,
  });

  static const wireLength = 4;

  final int ackedMsgId;
  final SafrAckStatus status;

  /// Byte 3 (spec §7.5 v3.2 `DETAIL`); always `none` from pre-v3.2 senders.
  final SafrAckDetail detail;

  /// Byte 3 as it came. What it means depends on the message being
  /// confirmed: [detail] for the v3.2 commands, [otaReason] for a
  /// firmware-update message (spec §13.7) — the two lists share values.
  final int detailRaw;

  /// Byte 3 read as the `REASON` of a firmware-update message (spec §13.7).
  SafrOtaReason get otaReason => SafrOtaReason.fromWire(detailRaw);

  static SafrAckPayload? parse(Uint8List p) {
    if (p.length < wireLength) return null;
    return SafrAckPayload(
      ackedMsgId: (p[0] << 8) | p[1],
      status: SafrAckStatus.fromWire(p[2]),
      detail: SafrAckDetail.fromWire(p[3]),
      detailRaw: p[3],
    );
  }

  static Uint8List build({
    required int ackedMsgId,
    SafrAckStatus status = SafrAckStatus.ok,
    SafrAckDetail detail = SafrAckDetail.none,

    /// Byte 3 as a number, e.g. a firmware-update `REASON` (spec §13.7);
    /// wins over [detail].
    int? detailRaw,
  }) {
    return Uint8List.fromList([
      (ackedMsgId >> 8) & 0xFF,
      ackedMsgId & 0xFF,
      status.wire,
      (detailRaw ?? detail.wire) & 0xFF,
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
    this.productCode,
    this.hwRev,
    this.fwVersion,
  });

  final String name;
  final String zone;

  /// v3.2 optional trailing ROLE byte (spec §7.11); `unknown` when absent.
  final SafrNodeRole role;

  /// v3.5 optional extension after ROLE (spec §7.11): `PRODUCT u16 ‖ HW_REV
  /// u8 ‖ FW_LEN u8 ‖ FW`. All three are null when the frame does not carry
  /// it (older firmware) or carries it malformed. As on the wire otherwise:
  /// PRODUCT 0x0000 = unknown, HW_REV 0 = not stated, FW may be empty.
  final int? productCode;
  final int? hwRev;
  final String? fwVersion;

  bool get hasProductFields => productCode != null;

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
      if (off >= p.length) {
        return SafrNameAnnouncePayload(name: name, zone: zone);
      }
      final role = SafrNodeRole.fromWire(p[off]);
      off += 1;
      // v3.5 extension: all of it or none of it. Truncated, FW_LEN > 24 or
      // FW running past the payload -> ignored, name/zone/role still count.
      int? productCode;
      int? hwRev;
      String? fwVersion;
      if (off + 4 <= p.length) {
        final fwLen = p[off + 3];
        if (fwLen <= safrFwVersionMaxLen && off + 4 + fwLen <= p.length) {
          productCode = (p[off] << 8) | p[off + 1];
          hwRev = p[off + 2];
          fwVersion = _fwVersion(p.sublist(off + 4, off + 4 + fwLen));
        }
      }
      return SafrNameAnnouncePayload(
        name: name,
        zone: zone,
        role: role,
        productCode: productCode,
        hwRev: hwRev,
        fwVersion: fwVersion,
      );
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
    int? productCode,
    int hwRev = 0,
    String fwVersion = '',
  }) {
    final nameBytes = utf8.encode(name);
    final zoneBytes = utf8.encode(zone);
    assert(nameBytes.length <= 32);
    assert(zoneBytes.length <= 16);
    // The v3.5 extension only exists after a ROLE byte (spec §7.11).
    assert(productCode == null || role != null);
    return Uint8List.fromList([
      nameBytes.length,
      ...nameBytes,
      zoneBytes.length,
      ...zoneBytes,
      if (role != null) role.wire,
      if (role != null && productCode != null)
        ..._productFields(productCode, hwRev, fwVersion),
    ]);
  }
}

/// FW bytes -> text (v3.5): ASCII, cut at the first NUL; anything that is not
/// printable ASCII reads as '?' so a bad unit cannot garble the screen.
String _fwVersion(Uint8List b) {
  final out = StringBuffer();
  for (final c in b) {
    if (c == 0) break;
    out.writeCharCode(c >= 0x20 && c <= 0x7E ? c : 0x3F);
  }
  return out.toString().trim();
}

/// `PRODUCT u16 ‖ HW_REV u8 ‖ FW_LEN u8 ‖ FW` (v3.5, spec §7.11/§7.12).
List<int> _productFields(int productCode, int hwRev, String fwVersion) {
  final fw = ascii.encode(fwVersion);
  if (fw.length > safrFwVersionMaxLen) {
    throw ArgumentError(
        'firmware version longer than $safrFwVersionMaxLen bytes: "$fwVersion"');
  }
  return [
    (productCode >> 8) & 0xFF,
    productCode & 0xFF,
    hwRev & 0xFF,
    fw.length,
    ...fw,
  ];
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

/// `SET_DEVICE` ARGS (CMD 0x12): `mac[6] ‖ name ‖ zone_len = 0`. The zone
/// slot is reserved since v3.8 (spec §7.6): sent empty, ignored on receive.
class SafrSetDeviceArgs {
  const SafrSetDeviceArgs({required this.mac, required this.name});
  final String mac;
  final String name;

  static SafrSetDeviceArgs? parse(Uint8List p) {
    try {
      final r = _Reader(p);
      final mac = safrMacToString(r.bytes(6));
      final name = r.str(32);
      r.str(16); // reserved zone slot
      return SafrSetDeviceArgs(mac: mac, name: name);
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  Uint8List build() => Uint8List.fromList([
        ...safrMacToBytes(mac),
        ..._str(name, 32),
        0,
      ]);
}

/// `SET_DEVICE_IDS` ARGS (CMD 0x26, v3.8 §14.1): `mac[6] ‖ zone_id u16 ‖
/// address_id u16`, 0 = none. Board-only.
abstract final class SafrSetDeviceIdsArgs {
  static Uint8List build(
          {required String mac, required int zoneId, required int addressId}) =>
      Uint8List.fromList([
        ...safrMacToBytes(mac),
        (zoneId >> 8) & 0xFF,
        zoneId & 0xFF,
        (addressId >> 8) & 0xFF,
        addressId & 0xFF,
      ]);

  static ({String mac, int zoneId, int addressId})? parse(Uint8List p) =>
      p.length == 10
          ? (
              mac: safrMacToString(p.sublist(0, 6)),
              zoneId: (p[6] << 8) | p[7],
              addressId: (p[8] << 8) | p[9],
            )
          : null;
}

// ── v3.8 labels (spec §14.1 / §14.2) ──────────────────────────────────────

/// Which label table: a zone (a group triggered together) or an
/// endereçamento (where the unit is).
enum SafrLabelKind {
  zone(1),
  address(2);

  const SafrLabelKind(this.wire);
  final int wire;

  static SafrLabelKind? fromWire(int v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }

  /// Singular / plural, as the screens name them.
  String get singular => switch (this) {
        SafrLabelKind.zone => 'Zona',
        SafrLabelKind.address => 'Endereçamento',
      };
  String get plural => switch (this) {
        SafrLabelKind.zone => 'Zonas',
        SafrLabelKind.address => 'Endereçamentos',
      };
}

/// Longest label name on the wire, bytes of UTF-8.
const safrLabelNameMaxLen = 32;

/// Labels of one kind a board may hold (spec §14.1, v1 caps).
const safrLabelCap = 64;

/// One label: the id the system keys by, the name the user sees.
class SafrLabel {
  const SafrLabel({required this.id, required this.name});
  final int id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is SafrLabel && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// `LABEL_TABLE` (0x16): one page of one kind's table (spec §14.2):
/// `KIND ‖ PAGE ‖ PAGE_COUNT ‖ TOTAL u16 ‖ REV u16 ‖ COUNT ‖ (ID u16 ‖
/// NAME_LEN ‖ NAME)[COUNT]`.
class SafrLabelTablePayload extends SafrV2Payload {
  const SafrLabelTablePayload({
    required this.kind,
    required this.page,
    required this.pageCount,
    required this.total,
    required this.rev,
    required this.labels,
  });

  final SafrLabelKind kind;
  final int page; // 1-based
  final int pageCount;
  final int total;

  /// The table's revision: bumped by the board on every change.
  final int rev;
  final List<SafrLabel> labels;

  bool get isLastPage => page >= pageCount;

  static SafrLabelTablePayload? parse(Uint8List p) {
    try {
      final r = _Reader(p);
      final kind = SafrLabelKind.fromWire(r.u8());
      if (kind == null) return null;
      final page = r.u8();
      final pageCount = r.u8();
      final total = r.u16();
      final rev = r.u16();
      final count = r.u8();
      final labels = <SafrLabel>[];
      for (var i = 0; i < count; i++) {
        final id = r.u16();
        final name = r.str(safrLabelNameMaxLen);
        labels.add(SafrLabel(id: id, name: name));
      }
      return SafrLabelTablePayload(
        kind: kind,
        page: page,
        pageCount: pageCount,
        total: total,
        rev: rev,
        labels: labels,
      );
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  static Uint8List build({
    required SafrLabelKind kind,
    required int page,
    required int pageCount,
    required int total,
    required int rev,
    required List<SafrLabel> labels,
  }) {
    final out = <int>[
      kind.wire,
      page & 0xFF,
      pageCount & 0xFF,
      (total >> 8) & 0xFF,
      total & 0xFF,
      (rev >> 8) & 0xFF,
      rev & 0xFF,
      labels.length & 0xFF,
    ];
    for (final l in labels) {
      out
        ..add((l.id >> 8) & 0xFF)
        ..add(l.id & 0xFF)
        ..addAll(_str(l.name, safrLabelNameMaxLen));
    }
    return Uint8List.fromList(out);
  }
}

/// `SET_LABEL` ARGS (CMD 0x20): `KIND ‖ ID u16 ‖ NAME_LEN ‖ NAME`. The tablet
/// chooses the id (next free in its copy); an existing id renames.
abstract final class SafrSetLabelArgs {
  static Uint8List build(
          {required SafrLabelKind kind, required int id, required String name}) =>
      Uint8List.fromList([
        kind.wire,
        (id >> 8) & 0xFF,
        id & 0xFF,
        ..._str(name, safrLabelNameMaxLen),
      ]);

  static ({SafrLabelKind kind, int id, String name})? parse(Uint8List p) {
    try {
      final r = _Reader(p);
      final kind = SafrLabelKind.fromWire(r.u8());
      if (kind == null) return null;
      final id = r.u16();
      final name = r.str(safrLabelNameMaxLen);
      return r.atEnd && id != 0 && name.isNotEmpty
          ? (kind: kind, id: id, name: name)
          : null;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }
}

/// `DEL_LABEL` ARGS (CMD 0x21): `KIND ‖ ID u16`.
abstract final class SafrDelLabelArgs {
  static Uint8List build({required SafrLabelKind kind, required int id}) =>
      Uint8List.fromList([kind.wire, (id >> 8) & 0xFF, id & 0xFF]);

  static ({SafrLabelKind kind, int id})? parse(Uint8List p) {
    if (p.length != 3) return null;
    final kind = SafrLabelKind.fromWire(p[0]);
    final id = (p[1] << 8) | p[2];
    return kind == null || id == 0 ? null : (kind: kind, id: id);
  }
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

/// `GET_DEVICE_TABLE` ARGS (CMD 0x18): `page u8 ‖ format u8`. `page` 0 = all
/// pages. `format` (v3.5) 1 = "send the entries with the product fields",
/// (v3.8) 2 = "and the label ids + link kind, then the label tables"; an
/// older board answers in the layout it knows.
abstract final class SafrGetDeviceTableArgs {
  /// v3.2 entry layout.
  static const formatLegacy = 0;

  /// v3.5 entry layout (product, hardware revision, firmware version).
  static const formatProduct = 1;

  /// v3.8 entry layout: product fields + zone id, endereçamento id, link.
  static const formatLabels = 2;

  static Uint8List build({int page = 0, int format = formatLabels}) =>
      Uint8List.fromList([page & 0xFF, format & 0xFF]);

  static ({int page, int format})? parse(Uint8List p) => p.isEmpty
      ? null
      : (page: p[0], format: p.length > 1 ? p[1] : formatLegacy);
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
    this.productCode = safrProductUnknown,
    this.hwRev = 0,
    this.fwVersion = '',
    this.zoneId = 0,
    this.addressId = 0,
    this.linkKind = safrLinkMesh,
  });

  final String mac;
  final SafrNodeRole role;
  final SafrDeviceState state;
  final int flags;

  /// Seconds since the board last heard it; null = never (`0xFFFF`).
  final int? lastSeenAgeS;
  final String name;

  /// v3.5 product fields, present when the page says so (COUNT bit 7).
  /// 0x0000 / 0 / '' = the board does not know (yet), or a v3.2 page.
  final int productCode;
  final int hwRev;
  final String fwVersion;

  /// v3.8 label ids (spec §14.1), present when the page says so (COUNT
  /// bit 6); 0 = none. [linkKind]: [safrLinkMesh] or [safrLinkIsland].
  final int zoneId;
  final int addressId;
  final int linkKind;

  bool get seenEver => flags & SafrDeviceFlags.seenEver != 0;
  bool get annotated => flags & SafrDeviceFlags.annotated != 0;
  bool get pendingRename => flags & SafrDeviceFlags.pendingRename != 0;
  bool get heardWhileRetired =>
      flags & SafrDeviceFlags.heardWhileRetired != 0;
  bool get pendingDecommission =>
      flags & SafrDeviceFlags.pendingDecommission != 0;
}

/// `DEVICE_TABLE` entry LINK (v3.8, spec §7.12 format 2): how the board
/// reaches the unit.
const safrLinkMesh = 0;
const safrLinkIsland = 1;

/// `DEVICE_TABLE` (0x0B): one page of the board's device table (spec §7.12).
class SafrDeviceTablePayload extends SafrV2Payload {
  const SafrDeviceTablePayload({
    required this.page,
    required this.pageCount,
    required this.total,
    required this.entries,
    this.hasProductFields = false,
    this.hasLabelFields = false,
  });

  /// Bit 7 of the COUNT byte (v3.5): this page's entries carry the product
  /// fields; bit 6 (v3.8): also the label ids and the link kind. The entry
  /// count is the low 6 bits.
  static const countProductFlag = 0x80;
  static const countLabelsFlag = 0x40;
  static const countMask = 0x3F;

  final int page; // 1-based
  final int pageCount;
  final int total;
  final List<SafrDeviceTableEntry> entries;

  /// True for a v3.5 page; false = the v3.2 entry layout (older board).
  final bool hasProductFields;

  /// True for a v3.8 page (format 2): zone / endereçamento ids and link.
  final bool hasLabelFields;

  bool get isLastPage => page >= pageCount;

  static SafrDeviceTablePayload? parse(Uint8List p) {
    try {
      final r = _Reader(p);
      final page = r.u8();
      final pageCount = r.u8();
      final total = r.u16();
      final countByte = r.u8();
      final hasProductFields = countByte & countProductFlag != 0;
      final hasLabelFields = countByte & countLabelsFlag != 0;
      final count = countByte & countMask;
      final entries = <SafrDeviceTableEntry>[];
      for (var i = 0; i < count; i++) {
        final mac = safrMacToString(r.bytes(6));
        final role = SafrNodeRole.fromWire(r.u8());
        final state = SafrDeviceState.fromWire(r.u8());
        final flags = r.u8();
        final age = r.u16();
        final name = r.str(32);
        r.str(16); // reserved zone slot (v3.8)
        var productCode = safrProductUnknown;
        var hwRev = 0;
        var fwVersion = '';
        if (hasProductFields) {
          productCode = r.u16();
          hwRev = r.u8();
          final fwLen = r.u8();
          if (fwLen > safrFwVersionMaxLen) {
            throw const FormatException('bad length prefix');
          }
          fwVersion = _fwVersion(r.bytes(fwLen));
        }
        var zoneId = 0;
        var addressId = 0;
        var linkKind = safrLinkMesh;
        if (hasLabelFields) {
          zoneId = r.u16();
          addressId = r.u16();
          linkKind = r.u8();
        }
        entries.add(SafrDeviceTableEntry(
          mac: mac,
          role: role,
          state: state,
          flags: flags,
          lastSeenAgeS: age == 0xFFFF ? null : age,
          name: name,
          productCode: productCode,
          hwRev: hwRev,
          fwVersion: fwVersion,
          zoneId: zoneId,
          addressId: addressId,
          linkKind: linkKind,
        ));
      }
      return SafrDeviceTablePayload(
        page: page,
        pageCount: pageCount,
        total: total,
        entries: entries,
        hasProductFields: hasProductFields,
        hasLabelFields: hasLabelFields,
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
    bool productFields = false,
    bool labelFields = false,
  }) {
    if (entries.length > countMask) {
      throw ArgumentError('more than $countMask entries in one page');
    }
    if (labelFields && !productFields) {
      throw ArgumentError('the label fields imply the product fields');
    }
    final out = <int>[
      page & 0xFF,
      pageCount & 0xFF,
      (total >> 8) & 0xFF,
      total & 0xFF,
      entries.length |
          (productFields ? countProductFlag : 0) |
          (labelFields ? countLabelsFlag : 0),
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
        ..add(0); // reserved zone slot (v3.8)
      if (productFields) {
        out.addAll(_productFields(e.productCode, e.hwRev, e.fwVersion));
      }
      if (labelFields) {
        out
          ..add((e.zoneId >> 8) & 0xFF)
          ..add(e.zoneId & 0xFF)
          ..add((e.addressId >> 8) & 0xFF)
          ..add(e.addressId & 0xFF)
          ..add(e.linkKind & 0xFF);
      }
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
