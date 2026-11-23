import '../domain/safr/safr_v2_payloads.dart';
import 'central_mirror_codec.dart';

// Eventos, grouped (2026-11-24). The event table has one line per unit and
// per fact; one thing that happens to the network writes many of them — five
// units that lost their path together are five lines, plus the "sem
// comunicação" and "voltou a comunicar" of each. Here the lines are put
// together for the screen, and only for the screen: nothing is merged or
// erased in the table, and the "Linhas" view lists them one by one.
//
//   - a NETWORK INCIDENT: the OUTAGE_REPORTs (protocol §7.17) whose times
//     with no path overlap — each says how long it lasted, so when it began
//     is known — and the supervision lines of that time. A unit that left
//     its parent for a better signal reports it the same way (v3.15), so
//     it stands in the incident it began; moves that simply worked are no
//     incident, each stays a line;
//   - a COMMUNICATION GAP: a unit's "sem comunicação" and the "voltou a
//     comunicar" that followed it, as one line saying how long;
//   - everything else stays a line.

/// What Eventos lists in its grouped view.
sealed class EventGroup {
  const EventGroup();

  /// Where it stands in the list: its newest line.
  DateTime get at;

  /// Every line in it, newest first.
  List<MirrorPanelEvent> get lines;
}

/// A line by itself.
class SingleEvent extends EventGroup {
  const SingleEvent(this.event);
  final MirrorPanelEvent event;

  @override
  DateTime get at => event.at;

  @override
  List<MirrorPanelEvent> get lines => [event];
}

/// A unit went silent and was heard again.
class CommGap extends EventGroup {
  const CommGap({required this.missing, required this.restored});
  final MirrorPanelEvent missing;
  final MirrorPanelEvent restored;

  Duration get duration => restored.at.difference(missing.at);

  @override
  DateTime get at => restored.at;

  @override
  List<MirrorPanelEvent> get lines => [restored, missing];
}

/// One unit's part in a network incident.
class IncidentUnit {
  IncidentUnit({required this.event, required this.report});

  /// Its OUTAGE_REPORT line.
  final MirrorPanelEvent event;
  final SafrOutageReportPayload report;

  String? get mac => event.mac;

  /// As the line names it.
  String get name => event.who ?? event.mac ?? 'Dispositivo';

  /// What it says happened, without how long. A move names other units:
  /// the line the central wrote has their names.
  List<String> get words {
    if (report.cause == SafrOutageCause.moved) {
      final i = event.text.indexOf(' — ');
      final said = i < 0 ? event.text : event.text.substring(i + 3);
      final parts = said.split(' · ');
      // Without "ficou N s sem caminho até a central": the bar says it.
      return report.cleanMove || parts.length < 2 ? parts : parts.sublist(1);
    }
    return report.detailWords();
  }

  DateTime get to => event.at;
  DateTime get from => event.at.subtract(report.duration);

  /// It says the break was its own: it lost its parent, its session with
  /// the central, the root's role — not "the unit above me had no path".
  bool get origin =>
      report.cause != SafrOutageCause.parentSilent &&
      report.cause != SafrOutageCause.unknown;
}

/// Units that had no path to the central at the same time.
class NetworkIncident extends EventGroup {
  NetworkIncident({required this.units, required this.related});

  /// Newest report first.
  final List<IncidentUnit> units;

  /// The supervision lines of that time ("sem comunicação", "voltou a
  /// comunicar"), newest first.
  final List<MirrorPanelEvent> related;

  DateTime get from =>
      units.map((u) => u.from).reduce((a, b) => a.isBefore(b) ? a : b);
  DateTime get to =>
      units.map((u) => u.to).reduce((a, b) => a.isAfter(b) ? a : b);
  Duration get duration => to.difference(from);

  /// Where it began, as far as the units say: the ones whose own link broke;
  /// when none says so, the first to lose the path.
  List<IncidentUnit> get origins {
    final own = [
      for (final u in units)
        if (u.origin) u
    ];
    if (own.isNotEmpty || units.length < 2) return own;
    final first = from.add(_sameMoment);
    return [
      for (final u in units)
        if (!u.from.isAfter(first)) u
    ];
  }

  /// Every unit named an origin: nothing singles one out.
  bool get originsAreAll => origins.length == units.length;

  /// The network re-forming **on purpose** (decided 2026-11-24): a unit of
  /// it left its parent by itself for a stronger signal, and none got lost
  /// trying — none had to restart itself. News, not a trouble: the units
  /// under the one that moved are without a path for the seconds it takes,
  /// and that is how a reorganisation looks. A unit that restarted itself
  /// was lost: the incident is then a trouble, whatever began it.
  bool get reorganisation =>
      restarted == 0 &&
      units.any((u) => u.report.cause == SafrOutageCause.moved);

  int get restarted => units.where((u) => u.report.restarts > 0).length;
  List<IncidentUnit> get backAsRoot => [
        for (final u in units)
          if (u.report.end == SafrOutageEnd.asRoot) u
      ];

  @override
  DateTime get at =>
      related.isEmpty || !related.first.at.isAfter(to) ? to : related.first.at;

  @override
  List<MirrorPanelEvent> get lines {
    final all = [for (final u in units) u.event, ...related];
    all.sort((a, b) => b.at.compareTo(a.at));
    return all;
  }
}

/// Two outages this close are one incident.
const _slack = Duration(seconds: 10);

/// A supervision line this long after the path is back still belongs to it.
const _after = Duration(seconds: 45);

/// Units that lost the path within this of the first are "the first".
const _sameMoment = Duration(seconds: 3);

SafrOutageReportPayload _reportOf(PanelOutage o) => SafrOutageReportPayload(
      duration: o.duration,
      cause: SafrOutageCause.fromWire(o.cause),
      flags: o.flags,
      rescues: o.rescues,
      rescuesMissed: o.rescuesMissed,
      anyRounds: o.anyRounds,
      restarts: o.restarts,
      end: SafrOutageEnd.fromWire(o.end),
    );

/// [events] with the lines of a reorganisation ([NetworkIncident
/// .reorganisation]) listed as news: each unit's own line and the "sem
/// comunicação" / "voltou a comunicar" of those seconds. A unit that went
/// silent in it and was **not** heard again keeps its trouble: it is lost.
/// What the table and the cloud hold is not touched — the kind is decided
/// here, when the lines are listed, because a unit's line may arrive before
/// the line of the unit that moved.
List<MirrorPanelEvent> listReorganisationsAsNews(
    List<MirrorPanelEvent> events) {
  final news = <MirrorPanelEvent>{};
  for (final g in groupEvents(events)) {
    if (g is! NetworkIncident || !g.reorganisation) continue;
    news.addAll(g.units.map((u) => u.event));
    final back = {
      for (final e in g.related)
        if (e.comm == PanelCommChange.restored) e.mac
    };
    for (final e in g.related) {
      if (e.comm == PanelCommChange.restored || back.contains(e.mac)) {
        news.add(e);
      }
    }
  }
  if (news.isEmpty) return events;
  return [
    for (final e in events)
      news.contains(e) ? e.withKind(PanelEventKind.info) : e
  ];
}

/// The lines of [events] (any order) put together, newest first.
List<EventGroup> groupEvents(List<MirrorPanelEvent> events) {
  final used = <MirrorPanelEvent>{};
  final groups = <EventGroup>[];

  // 1. Outages that overlap in time are one incident.
  final units = [
    for (final e in events)
      if (e.outage != null) IncidentUnit(event: e, report: _reportOf(e.outage!))
  ]..sort((a, b) => a.from.compareTo(b.from));
  final clusters = <List<IncidentUnit>>[];
  DateTime? clusterTo;
  for (final u in units) {
    if (clusterTo != null && !u.from.isAfter(clusterTo.add(_slack))) {
      clusters.last.add(u);
      if (u.to.isAfter(clusterTo)) clusterTo = u.to;
    } else {
      clusters.add([u]);
      clusterTo = u.to;
    }
  }

  // 2. ...with the supervision lines of that time: of its own units until a
  //    little after, of any unit while it lasted.
  final comm = [
    for (final e in events)
      if (e.comm != null) e
  ];
  for (final cluster in clusters) {
    final from =
        cluster.map((u) => u.from).reduce((a, b) => a.isBefore(b) ? a : b);
    final to = cluster.map((u) => u.to).reduce((a, b) => a.isAfter(b) ? a : b);
    final macs = {for (final u in cluster) u.mac};
    final related = <MirrorPanelEvent>[];
    if (cluster.every((u) => u.report.cleanMove)) continue;
    for (final e in comm) {
      if (used.contains(e) || e.at.isBefore(from)) continue;
      final own = macs.contains(e.mac);
      if (e.at.isAfter(own ? to.add(_after) : to)) continue;
      related.add(e);
    }
    related.sort((a, b) => b.at.compareTo(a.at));
    cluster.sort((a, b) => b.to.compareTo(a.to));
    // Units that moved to a better path and got there, and nothing else:
    // a reorganisation that worked is news, each on its own line.
    if (cluster.every((u) => u.report.cleanMove)) continue;
    for (final u in cluster) {
      used.add(u.event);
    }
    used.addAll(related);
    groups.add(NetworkIncident(units: cluster, related: related));
  }

  // 3. A unit's "sem comunicação" and the "voltou a comunicar" after it.
  final oldestFirst = [
    for (final e in comm)
      if (!used.contains(e)) e
  ]..sort((a, b) => a.at.compareTo(b.at));
  final open = <String, MirrorPanelEvent>{};
  for (final e in oldestFirst) {
    final mac = e.mac;
    if (mac == null) continue;
    if (e.comm == PanelCommChange.missing) {
      open[mac] = e;
    } else if (open.remove(mac) case final missing?) {
      groups.add(CommGap(missing: missing, restored: e));
      used
        ..add(missing)
        ..add(e);
    }
  }

  // 4. The rest, line by line.
  for (final e in events) {
    if (!used.contains(e)) groups.add(SingleEvent(e));
  }

  // Newest first; equal times keep the order the lines came in.
  final order = {for (var i = 0; i < events.length; i++) events[i]: i};
  int rank(EventGroup g) => g.lines.map((e) => order[e] ?? 0).reduce(_min);
  groups.sort((a, b) {
    final byTime = b.at.compareTo(a.at);
    return byTime != 0 ? byTime : rank(a).compareTo(rank(b));
  });
  return groups;
}

int _min(int a, int b) => a < b ? a : b;
