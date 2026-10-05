import 'dart:convert';

import '../../../core/database/app_database.dart' show OtaRun, OtaRunUnit;
import '../domain/safr/safr_product.dart';
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

/// Central → cloud, only while watched: the firmware update that runs (or
/// the last one), and the image on its way to the board.
String mirrorOtaTopic(String identityId) => '$identityId/ota';

/// Central → cloud, when a phone asks: the updates kept on the tablet.
String mirrorOtaHistoryTopic(String identityId) => '$identityId/ota/history';

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

/// Phone → central: make this unit blink (IDENTIFY). The one command a
/// phone may ask for: it lights an LED and changes nothing else.
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

class MirrorState {
  const MirrorState({
    required this.seq,
    required this.at,
    required this.link,
    required this.nodes,
  });

  final int seq;

  /// When the central took the snapshot (its clock).
  final DateTime at;

  /// The central's board link (`SerialLinkStatus` name).
  final String link;
  final List<TopologyNode> nodes;
}

Map<String, dynamic> _unitToJson(TopologyNode n, {bool volatile = true}) => {
      'mac': n.mac,
      'role': n.role.wire,
      'layer': n.layer,
      if (n.parentMac != null) 'parent': n.parentMac,
      if (volatile && n.rssi != null) 'rssi': n.rssi,
      if (n.batteryPct != null) 'bat': n.batteryPct,
      'online': n.online,
      'heard': n.heard,
      if (n.updating) 'updating': true,
      if (volatile) 'lastSeen': n.lastSeenAt.toUtc().toIso8601String(),
      if (n.alarmLatched) 'alarm': true,
      if (n.alarmLatchedAt != null)
        'alarmAt': n.alarmLatchedAt!.toUtc().toIso8601String(),
      if (n.name != null) 'name': n.name,
      if (n.zone != null) 'zone': n.zone,
      if (n.productCode != null) 'product': n.productCode,
      if (n.hwRev != null) 'hw': n.hwRev,
      if (n.fwVersion != null) 'fw': n.fwVersion,
      if (n.boardState != null) 'boardState': n.boardState!.wire,
      if (n.boardFlags != 0) 'boardFlags': n.boardFlags,
      if (n.parentCandidates.isNotEmpty)
        'candidates': [
          for (final c in n.parentCandidates) [c.mac, c.rssi],
        ],
    };

String encodeMirrorState({
  required int seq,
  required DateTime at,
  required String link,
  required List<TopologyNode> nodes,
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'seq': seq,
      'at': at.toUtc().toIso8601String(),
      'link': link,
      'units': [for (final n in nodes) _unitToJson(n)],
    });

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
    batteryPct: (raw['bat'] as num?)?.toInt(),
    online: raw['online'] == true,
    heard: raw['heard'] == true,
    updating: raw['updating'] == true,
    lastSeenAt: time(raw['lastSeen']) ?? fallbackSeen,
    alarmLatched: raw['alarm'] == true,
    alarmLatchedAt: time(raw['alarmAt']),
    name: raw['name'] as String?,
    zone: raw['zone'] as String?,
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
    return MirrorState(
      seq: (map['seq'] as num?)?.toInt() ?? 0,
      at: at,
      link: map['link'] as String? ?? 'disconnected',
      nodes: [
        for (final u in units)
          if (_unitFromJson(u, at) case final node?) node,
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
/// - [identifyFailed]: an IDENTIFY a phone asked for got no confirmation.
typedef MirrorEvent = ({String kind, String mac, int arg});

abstract final class MirrorEventKind {
  static const identify = 'identify';
  static const identifySending = 'identify_sending';
  static const identifyFailed = 'identify_failed';
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
/// parentMac, msgType, eventCode, uptimeS]`: short, because this is the
/// message that is sent several times a second.
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
          for (final e in events) [e.kind, e.mac, e.arg],
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
              ),
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
  const MirrorAlarm({required this.mac, this.name, this.zone, this.since});

  final String mac;
  final String? name;
  final String? zone;
  final DateTime? since;
}

class MirrorAlarms {
  const MirrorAlarms({required this.at, required this.alarms});

  /// When the central published this list (its clock).
  final DateTime at;
  final List<MirrorAlarm> alarms;
}

List<Map<String, dynamic>> _alarmsToJson(List<MirrorAlarm> alarms) => [
      for (final a in alarms)
        {
          'mac': a.mac,
          if (a.name?.isNotEmpty == true) 'name': a.name,
          if (a.zone?.isNotEmpty == true) 'zone': a.zone,
          if (a.since != null) 'since': a.since!.toUtc().toIso8601String(),
        },
    ];

String encodeMirrorAlarms({
  required DateTime at,
  required List<MirrorAlarm> alarms,
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'at': at.toUtc().toIso8601String(),
      'alarms': _alarmsToJson(alarms),
    });

/// The list without the time it was published: the same alarms held = the
/// same signature = nothing new to publish.
String mirrorAlarmsSignature(List<MirrorAlarm> alarms) =>
    jsonEncode(_alarmsToJson(alarms));

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
            ),
      ],
    );
  } catch (_) {
    return null;
  }
}

// ── ota ─────────────────────────────────────────────────────────────────────

/// The firmware update as the tablet's "Atualizar dispositivos" has it.
class MirrorOta {
  const MirrorOta({required this.seq, this.run, this.push});

  final int seq;

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

/// The update without its number: the same body = nothing new to publish.
String mirrorOtaBody(DeviceUpdateRun? run, OtaPushState? push) => jsonEncode({
      'run': run == null ? null : _runToJson(run),
      'push': _pushToJson(push),
    });

String encodeMirrorOta({
  required int seq,
  required DeviceUpdateRun? run,
  required OtaPushState? push,
}) =>
    jsonEncode({
      'v': mirrorVersion,
      'seq': seq,
      'run': run == null ? null : _runToJson(run),
      'push': _pushToJson(push),
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
            OtaRun.fromJson((r['run'] as Map).cast<String, dynamic>()),
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
