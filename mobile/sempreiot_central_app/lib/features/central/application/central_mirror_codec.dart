import 'dart:convert';

import '../../../core/database/app_database.dart' show OtaRun, OtaRunUnit;
import '../domain/ota/firmware_release.dart';
import '../domain/safr/safr_product.dart';
import '../domain/system_test/system_test_run.dart';
import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'device_update_state.dart';
import 'ota_push_state.dart';
import 'ota_rollout_state.dart' show OtaPauseCause;
import 'safr_traffic_provider.dart';
import 'topology_provider.dart';

/// The central mirror on the wire (docs/cloud/central-mirror.md): what the
/// central publishes so a user's phone shows the tablet's live picture, and
/// what the phone sends to say it is watching. JSON, every message `"v":1`.
const mirrorVersion = 1;

/// Phone → central: the `watch` ping. The bare identity topic is the one
/// topic a user's access policy lets it publish to under a central.
String mirrorCommandTopic(String identityId) => identityId;

/// Central → cloud, only while watched: every unit, as the Rede map has it.
String mirrorStateTopic(String identityId) => '$identityId/state';

/// Central → cloud, only while watched: the frame movements, in batches.
String mirrorFramesTopic(String identityId) => '$identityId/frames';

/// Central → cloud, always, retained: the alarms held on the panel.
String mirrorAlarmTopic(String identityId) => '$identityId/alarm';

/// Central → cloud, always, retained: the system test running now and the
/// last few (§4.7).
String mirrorTestTopic(String identityId) => '$identityId/test';

/// Central → cloud, only while watched: the firmware update that runs (or
/// the last one), and the image on its way to the board.
String mirrorOtaTopic(String identityId) => '$identityId/ota';

/// Central → cloud, when a phone asks: the updates kept on the tablet.
String mirrorOtaHistoryTopic(String identityId) => '$identityId/ota/history';

/// Phone → central: a command that needs to know WHO asks — today an
/// Internet update (docs/ota/ota-internet-plan.md §5.4). The last level is
/// the phone's own Identity ID, and AWS lets a user publish only under its
/// own (`SempreIoTCognitoPolicy`: `*/cmd/${cognito-identity.amazonaws.com:sub}`):
/// the central knows who asked from the topic, not from the payload.
String mirrorUserCommandTopic(String identityId, String userIdentityId) =>
    '$identityId/cmd/$userIdentityId';

/// What the central subscribes to: every user's command topic.
String mirrorUserCommandFilter(String identityId) => '$identityId/cmd/+';

/// The user's Identity ID of a command [topic] under [identityId]; null
/// when [topic] is not one.
String? mirrorCommandUser(String identityId, String topic) {
  final prefix = '$identityId/cmd/';
  if (!topic.startsWith(prefix)) return null;
  final user = topic.substring(prefix.length);
  return user.isEmpty || user.contains('/') ? null : user;
}

// ── remote update ───────────────────────────────────────────────────────────

/// A phone asks the central to start "Testar tudo", or to cancel the one
/// running (docs/cloud/central-mirror.md §4.9) — or, with [mac], to send
/// TESTAR to that one unit (§4.10). [id] pairs the central's `test_answer`
/// with the request; [name] is the label the report shows.
/// One test at a time: the central refuses while a run is current.
class MirrorRemoteTest {
  const MirrorRemoteTest(
      {required this.id,
      this.cancel = false,
      this.mac,
      this.restart = false,
      this.takeRoot = false,
      this.name});
  final String id;
  final bool cancel;

  /// One unit's test (`unit_test`) or restart (`unit_restart`); null = the
  /// system test.
  final String? mac;

  /// With [mac]: REINICIAR that unit (§4.11) instead of TESTAR.
  final bool restart;

  /// With [mac]: make that unit the root (§4.12) — the one the central
  /// itself suggests.
  final bool takeRoot;
  final String? name;
}

String encodeMirrorTestStart({required String id, String? name}) => jsonEncode({
      'v': mirrorVersion,
      'type': 'test_start',
      'id': id,
      if (name != null && name.isNotEmpty) 'name': name,
    });

String encodeMirrorTestCancel({required String id, String? name}) =>
    jsonEncode({
      'v': mirrorVersion,
      'type': 'test_cancel',
      'id': id,
      if (name != null && name.isNotEmpty) 'name': name,
    });

/// Phone → central, on the phone's own command topic: send TESTAR to the
/// unit [mac] (§4.10). Administrador only, as "Testar tudo".
String encodeMirrorUnitTest(
        {required String id, required String mac, String? name}) =>
    jsonEncode({
      'v': mirrorVersion,
      'type': 'unit_test',
      'id': id,
      'mac': mac,
      if (name != null && name.isNotEmpty) 'name': name,
    });

/// Phone → central, on the phone's own command topic: restart the unit
/// [mac] — the board, a mains unit or a battery unit (§4.11). Administrador
/// only. A plain restart: nothing is erased.
String encodeMirrorUnitRestart(
        {required String id, required String mac, String? name}) =>
    jsonEncode({
      'v': mirrorVersion,
      'type': 'unit_restart',
      'id': id,
      'mac': mac,
      if (name != null && name.isNotEmpty) 'name': name,
    });

/// Phone → central, on the phone's own command topic: make the unit [mac]
/// the root — the one the central suggests (§4.12). Administrador only.
String encodeMirrorRootTake(
        {required String id, required String mac, String? name}) =>
    jsonEncode({
      'v': mirrorVersion,
      'type': 'root_take',
      'id': id,
      'mac': mac,
      if (name != null && name.isNotEmpty) 'name': name,
    });

/// A `test_start`, a `test_cancel`, a `unit_test`, a `unit_restart` or a
/// `root_take`; null = none of them, or malformed.
MirrorRemoteTest? decodeMirrorRemoteTest(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['id'] is! String) return null;
    final name = map['name'] is String ? map['name'] as String : null;
    final mac = map['mac'];
    return switch (map['type']) {
      'test_start' => MirrorRemoteTest(id: map['id'] as String, name: name),
      'test_cancel' =>
        MirrorRemoteTest(id: map['id'] as String, cancel: true, name: name),
      'unit_test' when mac is String && mac.isNotEmpty =>
        MirrorRemoteTest(id: map['id'] as String, mac: mac, name: name),
      'unit_restart' when mac is String && mac.isNotEmpty => MirrorRemoteTest(
          id: map['id'] as String, mac: mac, restart: true, name: name),
      'root_take' when mac is String && mac.isNotEmpty => MirrorRemoteTest(
          id: map['id'] as String, mac: mac, takeRoot: true, name: name),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// A phone asks for an Internet update ([all] = "Atualizar tudo", else
/// [family] at [version] on [units]), or to cancel the one running. [id]
/// pairs the central's answer with the request; [name] is the label the
/// tablet shows ("Atualização iniciada remotamente por …").
class MirrorRemoteOta {
  const MirrorRemoteOta({
    required this.id,
    this.cancel = false,
    this.all = false,
    this.family,
    this.version,
    this.units = const [],
    this.name,
  });

  final String id;
  final bool cancel;
  final bool all;
  final SafrProductFamily? family;
  final String? version;
  final List<String> units;
  final String? name;
}

String encodeMirrorOtaStart({
  required String id,
  bool all = false,
  SafrProductFamily? family,
  String? version,
  List<String> units = const [],
  String? name,
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'type': 'ota_start',
      'id': id,
      if (all) 'all': true,
      if (family != null) 'family': family.name,
      if (version != null) 'version': version,
      if (units.isNotEmpty) 'units': units,
      if (name != null && name.isNotEmpty) 'name': name,
    });

String encodeMirrorOtaCancel({required String id, String? name}) => jsonEncode({
      'v': mirrorVersion,
      'type': 'ota_cancel',
      'id': id,
      if (name != null && name.isNotEmpty) 'name': name,
    });

/// An `ota_start` or `ota_cancel`; null = neither, or malformed.
MirrorRemoteOta? decodeMirrorRemoteOta(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['id'] is! String) return null;
    final name = map['name'] is String ? map['name'] as String : null;
    switch (map['type']) {
      case 'ota_cancel':
        return MirrorRemoteOta(
            id: map['id'] as String, cancel: true, name: name);
      case 'ota_start':
        final all = map['all'] == true;
        final family = _byName(SafrProductFamily.values, map['family']);
        final version = map['version'];
        if (!all && (family == null || version is! String || version.isEmpty)) {
          return null;
        }
        final units = map['units'];
        return MirrorRemoteOta(
          id: map['id'] as String,
          all: all,
          family: family,
          version: version is String ? version : null,
          units: [
            if (units is List)
              for (final u in units)
                if (u is String) u,
          ],
          name: name,
        );
    }
    return null;
  } catch (_) {
    return null;
  }
}

// ── watch ───────────────────────────────────────────────────────────────────

/// [sub] is the user's id (the one the central's Acessos screen lists),
/// [name] the account name the user signed in with: the tablet shows who is
/// watching. Both are what the phone says of itself — a label, not a proof.
String encodeMirrorWatch({bool hello = false, String? sub, String? name}) =>
    jsonEncode({
      'v': mirrorVersion,
      'type': 'watch',
      if (hello) 'hello': true,
      if (sub != null && sub.isNotEmpty) 'sub': sub,
      if (name != null && name.isNotEmpty) 'name': name,
    });

/// A `watch` ping: `hello` asks for the snapshot again. Null = not a ping.
({bool hello, String? sub, String? name})? decodeMirrorWatch(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['type'] != 'watch') return null;
    final sub = map['sub'];
    final name = map['name'];
    return (
      hello: map['hello'] == true,
      sub: sub is String && sub.isNotEmpty ? sub : null,
      name: name is String && name.isNotEmpty ? name : null,
    );
  } catch (_) {
    return null;
  }
}

/// Phone → central: this phone stopped watching (the user left the central,
/// or the app went to the background). Without it the central would go on
/// streaming until its timeout.
String encodeMirrorUnwatch({String? sub, String? name}) => jsonEncode({
      'v': mirrorVersion,
      'type': 'unwatch',
      if (sub != null && sub.isNotEmpty) 'sub': sub,
      if (name != null && name.isNotEmpty) 'name': name,
    });

({String? sub, String? name})? decodeMirrorUnwatch(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['type'] != 'unwatch') return null;
    final sub = map['sub'];
    final name = map['name'];
    return (
      sub: sub is String && sub.isNotEmpty ? sub : null,
      name: name is String && name.isNotEmpty ? name : null,
    );
  } catch (_) {
    return null;
  }
}

/// Phone → central: send the update history (`ota/history`).
String encodeMirrorOtaHistoryRequest() =>
    jsonEncode({'v': mirrorVersion, 'type': 'ota_history'});

bool isMirrorOtaHistoryRequest(String payload) {
  try {
    final map = jsonDecode(payload);
    return map is Map && map['type'] == 'ota_history';
  } catch (_) {
    return false;
  }
}

/// Phone → central: make this unit blink (IDENTIFY). Any user watching may
/// ask for it: it lights an LED and changes nothing else. (TESTAR of a
/// unit is an Administrador's, on the phone's own topic: `unit_test`.)
String encodeMirrorIdentify(String mac, {String? sub, String? name}) =>
    jsonEncode({
      'v': mirrorVersion,
      'type': 'identify',
      'mac': mac,
      if (sub != null && sub.isNotEmpty) 'sub': sub,
      if (name != null && name.isNotEmpty) 'name': name,
    });

({String mac, String? sub, String? name})? decodeMirrorIdentify(
    String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['type'] != 'identify' || map['mac'] is! String) {
      return null;
    }
    return (
      mac: map['mac'] as String,
      sub: map['sub'] as String?,
      name: map['name'] as String?,
    );
  } catch (_) {
    return null;
  }
}

// ── state ───────────────────────────────────────────────────────────────────

/// A command in flight on the central, as the snapshot carries it:
/// `DeviceCommandStatus.wire` (kind, step, waits for the wake), who started
/// it from a phone, and its note (a broadcast's tally, a unit's "sem
/// comunicação" / "sem resposta").
typedef MirrorCommand = ({String mac, int wire, String? by, String? note});

class MirrorState {
  const MirrorState({
    required this.seq,
    required this.at,
    required this.link,
    required this.nodes,
    this.commands = const [],
  });

  final int seq;

  /// When the central took the snapshot (its clock).
  final DateTime at;

  /// The central's board link (`SerialLinkStatus` name).
  final String link;
  final List<TopologyNode> nodes;

  /// Every command of the tablet still on the map (a system test with its
  /// units, an Identificar …), the broadcast first: a phone joining in the
  /// middle of a test starts with the whole picture, not just what moves
  /// from then on (2026-10-14).
  final List<MirrorCommand> commands;
}

Map<String, dynamic> _unitToJson(TopologyNode n, {bool volatile = true}) => {
      'mac': n.mac,
      'role': n.role.wire,
      'layer': n.layer,
      if (n.parentMac != null) 'parent': n.parentMac,
      if (volatile && n.rssi != null) 'rssi': n.rssi,
      if (volatile && n.dlHeard != null) 'dl': n.dlHeard,
      if (volatile && n.boardRssi != null) 'brd': n.boardRssi,
      if (n.suggestedRoot) 'rootHint': true,
      if (n.batteryPct != null) 'bat': n.batteryPct,
      'online': n.online,
      'heard': n.heard,
      if (n.awaitingSignal) 'awaiting': true,
      if (n.updating) 'updating': true,
      if (volatile) 'lastSeen': n.lastSeenAt.toUtc().toIso8601String(),
      if (n.alarmLatched) 'alarm': true,
      if (n.alarmLatchedAt != null)
        'alarmAt': n.alarmLatchedAt!.toUtc().toIso8601String(),
      if (n.name != null) 'name': n.name,
      if (n.zone != null) 'zone': n.zone,
      if (n.address != null) 'addr': n.address,
      if (n.productCode != null) 'product': n.productCode,
      if (n.hwRev != null) 'hw': n.hwRev,
      if (n.fwVersion != null) 'fw': n.fwVersion,
      if (n.boardState != null) 'boardState': n.boardState!.wire,
      if (n.boardFlags != 0) 'boardFlags': n.boardFlags,
      if (n.parentCandidates.isNotEmpty)
        'candidates': [
          for (final c in n.parentCandidates) [c.mac, c.rssi],
        ],
      // Heat and humidity (2026-11-26). The reading changes on every
      // heartbeat, like the dBm; what the screen says of it does not.
      if (volatile && n.tempTenths != null) 'temp': n.tempTenths,
      if (volatile && n.humidityPct != null) 'hum': n.humidityPct,
      if (volatile && n.readingAt != null)
        'tempAt': n.readingAt!.toUtc().toIso8601String(),
      if (n.tempRising) 'rising': true,
      if (n.alarmCode != null) 'alarmCode': n.alarmCode!.wire,
      if (n.alarmTempTenths != null) 'alarmTemp': n.alarmTempTenths,
      if (n.sensorWet) 'wet': true,
    };

String encodeMirrorState({
  required int seq,
  required DateTime at,
  required String link,
  required List<TopologyNode> nodes,
  List<MirrorCommand> commands = const [],
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'seq': seq,
      'at': at.toUtc().toIso8601String(),
      'link': link,
      'units': [for (final n in nodes) _unitToJson(n)],
      if (commands.isNotEmpty)
        'commands': [
          for (final c in commands)
            {
              'mac': c.mac,
              'wire': c.wire,
              if (c.by != null) 'by': c.by,
              if (c.note != null) 'note': c.note,
            },
        ],
    });

MirrorCommand? _commandFromJson(Object? raw) {
  if (raw is! Map) return null;
  final mac = raw['mac'];
  final wire = raw['wire'];
  if (mac is! String || wire is! num) return null;
  return (
    mac: mac,
    wire: wire.toInt(),
    by: raw['by'] as String?,
    note: raw['note'] as String?,
  );
}

/// What a snapshot says, without what changes on every heartbeat (the last
/// seen time, the dBm): two snapshots with the same signature show the same
/// map, so the second one can wait.
String mirrorStateSignature(String link, List<TopologyNode> nodes) =>
    jsonEncode({
      'link': link,
      'units': [for (final n in nodes) _unitToJson(n, volatile: false)],
    });

TopologyNode? _unitFromJson(Object? raw, DateTime fallbackSeen) {
  if (raw is! Map) return null;
  final mac = raw['mac'];
  if (mac is! String) return null;
  DateTime? time(Object? v) => v is String ? DateTime.tryParse(v) : null;
  final state = raw['boardState'];
  final candidates = raw['candidates'];
  return TopologyNode(
    mac: mac,
    role: SafrNodeRole.fromWire((raw['role'] as num?)?.toInt() ?? 0xFF),
    layer: (raw['layer'] as num?)?.toInt() ?? 0,
    parentMac: raw['parent'] as String?,
    rssi: (raw['rssi'] as num?)?.toInt(),
    dlHeard: (raw['dl'] as num?)?.toInt(),
    boardRssi: (raw['brd'] as num?)?.toInt(),
    suggestedRoot: raw['rootHint'] == true,
    batteryPct: (raw['bat'] as num?)?.toInt(),
    online: raw['online'] == true,
    heard: raw['heard'] == true,
    awaitingSignal: raw['awaiting'] == true,
    updating: raw['updating'] == true,
    lastSeenAt: time(raw['lastSeen']) ?? fallbackSeen,
    alarmLatched: raw['alarm'] == true,
    alarmLatchedAt: time(raw['alarmAt']),
    name: raw['name'] as String?,
    zone: raw['zone'] as String?,
    address: raw['addr'] as String?,
    productCode: (raw['product'] as num?)?.toInt(),
    hwRev: (raw['hw'] as num?)?.toInt(),
    fwVersion: raw['fw'] as String?,
    boardState: state is num ? SafrDeviceState.fromWire(state.toInt()) : null,
    boardFlags: (raw['boardFlags'] as num?)?.toInt() ?? 0,
    parentCandidates: [
      if (candidates is List)
        for (final c in candidates)
          if (c is List && c.length == 2 && c[0] is String && c[1] is num)
            (mac: c[0] as String, rssi: (c[1] as num).toInt()),
    ],
    tempTenths: (raw['temp'] as num?)?.toInt(),
    humidityPct: (raw['hum'] as num?)?.toInt(),
    readingAt: time(raw['tempAt']),
    tempRising: raw['rising'] == true,
    alarmCode: raw['alarmCode'] is num
        ? SafrEventCode.fromWire((raw['alarmCode'] as num).toInt())
        : null,
    alarmTempTenths: (raw['alarmTemp'] as num?)?.toInt(),
    sensorWet: raw['wet'] == true,
  );
}

/// Null on anything that is not a snapshot of this version.
MirrorState? decodeMirrorState(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['v'] != mirrorVersion) return null;
    final units = map['units'];
    final at = DateTime.tryParse(map['at'] as String? ?? '');
    if (units is! List || at == null) return null;
    final commands = map['commands'];
    return MirrorState(
      seq: (map['seq'] as num?)?.toInt() ?? 0,
      at: at,
      link: map['link'] as String? ?? 'disconnected',
      nodes: [
        for (final u in units)
          if (_unitFromJson(u, at) case final node?) node,
      ],
      commands: [
        if (commands is List)
          for (final c in commands)
            if (_commandFromJson(c) case final command?) command,
      ],
    );
  } catch (_) {
    return null;
  }
}

// ── frames ──────────────────────────────────────────────────────────────────

/// One frame movement and how long after the batch started it happened.
typedef MirrorTick = ({int offsetMs, SafrTrafficTick tick});

/// Something that happened on the central and is not a frame movement.
/// - [identify]: the root confirmed an IDENTIFY, the unit [mac] blinks for
///   [arg] seconds;
/// - [identifySending]: the central took a phone's request and is sending
///   the IDENTIFY — the phone knows the central heard it;
/// - [identifyFailed]: an IDENTIFY a phone asked for got no confirmation;
/// - [otaAnswer]: the central's answer to a phone's `ota_start` /
///   `ota_cancel` — [mac] carries the request's id, [arg] is
///   [MirrorOtaAnswer], [text] why it was refused;
/// - [command]: a command to the unit [mac] moved on — [arg] is
///   `DeviceCommandStatus.wire` (kind × 16 + step: sent, the board took it,
///   the unit confirmed it, the test came back, or no confirmation), [text]
///   who started it from a phone. The phones draw the same packet and
///   checks the tablet draws.
typedef MirrorEvent = ({String kind, String mac, int arg, String? text});

abstract final class MirrorEventKind {
  static const identify = 'identify';
  static const identifySending = 'identify_sending';
  static const identifyFailed = 'identify_failed';
  static const otaAnswer = 'ota_answer';
  static const command = 'command';

  /// The central's answer to a phone's `test_start` / `test_cancel` (§4.9):
  /// `arg` as [MirrorOtaAnswer] (started / refused), `text` the reason.
  static const testAnswer = 'test_answer';
}

/// [MirrorEventKind.otaAnswer]'s — and [MirrorEventKind.testAnswer]'s — `arg`.
abstract final class MirrorOtaAnswer {
  static const refused = 0;
  static const started = 1;

  /// Heard and being worked on (the image may have to be downloaded first).
  static const working = 2;
}

class MirrorFrames {
  const MirrorFrames({
    required this.seq,
    required this.ticks,
    this.events = const [],
  });
  final int seq;
  final List<MirrorTick> ticks;
  final List<MirrorEvent> events;
}

/// A tick is `[ms since t0, mac, direction (0 up, 1 down), severity, ack,
/// parentMac, msgType, eventCode, uptimeS, dlHeard, dlMap]`: short, because
/// this is the message that is sent several times a second. The tenth and
/// eleventh elements (2026-10-27) are read when present: a phone on an
/// older app ignores them, a newer phone reads an older central's nine.
String encodeMirrorFrames({
  required int seq,
  required DateTime t0,
  required List<MirrorTick> ticks,
  List<MirrorEvent> events = const [],
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'seq': seq,
      't0': t0.millisecondsSinceEpoch,
      if (events.isNotEmpty)
        'events': [
          for (final e in events)
            [e.kind, e.mac, e.arg, if (e.text != null) e.text],
        ],
      'ticks': [
        for (final t in ticks)
          [
            t.offsetMs,
            t.tick.mac,
            t.tick.direction == SafrTrafficDirection.uplink ? 0 : 1,
            t.tick.severity,
            t.tick.ack ? 1 : 0,
            t.tick.parentMac,
            t.tick.msgType?.wire,
            t.tick.eventCode?.wire,
            t.tick.uptimeS,
          ],
      ],
    });

MirrorFrames? decodeMirrorFrames(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['v'] != mirrorVersion) return null;
    final raw = map['ticks'];
    if (raw is! List) return null;
    final ticks = <MirrorTick>[];
    for (final t in raw) {
      if (t is! List || t.length < 9 || t[1] is! String) continue;
      final type = t[6];
      final code = t[7];
      ticks.add((
        offsetMs: (t[0] as num?)?.toInt() ?? 0,
        tick: SafrTrafficTick(
          mac: t[1] as String,
          direction: t[2] == 0
              ? SafrTrafficDirection.uplink
              : SafrTrafficDirection.downlink,
          severity: (t[3] as num?)?.toInt() ?? 0,
          ack: t[4] == 1,
          parentMac: t[5] as String?,
          msgType: type is num ? SafrMsgType.fromWire(type.toInt()) : null,
          eventCode: code is num ? SafrEventCode.fromWire(code.toInt()) : null,
          uptimeS: (t[8] as num?)?.toInt(),
        ),
      ));
    }
    final events = map['events'];
    return MirrorFrames(
      seq: (map['seq'] as num?)?.toInt() ?? 0,
      ticks: ticks,
      events: [
        if (events is List)
          for (final e in events)
            if (e is List && e.length >= 3 && e[0] is String && e[1] is String)
              (
                kind: e[0] as String,
                mac: e[1] as String,
                arg: (e[2] as num?)?.toInt() ?? 0,
                text: e.length > 3 && e[3] is String ? e[3] as String : null,
              ),
      ],
    );
  } catch (_) {
    return null;
  }
}

// ── system tests ────────────────────────────────────────────────────────────

/// The retained `test` message: the test running now (null = none) and
/// the last tests, newest first.
class MirrorTests {
  const MirrorTests({required this.at, this.running, this.recent = const []});
  final DateTime at;
  final SystemTestRun? running;
  final List<SystemTestRun> recent;

  /// [running] only while the record can still be true. The central writes
  /// the record on every change and a test ends within its 100 s window,
  /// so a "running" written longer than [mirrorTestsStaleAfter] ago is a
  /// record whose end never reached the broker (2026-10-31: one such left
  /// every phone with ✓✓ on every unit, and would have locked their
  /// "Testar tudo" for good). Stale = no test runs, nothing lights up.
  SystemTestRun? runningAt(DateTime now) =>
      running != null && now.difference(at) < mirrorTestsStaleAfter
          ? running
          : null;
}

/// Older than this, a retained "running" test is stale (see
/// [MirrorTests.runningAt]): the broadcast window is 100 s, a detector's
/// wake window 75 s, and the central rewrites the record on every change.
const mirrorTestsStaleAfter = Duration(minutes: 3);

/// How many past tests ride the retained message (the tablet keeps them
/// all; a phone sees these). Five (was 10, 2026-10-31): the record is
/// billed in 5 KB steps, and with ten runs it was about to cross one.
const mirrorTestsRecent = 5;

String encodeMirrorTests({
  required DateTime at,
  SystemTestRun? running,
  List<SystemTestRun> recent = const [],
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'at': at.toUtc().toIso8601String(),
      if (running != null) 'running': running.toJson(),
      'recent': [
        for (final r in recent.take(mirrorTestsRecent)) r.toJson(),
      ],
    });

/// What the message says without the time it was published: the same
/// tests = the same message, so it is not written again.
String mirrorTestsSignature(
        SystemTestRun? running, List<SystemTestRun> recent) =>
    jsonEncode({
      if (running != null) 'running': running.toJson(),
      'recent': [
        for (final r in recent.take(mirrorTestsRecent)) r.toJson(),
      ],
    });

MirrorTests? decodeMirrorTests(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['v'] != mirrorVersion) return null;
    final at = DateTime.tryParse(map['at'] as String? ?? '');
    if (at == null) return null;
    final recent = map['recent'];
    return MirrorTests(
      at: at,
      running: SystemTestRun.fromJson(map['running']),
      recent: [
        if (recent is List)
          for (final r in recent)
            if (SystemTestRun.fromJson(r) case final run?) run,
      ],
    );
  } catch (_) {
    return null;
  }
}

// ── alarm ───────────────────────────────────────────────────────────────────

/// One alarm held on the panel (SAFR v3 §7.1.4): latched until the operator
/// resets it at the tablet.
class MirrorAlarm {
  const MirrorAlarm({
    required this.mac,
    this.name,
    this.zone,
    this.since,
    this.address,
    this.productCode,
    this.leaf = false,
    this.code,
    this.tempTenths,
  });

  final String mac;
  final String? name;
  final String? zone;
  final DateTime? since;

  /// Why it is held (2026-11-26): the EVENT_CODE of the newest ALARM of
  /// the latch and the TEMP it carried (°C × 10) — "Calor — 58 °C". Absent
  /// from a central on an older app.
  final int? code;
  final int? tempTenths;

  /// What a phone needs to draw the unit itself (2026-11-23): its
  /// endereçamento, its product (the model it is drawn as), whether it
  /// runs on a battery. Absent from a central on an older app.
  final String? address;
  final int? productCode;
  final bool leaf;
}

class MirrorAlarms {
  const MirrorAlarms({required this.at, required this.alarms, this.panel});

  /// When the central published this list (its clock).
  final DateTime at;
  final List<MirrorAlarm> alarms;

  /// What Principal shows besides the alarms (2026-11-19); null from a
  /// central whose app does not publish it yet.
  final MirrorPanel? panel;
}

/// What kind of line an event is — the word and the colour it is listed
/// with (2026-11-23). It is not the wire's severity alone: a manual test
/// arrives as an "alert" and is no warning of anything, and "the root
/// changed" is news, not "OK".
enum PanelEventKind {
  /// Something came back to normal.
  ok(0),

  /// News that asks for nothing: a test, a command, a change in the mesh.
  info(4),

  /// A unit or a link needs attention.
  trouble(1),

  /// A pre-alarm.
  alert(2),

  alarm(3);

  const PanelEventKind(this.wire);

  /// 0–3 are the severities, as they always travelled; 4 is [info].
  final int wire;

  static PanelEventKind fromSeverity(int severity) => switch (severity) {
        3 => alarm,
        2 => alert,
        1 => trouble,
        _ => ok,
      };

  static PanelEventKind? fromWire(Object? v) {
    if (v is! num) return null;
    for (final k in values) {
      if (k.wire == v.toInt()) return k;
    }
    return null;
  }
}

/// One line of the central's event list, already in words.
class MirrorPanelEvent {
  const MirrorPanelEvent({
    required this.at,
    required this.severity,
    required this.text,
    PanelEventKind? kind,
    this.mac,
    this.outage,
    this.comm,
    this.zone,
    this.address,
  }) : _kind = kind;

  final DateTime at;

  /// 0 ok · 1 trouble · 2 alert · 3 alarm (DeviceEvents.severity).
  final int severity;
  final String text;

  final PanelEventKind? _kind;

  /// How the line is listed; the severity's own kind when nothing said
  /// otherwise (a central on an older app).
  PanelEventKind get kind => _kind ?? PanelEventKind.fromSeverity(severity);

  /// The unit the line is about; null for the central's own lines.
  final String? mac;

  /// The line is a unit's own account of a time with no path to the
  /// central (OUTAGE_REPORT): its numbers, so a screen can put the lines of
  /// one incident together (2026-11-24). Null for every other line.
  final PanelOutage? outage;

  /// The line is the central's supervision: the unit went silent, or was
  /// heard again. Null for every other line.
  final PanelCommChange? comm;

  /// The unit's zona and endereçamento **as the central has them now**
  /// (2026-11-24) — the event table does not keep where a unit was when
  /// the line was written. Null for a line that is not about a unit, and
  /// for a unit that is no longer in the installation.
  final String? zone;
  final String? address;

  /// The same line, with where its unit is.
  MirrorPanelEvent placed({String? zone, String? address}) => MirrorPanelEvent(
        at: at,
        severity: severity,
        text: text,
        kind: _kind,
        mac: mac,
        outage: outage,
        comm: comm,
        zone: zone,
        address: address,
      );

  /// The same line, listed as [kind].
  MirrorPanelEvent withKind(PanelEventKind kind) => MirrorPanelEvent(
        at: at,
        severity: severity,
        text: text,
        kind: kind,
        mac: mac,
        outage: outage,
        comm: comm,
        zone: zone,
        address: address,
      );

  /// Who the line is about, as the line names it (what stands before the
  /// dash); null for a line with no dash.
  String? get who {
    final i = text.indexOf(' — ');
    return i <= 0 ? null : text.substring(0, i);
  }
}

/// The central's supervision said so of a unit.
enum PanelCommChange {
  missing(1),
  restored(2);

  const PanelCommChange(this.wire);
  final int wire;

  static PanelCommChange? fromWire(Object? v) =>
      values.where((e) => e.wire == v).firstOrNull;
}

/// The numbers of an OUTAGE_REPORT (protocol §7.17), as the central stored
/// them — on the cloud a list of eight numbers, in this order.
class PanelOutage {
  const PanelOutage({
    required this.duration,
    this.cause = 0,
    this.flags = 0,
    this.rescues = 0,
    this.rescuesMissed = 0,
    this.anyRounds = 0,
    this.restarts = 0,
    this.end = 3,
  });

  final Duration duration;

  /// CAUSE, FLAGS, the counters and END as they came on the wire.
  final int cause;
  final int flags;
  final int rescues;
  final int rescuesMissed;
  final int anyRounds;
  final int restarts;
  final int end;

  List<int> toWire() => [
        duration.inSeconds,
        cause,
        flags,
        rescues,
        rescuesMissed,
        anyRounds,
        restarts,
        end,
      ];

  static PanelOutage? fromWire(Object? v) {
    if (v is! List || v.length < 8 || v.any((e) => e is! num)) return null;
    final n = [for (final e in v) (e as num).toInt()];
    return PanelOutage(
      duration: Duration(seconds: n[0] < 0 ? 0 : n[0]),
      cause: n[1],
      flags: n[2],
      rescues: n[3],
      rescuesMissed: n[4],
      anyRounds: n[5],
      restarts: n[6],
      end: n[7],
    );
  }
}

/// One unit that needs attention: its name and why ([offline] | [battery]),
/// and what a screen needs to draw the unit itself (2026-11-23) — which
/// product it is, where it is, whether it runs on a battery.
class MirrorTrouble {
  const MirrorTrouble({
    required this.name,
    required this.why,
    this.mac,
    this.address,
    this.productCode,
    this.leaf = false,
    this.batteryPct,
  });

  static const offline = 'offline';
  static const battery = 'battery';

  /// SENSOR_WET (2026-11-26): the unit answers, its sensor is saturated.
  static const wet = 'wet';

  /// The unit's name; its endereçamento or its MAC when it has none.
  final String name;
  final String why;

  /// The unit; null from a central on an older app.
  final String? mac;

  /// Its endereçamento, when it has one.
  final String? address;

  /// Its product (system reference §2.1): the model it is drawn as.
  final int? productCode;

  /// A battery unit.
  final bool leaf;
  final int? batteryPct;
}

/// The numbers and the last events of the central's Principal, carried on
/// the retained alarm message so a phone has them the moment it opens —
/// without watching the live map (docs/cloud/central-mirror.md §4.5).
class MirrorPanel {
  const MirrorPanel({
    required this.total,
    required this.troubles,
    this.troubleList = const [],
    this.events = const [],
  });

  /// At most this many events and troubles are carried.
  static const maxEvents = 20;
  static const maxTroubles = 10;

  /// Units installed (heard at least once), and how many need attention.
  final int total;
  final int troubles;

  /// The first [maxTroubles] of them, by name.
  final List<MirrorTrouble> troubleList;

  /// The last [maxEvents] events, newest first.
  final List<MirrorPanelEvent> events;
}

List<Map<String, dynamic>> _alarmsToJson(List<MirrorAlarm> alarms) => [
      for (final a in alarms)
        {
          'mac': a.mac,
          if (a.name?.isNotEmpty == true) 'name': a.name,
          if (a.zone?.isNotEmpty == true) 'zone': a.zone,
          if (a.since != null) 'since': a.since!.toUtc().toIso8601String(),
          if (a.address?.isNotEmpty == true) 'addr': a.address,
          if (a.productCode != null) 'prod': a.productCode,
          if (a.leaf) 'leaf': 1,
          if (a.code != null) 'code': a.code,
          if (a.tempTenths != null) 'temp': a.tempTenths,
        },
    ];

Map<String, dynamic> _panelToJson(MirrorPanel p) => {
      'n': p.total,
      'nt': p.troubles,
      'tr': [
        for (final t in p.troubleList.take(MirrorPanel.maxTroubles))
          {
            'n': t.name,
            'w': t.why,
            if (t.mac != null) 'm': t.mac,
            if (t.address?.isNotEmpty == true) 'a': t.address,
            if (t.productCode != null) 'p': t.productCode,
            if (t.leaf) 'l': 1,
            if (t.batteryPct != null) 'b': t.batteryPct,
          },
      ],
      'ev': [
        for (final e in p.events.take(MirrorPanel.maxEvents))
          {
            't': e.at.toUtc().toIso8601String(),
            's': e.severity,
            'x': e.text,
            // Said only when it is not the severity's own (older phones
            // read `s` alone).
            if (e.kind != PanelEventKind.fromSeverity(e.severity))
              'k': e.kind.wire,
            if (e.mac != null) 'm': e.mac,
            if (e.outage != null) 'o': e.outage!.toWire(),
            if (e.comm != null) 'c': e.comm!.wire,
            if (e.zone?.isNotEmpty == true) 'z': e.zone,
            if (e.address?.isNotEmpty == true) 'a': e.address,
          },
      ],
    };

/// Old phones read `alarms` alone and ignore `panel`.
String encodeMirrorAlarms({
  required DateTime at,
  required List<MirrorAlarm> alarms,
  MirrorPanel? panel,
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'at': at.toUtc().toIso8601String(),
      'alarms': _alarmsToJson(alarms),
      if (panel != null) 'panel': _panelToJson(panel),
    });

/// The list without the time it was published: the same alarms held (and
/// the same numbers and events) = the same signature = nothing new to
/// publish.
String mirrorAlarmsSignature(List<MirrorAlarm> alarms, [MirrorPanel? panel]) =>
    jsonEncode([
      _alarmsToJson(alarms),
      if (panel != null) _panelToJson(panel),
    ]);

MirrorPanel? _panelFromJson(Object? raw) {
  if (raw is! Map) return null;
  final total = raw['n'];
  final troubles = raw['nt'];
  if (total is! num || troubles is! num) return null;
  final tr = raw['tr'];
  final ev = raw['ev'];
  return MirrorPanel(
    total: total.toInt(),
    troubles: troubles.toInt(),
    troubleList: [
      if (tr is List)
        for (final t in tr)
          if (t is Map && t['n'] is String)
            MirrorTrouble(
                name: t['n'] as String,
                why: t['w'] as String? ?? MirrorTrouble.offline,
                mac: t['m'] is String ? t['m'] as String : null,
                address: t['a'] is String ? t['a'] as String : null,
                productCode: (t['p'] as num?)?.toInt(),
                leaf: t['l'] == 1,
                batteryPct: (t['b'] as num?)?.toInt()),
    ],
    events: [
      if (ev is List)
        for (final e in ev)
          if (e is Map && e['x'] is String)
            if (DateTime.tryParse(e['t'] as String? ?? '') case final at?)
              MirrorPanelEvent(
                at: at,
                severity: (e['s'] as num?)?.toInt() ?? 0,
                text: e['x'] as String,
                kind: PanelEventKind.fromWire(e['k']),
                mac: e['m'] is String ? e['m'] as String : null,
                outage: PanelOutage.fromWire(e['o']),
                comm: PanelCommChange.fromWire(e['c']),
                zone: e['z'] is String ? e['z'] as String : null,
                address: e['a'] is String ? e['a'] as String : null,
              ),
    ],
  );
}

MirrorAlarms? decodeMirrorAlarms(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['v'] != mirrorVersion) return null;
    final raw = map['alarms'];
    final at = DateTime.tryParse(map['at'] as String? ?? '');
    if (raw is! List || at == null) return null;
    return MirrorAlarms(
      at: at,
      alarms: [
        for (final a in raw)
          if (a is Map && a['mac'] is String)
            MirrorAlarm(
              mac: a['mac'] as String,
              name: a['name'] as String?,
              zone: a['zone'] as String?,
              since: DateTime.tryParse(a['since'] as String? ?? ''),
              address: a['addr'] is String ? a['addr'] as String : null,
              productCode: (a['prod'] as num?)?.toInt(),
              leaf: a['leaf'] == 1,
              code: (a['code'] as num?)?.toInt(),
              tempTenths: (a['temp'] as num?)?.toInt(),
            ),
      ],
      panel: _panelFromJson(map['panel']),
    );
  } catch (_) {
    return null;
  }
}

// ── ota ─────────────────────────────────────────────────────────────────────

/// The firmware update as the tablet's "Atualizar dispositivos" has it.
class MirrorOta {
  const MirrorOta({
    required this.seq,
    this.run,
    this.push,
    this.releases,
    this.updates = UpdatesAvailable.none,
  });

  final int seq;

  /// The versions the central may install from the Internet, newest first
  /// (its two catalogs merged); null = it has heard no catalog (or is an
  /// app from before the Internet updates).
  final List<FirmwareRelease>? releases;

  /// What the central's badge counts.
  final UpdatesAvailable updates;

  /// The update on screen: running, or ended and not dismissed. Null = none.
  final DeviceUpdateRun? run;

  /// The image on its way from the tablet to the board; null = none.
  final OtaPushState? push;
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

Map<String, dynamic> _runToJson(DeviceUpdateRun r) => {
      'runId': r.runId,
      'all': r.all,
      'phases': [for (final f in r.phases) f.name],
      'phase': r.phase,
      'target': r.target,
      'targets': {for (final e in r.targets.entries) e.key.name: e.value},
      'queues': {for (final e in r.queues.entries) e.key.name: e.value},
      'units': [
        for (final u in r.units.values)
          {
            'key': u.key,
            'family': u.family.name,
            'state': u.state.name,
            if (u.percent != 0) 'percent': u.percent,
            if (u.attempts != 0) 'attempts': u.attempts,
            if (u.reasonRaw != 0) 'reason': u.reasonRaw,
            if (u.versionBefore.isNotEmpty) 'before': u.versionBefore,
            if (u.version.isNotEmpty) 'version': u.version,
            if (u.note != null) 'note': u.note,
          },
      ],
      'stage': r.stage.name,
      if (r.end != null) 'end': r.end!.name,
      if (r.message != null) 'message': r.message,
      if (r.holding) 'holding': true,
      if (r.pausedBy != null) 'pausedBy': r.pausedBy!.name,
      'startedAt': _iso(r.startedAt),
      if (r.endedAt != null) 'endedAt': _iso(r.endedAt),
      if (r.boardRestartedAt != null)
        'boardRestartedAt': _iso(r.boardRestartedAt),
      'startedBy': r.startedBy,
      'source': r.source.name,
      if (r.publishedBy != null) 'publishedBy': r.publishedBy,
    };

DeviceUpdateRun? _runFromJson(Object? raw) {
  if (raw is! Map) return null;
  final stage = _byName(DeviceUpdateStage.values, raw['stage']);
  final startedAt = _time(raw['startedAt']);
  final phases = raw['phases'];
  final units = raw['units'];
  if (stage == null || startedAt == null || phases is! List || units is! List) {
    return null;
  }
  SafrProductFamily family(Object? name) =>
      _byName(SafrProductFamily.values, name) ?? SafrProductFamily.unknown;
  final targets = raw['targets'];
  final queues = raw['queues'];
  return DeviceUpdateRun(
    runId: raw['runId'] as String? ?? '',
    all: raw['all'] == true,
    phases: [for (final p in phases) family(p)],
    phase: (raw['phase'] as num?)?.toInt() ?? 0,
    target: raw['target'] as String? ?? '',
    targets: {
      if (targets is Map)
        for (final e in targets.entries) family(e.key): '${e.value}',
    },
    queues: {
      if (queues is Map)
        for (final e in queues.entries)
          if (e.value is List)
            family(e.key): [for (final k in e.value as List) '$k'],
    },
    units: {
      for (final u in units)
        if (u is Map && u['key'] is String)
          u['key'] as String: DeviceUpdateUnit(
            key: u['key'] as String,
            family: family(u['family']),
            state: _byName(SafrOtaUnitState.values, u['state']) ??
                SafrOtaUnitState.waiting,
            percent: (u['percent'] as num?)?.toInt() ?? 0,
            attempts: (u['attempts'] as num?)?.toInt() ?? 0,
            reasonRaw: (u['reason'] as num?)?.toInt() ?? 0,
            versionBefore: u['before'] as String? ?? '',
            version: u['version'] as String? ?? '',
            note: u['note'] as String?,
          ),
    },
    stage: stage,
    end: _byName(DeviceUpdateEnd.values, raw['end']),
    message: raw['message'] as String?,
    holding: raw['holding'] == true,
    pausedBy: _byName(OtaPauseCause.values, raw['pausedBy']),
    startedAt: startedAt,
    endedAt: _time(raw['endedAt']),
    boardRestartedAt: _time(raw['boardRestartedAt']),
    startedBy: raw['startedBy'] as String? ?? 'system',
    source: _byName(DeviceUpdateSource.values, raw['source']) ??
        DeviceUpdateSource.manual,
    publishedBy: raw['publishedBy'] as String?,
  );
}

/// What the screens read of a push: its phase and how far it is. The
/// image, the steps and the log stay on the tablet.
Map<String, dynamic>? _pushToJson(OtaPushState? p) {
  if (p == null || p.phase == OtaPushPhase.idle) return null;
  return {
    'phase': p.phase.name,
    'chunksDone': p.chunksDone,
    'chunksTotal': p.chunksTotal,
    'bytesDone': p.bytesDone,
    'bytesTotal': p.bytesTotal,
    if (p.waitingFor != null) 'waitingFor': p.waitingFor,
  };
}

OtaPushState? _pushFromJson(Object? raw) {
  if (raw is! Map) return null;
  final phase = _byName(OtaPushPhase.values, raw['phase']);
  if (phase == null) return null;
  return OtaPushState(
    phase: phase,
    chunksDone: (raw['chunksDone'] as num?)?.toInt() ?? 0,
    bytesDone: (raw['bytesDone'] as num?)?.toInt() ?? 0,
    totals: (
      chunks: (raw['chunksTotal'] as num?)?.toInt() ?? 0,
      bytes: (raw['bytesTotal'] as num?)?.toInt() ?? 0,
    ),
    waitingFor: raw['waitingFor'] as String?,
  );
}

/// The published versions as the phone needs them: what, when, by whom,
/// for which families and their sizes. Keys and hashes stay on the tablet
/// (the phone never downloads an image).
List<Map<String, dynamic>> _releasesToJson(List<FirmwareRelease> releases) => [
      for (final r in releases)
        {
          'version': r.version,
          if (r.published != null) 'published': _iso(r.published),
          if (r.publishedBy != null) 'by': r.publishedBy!.who,
          if (r.notes.isNotEmpty) 'notes': r.notes,
          if (r.forThisCentral) 'mine': true,
          'sizes': {for (final e in r.images.entries) e.key.name: e.value.size},
        },
    ];

List<FirmwareRelease>? _releasesFromJson(Object? raw) {
  if (raw is! List) return null;
  final out = <FirmwareRelease>[];
  for (final r in raw) {
    if (r is! Map || r['version'] is! String) continue;
    final sizes = r['sizes'];
    final images = <SafrProductFamily, FirmwareReleaseImage>{
      if (sizes is Map)
        for (final e in sizes.entries)
          if (_byName(SafrProductFamily.values, e.key) case final f?)
            f: FirmwareReleaseImage(
                key: '',
                size: (e.value as num?)?.toInt() ?? 0,
                sha256: '',
                project: 'sempreiot-${f.name}'),
    };
    if (images.isEmpty) continue;
    final by = r['by'];
    out.add(FirmwareRelease(
      version: r['version'] as String,
      images: images,
      bucket: '',
      region: '',
      published: _time(r['published']),
      publishedBy: by is String ? FirmwarePublisher(who: by) : null,
      notes: r['notes'] is String ? r['notes'] as String : '',
      forThisCentral: r['mine'] == true,
    ));
  }
  return out;
}

Map<String, dynamic> _updatesToJson(UpdatesAvailable u) => {
      'units': {for (final e in u.units.entries) e.key.name: e.value},
      'versions': {for (final e in u.versions.entries) e.key.name: e.value},
    };

UpdatesAvailable _updatesFromJson(Object? raw) {
  if (raw is! Map) return UpdatesAvailable.none;
  final units = raw['units'], versions = raw['versions'];
  return UpdatesAvailable(
    units: {
      if (units is Map)
        for (final e in units.entries)
          if (_byName(SafrProductFamily.values, e.key) case final f?)
            if (e.value is List) f: [for (final k in e.value as List) '$k'],
    },
    versions: {
      if (versions is Map)
        for (final e in versions.entries)
          if (_byName(SafrProductFamily.values, e.key) case final f?)
            f: '${e.value}',
    },
  );
}

/// The update without its number: the same body = nothing new to publish.
String mirrorOtaBody(
  DeviceUpdateRun? run,
  OtaPushState? push, {
  List<FirmwareRelease>? releases,
  UpdatesAvailable updates = UpdatesAvailable.none,
}) =>
    jsonEncode({
      'run': run == null ? null : _runToJson(run),
      'push': _pushToJson(push),
      if (releases != null) 'releases': _releasesToJson(releases),
      'updates': _updatesToJson(updates),
    });

String encodeMirrorOta({
  required int seq,
  required DeviceUpdateRun? run,
  required OtaPushState? push,
  List<FirmwareRelease>? releases,
  UpdatesAvailable updates = UpdatesAvailable.none,
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'seq': seq,
      'run': run == null ? null : _runToJson(run),
      'push': _pushToJson(push),
      if (releases != null) 'releases': _releasesToJson(releases),
      'updates': _updatesToJson(updates),
    });

MirrorOta? decodeMirrorOta(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['v'] != mirrorVersion || !map.containsKey('run')) {
      return null;
    }
    return MirrorOta(
      seq: (map['seq'] as num?)?.toInt() ?? 0,
      run: _runFromJson(map['run']),
      push: _pushFromJson(map['push']),
      releases: _releasesFromJson(map['releases']),
      updates: _updatesFromJson(map['updates']),
    );
  } catch (_) {
    return null;
  }
}

/// One update of the history with its units (the tablet's `OtaRuns` and
/// `OtaRunUnits` rows).
typedef MirrorOtaHistoryRun = (OtaRun, List<OtaRunUnit>);

/// As many of [runs] (newest first) as fit in [maxBytes]: one MQTT message
/// holds 128 KB, and a site with many units fills it in a few updates.
String encodeMirrorOtaHistory(
  List<MirrorOtaHistoryRun> runs, {
  int maxBytes = 100 * 1024,
}) {
  final out = <String>[];
  var size = 0;
  for (final (run, units) in runs) {
    final row = jsonEncode({
      'run': run.toJson(),
      'units': [for (final u in units) u.toJson()],
    });
    if (out.isNotEmpty && size + row.length > maxBytes) break;
    out.add(row);
    size += row.length;
  }
  return '{"v":$mirrorVersion,"runs":[${out.join(',')}]}';
}

List<MirrorOtaHistoryRun>? decodeMirrorOtaHistory(String payload) {
  try {
    final map = jsonDecode(payload);
    if (map is! Map || map['v'] != mirrorVersion) return null;
    final runs = map['runs'];
    if (runs is! List) return null;
    return [
      for (final r in runs)
        if (r is Map && r['run'] is Map && r['units'] is List)
          (
            // A central from before the Internet updates sends no source.
            OtaRun.fromJson({
              'source': 'manual',
              ...(r['run'] as Map).cast<String, dynamic>(),
            }),
            [
              for (final u in r['units'] as List)
                if (u is Map) OtaRunUnit.fromJson(u.cast<String, dynamic>()),
            ],
          ),
    ];
  } catch (_) {
    return null;
  }
}
