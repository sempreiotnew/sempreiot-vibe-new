import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../domain/safr/safr_v2_frame.dart' show safrCentralMac;
import '../domain/safr/safr_v2_payloads.dart';
import 'alarm_latch_provider.dart';
import 'central_mirror_codec.dart';
import 'central_mirror_viewer.dart';
import 'topology_provider.dart';

/// What Principal says about the system (2026-11-19): how many units, how
/// many in alarm, how many needing attention, and the last events — the
/// same picture on the central's tablet (from its own registry and event
/// table) and on a user's phone (from the central's retained alarm
/// message, `MirrorPanel`).
///
/// "Needs attention" is what the Rede legend already flags, nothing new: a
/// unit that is not heard, or one whose battery is under 20 %. What a
/// trouble finally is waits for the product's definition.
class PanelView {
  const PanelView({
    required this.known,
    this.total = 0,
    this.alarms = 0,
    this.troubles = 0,
    this.troubleList = const [],
    this.events = const [],
    this.eventsKnown = true,
  });

  /// Nothing arrived yet (a phone before the central's message).
  static const unknown = PanelView(known: false, eventsKnown: false);

  final bool known;
  final int total;
  final int alarms;
  final int troubles;
  final List<MirrorTrouble> troubleList;
  final List<MirrorPanelEvent> events;

  /// False on a phone whose central runs an app that does not publish the
  /// numbers and the events yet: only its alarms are known.
  final bool eventsKnown;

  int get ok => (total - alarms - troubles).clamp(0, total);
}

/// A unit's battery under this is "needs attention" (as the Rede legend).
const panelLowBatteryPct = 20;

/// The name an event line gives a unit: its name, else where it is, else
/// its MAC.
String _unitName(TopologyNode n) => n.name?.isNotEmpty == true
    ? n.name!
    : n.address?.isNotEmpty == true
        ? n.address!
        : n.mac;

String _eventWords(SafrEventCode code) => switch (code) {
      SafrEventCode.none => 'estado normal',
      SafrEventCode.smokeAlarm => 'alarme de fumaça',
      SafrEventCode.heatAlarm => 'alarme de calor',
      SafrEventCode.smokeRising => 'pré-alarme (fumaça subindo)',
      SafrEventCode.manualTest => 'teste manual',
      SafrEventCode.tamper => 'tamper aberto',
      SafrEventCode.battLow => 'bateria baixa',
      SafrEventCode.battCritical => 'bateria crítica',
      SafrEventCode.sensorFault => 'falha do sensor',
      SafrEventCode.commFault => 'sem comunicação',
      SafrEventCode.acLost => 'sem energia da rede elétrica',
      SafrEventCode.restore => 'voltou ao normal',
      SafrEventCode.rfInterference => 'interferência de rádio',
      SafrEventCode.unknown => 'evento desconhecido',
    };

String _diagnosticWords(String kind) => switch (kind) {
      'auth_failed' => 'quadro recusado (assinatura inválida)',
      'crc_failed' => 'quadro recusado (erro de transmissão)',
      'foreign_system' => 'quadro de outra instalação',
      'replay' => 'quadro repetido, ignorado',
      _ => 'quadro ilegível',
    };

String _capitalized(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// One row of the event table, in words. Null for a row that is not news:
/// the 60 s re-announcement of an alarm already listed.
MirrorPanelEvent? panelEventOf(
    DeviceEvent row, String Function(String mac) nameOf) {
  Map<String, dynamic> detail = const {};
  try {
    final decoded = jsonDecode(row.detailJson);
    if (decoded is Map<String, dynamic>) detail = decoded;
  } catch (_) {
    // A row without details still says who and how serious.
  }
  if (detail['retx'] == true) return null;

  final central = row.deviceMac == safrCentralMac;
  final who = central
      ? 'Central'
      : row.deviceMac == '?'
          ? 'Dispositivo desconhecido'
          : nameOf(row.deviceMac);
  final description = detail['description'];
  final String text;
  if (row.errorKind != null) {
    text = '$who — ${_diagnosticWords(row.errorKind!)}';
  } else if (detail['kind'] == 'device_missing') {
    text = '$who — sem comunicação';
  } else if (detail['kind'] == 'device_restored') {
    text = '$who — voltou a comunicar';
  } else if (description is String && description.isNotEmpty) {
    text = central ? _capitalized(description) : '$who — $description';
  } else if (row.eventCode != null) {
    text = '$who — ${_eventWords(SafrEventCode.fromWire(row.eventCode!))}';
  } else {
    text = '$who — evento';
  }
  // An event the board kept and handed over later (its journal, protocol
  // §7.9 — every one of them again after the app is installed afresh): it
  // happened when the unit says, not when the tablet got it. Without a
  // believable time of its own it is listed as old, never as "now".
  var at = row.receivedAt;
  var words = text;
  if (detail['historic'] == true) {
    final own = DateTime.tryParse(detail['device_ts'] as String? ?? '');
    if (own != null &&
        own.year >= _firstBelievableYear &&
        !own.isAfter(row.receivedAt)) {
      at = own.toUtc();
    } else {
      words = '$text (registro antigo, hora desconhecida)';
    }
  }
  return MirrorPanelEvent(at: at, severity: row.severity, text: words);
}

/// A unit that never got the time counts from 1970: such a time is not the
/// event's.
const _firstBelievableYear = 2024;

/// The newest [limit] rows of the tablet's event table, live.
final _eventRowsProvider =
    StreamProvider.family<List<DeviceEvent>, int>((ref, limit) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.deviceEvents)
        ..orderBy([(t) => OrderingTerm.desc(t.id)])
        ..limit(limit))
      .watch();
});

/// The tablet's last [limit] events in words, newest first.
final localPanelEventsProvider =
    Provider.family<List<MirrorPanelEvent>, int>((ref, limit) {
  // More rows than asked: re-announcements are skipped after the read, and
  // a journal handed over late puts old events among the newest rows —
  // they are sorted back to when they happened.
  final rows = ref.watch(_eventRowsProvider(limit * 5)).valueOrNull ?? const [];
  final names = {
    for (final n in ref.watch(topologyProvider)) n.mac: _unitName(n),
  };
  final out = <MirrorPanelEvent>[];
  for (final row in rows) {
    final e = panelEventOf(row, (mac) => names[mac] ?? mac);
    if (e == null) continue;
    out.add(e);
  }
  // Newest first by when it happened (equal times keep the table's order).
  final order = {for (var i = 0; i < out.length; i++) out[i]: i};
  out.sort((x, y) {
    final byTime = y.at.compareTo(x.at);
    return byTime != 0 ? byTime : order[x]!.compareTo(order[y]!);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
});

/// The tablet's own picture.
final localPanelProvider = Provider<PanelView>((ref) {
  final units = [
    for (final n in ref.watch(topologyProvider))
      if (n.layer > 0 && !n.awaitingSignal) n,
  ];
  final alarms = ref.watch(latchedAlarmsProvider).valueOrNull ?? const [];
  final inAlarm = {for (final d in alarms) d.mac};
  final troubles = <MirrorTrouble>[];
  for (final n in units) {
    if (inAlarm.contains(n.mac)) continue;
    if (!n.online) {
      troubles
          .add(MirrorTrouble(name: _unitName(n), why: MirrorTrouble.offline));
    } else if (n.batteryPct != null && n.batteryPct! < panelLowBatteryPct) {
      troubles
          .add(MirrorTrouble(name: _unitName(n), why: MirrorTrouble.battery));
    }
  }
  return PanelView(
    known: true,
    total: units.length,
    alarms: alarms.length,
    troubles: troubles.length,
    troubleList: troubles,
    events: ref.watch(localPanelEventsProvider(MirrorPanel.maxEvents)),
  );
});

/// What the central publishes of it (null off the tablet): the numbers and
/// the last events, for the retained alarm message.
final localMirrorPanelProvider = Provider<MirrorPanel?>((ref) {
  if (!AppConfig.isCentral) return null;
  final view = ref.watch(localPanelProvider);
  return MirrorPanel(
    total: view.total,
    troubles: view.troubles,
    troubleList: view.troubleList.take(MirrorPanel.maxTroubles).toList(),
    events: view.events,
  );
});

/// Principal's picture: the tablet's own ([centralId] null) or the viewed
/// central's, from its retained alarm message.
final panelViewProvider = Provider.family<PanelView, String?>((ref, centralId) {
  if (centralId == null) return ref.watch(localPanelProvider);
  final msg = ref.watch(centralAlarmsProvider(centralId));
  if (msg == null) return PanelView.unknown;
  final panel = msg.panel;
  if (panel == null) {
    return PanelView(
      known: true,
      total: msg.alarms.length,
      alarms: msg.alarms.length,
      eventsKnown: false,
    );
  }
  return PanelView(
    known: true,
    total: panel.total,
    alarms: msg.alarms.length,
    troubles: panel.troubles,
    troubleList: panel.troubleList,
    events: panel.events,
  );
});

/// The tablet's full history for "Ver todos": its last [historyLimit]
/// events.
const panelHistoryLimit = 500;
