import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'ota_push_report.dart';
import 'ota_rollout_controller.dart';
import 'ota_rollout_state.dart';
import 'ota_rollout_words.dart';
import 'root_election_provider.dart';
import 'topology_provider.dart';

// What a rollout means for every screen: what the board holds, who is being
// updated, what the Rede maps draw and what their banner says. Pure
// functions over an [OtaRolloutState]; the providers only hand it over.
//
// (This file is read by topology_provider.dart for "who is being updated":
// nothing that file reads may watch the topology. What needs the topology
// takes it as an argument, or is a provider of its own further down.)

/// The rollout as every screen reads it. A provider of its own so a widget
/// test can hand a state over without a serial port or a database behind it.
final otaRolloutViewProvider =
    Provider<OtaRolloutState>((ref) => ref.watch(otaRolloutProvider));

// ── Who is being updated ────────────────────────────────────────────────────

/// The units whose row of a rollout is offered / downloading / verifying /
/// rebooting / in self-test, with the moment the row entered those states.
/// Two of them are equal when they say the same, so what watches this is
/// rebuilt when a unit enters or leaves, not on every percent.
class OtaUpdatingUnits {
  const OtaUpdatingUnits(this._since);

  static const none = OtaUpdatingUnits({});

  final Map<String, DateTime> _since;

  bool get isEmpty => _since.isEmpty;

  /// Since when [mac] is being updated; null = it is not.
  DateTime? since(String mac) => _since[mac];

  /// Still within [grace] at [now].
  bool updatingAt(String mac, DateTime now, Duration grace) {
    final since = _since[mac];
    return since != null && now.difference(since) < grace;
  }

  factory OtaUpdatingUnits.of(OtaRolloutState s) {
    Map<String, DateTime>? out;
    for (final f in s.families.values) {
      for (final u in f.units) {
        final since = u.activeSince;
        if (u.state.active && since != null) (out ??= {})[u.mac] = since;
      }
    }
    return out == null ? none : OtaUpdatingUnits(out);
  }

  @override
  bool operator ==(Object other) =>
      other is OtaUpdatingUnits && mapEquals(other._since, _since);

  @override
  int get hashCode => Object.hashAllUnordered(
      _since.entries.map((e) => Object.hash(e.key, e.value)));
}

final otaUpdatingUnitsProvider = Provider<OtaUpdatingUnits>(
    (ref) => OtaUpdatingUnits.of(ref.watch(otaRolloutViewProvider)));

// ── What the board holds ────────────────────────────────────────────────────

/// Family → version of the image the board holds. From the board itself
/// (the headers of OTA_ROLLOUT) when it answered; from what this session
/// saw stored ([session]) when it never did.
Map<SafrProductFamily, String> otaHeldOnBoard(
  OtaRolloutState rollout,
  Map<SafrProductFamily, String> session,
) {
  if (rollout.boardAnswered != true) return session;
  return {
    for (final f in rollout.families.values)
      if (f.holdsImage) f.family: f.target,
  };
}

final otaHeldOnBoardProvider = Provider<Map<SafrProductFamily, String>>((ref) {
  final rollout = ref.watch(otaRolloutViewProvider);
  final session =
      ref.watch(otaPushViewProvider.select((s) => s.storedOnBoard));
  return otaHeldOnBoard(rollout, session);
});

/// An image of [family] waits on the board and no unit got it: true while
/// the board says `staged`, and when only this session's memory is left.
bool otaNothingSentYet(OtaRolloutState rollout, SafrProductFamily family) {
  if (rollout.boardAnswered != true) return true;
  return rollout.families[family]?.state == SafrOtaRolloutState.staged;
}

// ── Who can be updated ──────────────────────────────────────────────────────

/// The units of a family the tablet knows, for the filter of a rollout and
/// for the number the confirmation names. The board makes its own queue
/// from its own table: units that are online, whose product is of the
/// family and that pass the filter (protocol §13.6).
class OtaRolloutCandidates {
  const OtaRolloutCandidates({
    required this.family,
    this.units = const [],
    this.unknownProduct = const [],
  });

  final SafrProductFamily family;

  /// Units that said a product of [family], by name.
  final List<TopologyNode> units;

  /// Units that look like one of [family] and never said their product:
  /// the board offers them nothing.
  final List<TopologyNode> unknownProduct;

  factory OtaRolloutCandidates.of(
    List<TopologyNode> nodes,
    SafrProductFamily family,
  ) {
    final units = <TopologyNode>[];
    final unknown = <TopologyNode>[];
    for (final n in nodes) {
      if (n.retired || unitFamily(n) != family) continue;
      final code = n.productCode;
      if (code != null && SafrProductFamily.ofCode(code) == family) {
        units.add(n);
      } else {
        unknown.add(n);
      }
    }
    int byName(TopologyNode a, TopologyNode b) => _nameOf(a)
        .toLowerCase()
        .compareTo(_nameOf(b).toLowerCase());
    return OtaRolloutCandidates(
      family: family,
      units: units..sort(byName),
      unknownProduct: unknown..sort(byName),
    );
  }

  /// The products present, in code order.
  List<SafrProduct> get products {
    final codes = {for (final n in units) n.productCode!}.toList()..sort();
    return [for (final c in codes) SafrProduct.fromCode(c)!];
  }

  /// The zones present, in alphabetical order. A unit with no zone is in
  /// none.
  List<String> get zones {
    final zones = {
      for (final n in units)
        if (n.zone?.isNotEmpty == true) n.zone!
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return zones;
  }

  bool _passes(TopologyNode n, SafrOtaFilter filter) => switch (filter.kind) {
        SafrOtaFilterKind.all => true,
        SafrOtaFilterKind.product => n.productCode == filter.product,
        SafrOtaFilterKind.zone => n.zone == filter.zone,
        SafrOtaFilterKind.unit => n.mac == filter.mac,
      };

  /// The units [filter] lets through, online or not.
  List<TopologyNode> passing(SafrOtaFilter filter) =>
      [for (final n in units) if (_passes(n, filter)) n];

  /// The units the board will queue, as far as the tablet can tell: the
  /// ones [filter] lets through that are online.
  List<TopologyNode> reachable(SafrOtaFilter filter) =>
      [for (final n in passing(filter)) if (n.online) n];
}

String _nameOf(TopologyNode n) =>
    n.name?.isNotEmpty == true ? n.name! : n.mac;

// ── The Rede maps ───────────────────────────────────────────────────────────

/// What a Rede map draws on one unit of a rollout. This is NOT the unit's
/// LED: the ring, the caption and the markers are drawings of the tablet.
class OtaUnitActivity {
  const OtaUnitActivity({
    required this.state,
    this.percent = 0,
    this.version = '',
    this.last = false,
  });

  final SafrOtaUnitState state;

  /// 0…100 while it downloads.
  final int percent;

  /// What the unit runs, as the rollout knows it; empty = not known.
  final String version;

  /// It is the mesh root: the board updates it after every other unit.
  final bool last;

  /// The ring is drawn.
  bool get updating => state.active;

  /// 0…1 for the ring while the image is on its way; null = the ring turns.
  double? get progress =>
      state == SafrOtaUnitState.downloading ? percent / 100 : null;

  /// Under the unit's name: "baixando 40 %", "aguardando", "por último".
  String get caption => switch (state) {
        SafrOtaUnitState.waiting => last ? 'por último' : 'aguardando',
        _ => otaUnitStateLog(state, percent),
      };

  @override
  bool operator ==(Object other) =>
      other is OtaUnitActivity &&
      other.state == state &&
      other.percent == percent &&
      other.version == version &&
      other.last == last;

  @override
  int get hashCode => Object.hash(state, percent, version, last);
}

/// What the Rede maps draw of the rollouts: unit by unit, and the unit the
/// image is travelling to now.
class OtaRolloutOverlay {
  const OtaRolloutOverlay({this.units = const {}, this.downloading});

  static const none = OtaRolloutOverlay();

  final Map<String, OtaUnitActivity> units;

  /// MAC of the unit that is downloading: packets travel to it.
  final String? downloading;

  bool get isEmpty => units.isEmpty;

  OtaUnitActivity? operator [](String mac) => units[mac];

  @override
  bool operator ==(Object other) =>
      other is OtaRolloutOverlay &&
      other.downloading == downloading &&
      mapEquals(other.units, units);

  @override
  int get hashCode => Object.hash(
        downloading,
        Object.hashAllUnordered(
            units.entries.map((e) => Object.hash(e.key, e.value))),
      );
}

/// The rollout a Rede map shows: the one that runs, else the one this
/// session saw end — until its outcome is closed on the banner
/// ([dismissed] = its `endedAt`). A rollout that was over before the app
/// looked is on the update screen only.
OtaFamilyRollout? otaRolloutOnTheMap(OtaRolloutState s, DateTime? dismissed) {
  final running = s.running;
  if (running != null) return running;
  OtaFamilyRollout? latest;
  for (final f in s.families.values) {
    final ended = f.endedAt;
    if (!f.ended || ended == null || ended == dismissed) continue;
    if (latest == null || ended.isAfter(latest.endedAt!)) latest = f;
  }
  return latest;
}

OtaRolloutOverlay otaRolloutOverlay(
  OtaRolloutState s, {
  String? rootMac,
  DateTime? dismissed,
}) {
  final f = otaRolloutOnTheMap(s, dismissed);
  if (f == null || f.units.isEmpty) return OtaRolloutOverlay.none;
  String? downloading;
  final units = <String, OtaUnitActivity>{};
  for (final u in f.units) {
    if (f.running && u.state == SafrOtaUnitState.downloading) {
      downloading ??= u.mac;
    }
    units[u.mac] = OtaUnitActivity(
      state: u.state,
      percent: u.percent,
      version: u.version,
      last: u.mac == rootMac && u.state == SafrOtaUnitState.waiting,
    );
  }
  return OtaRolloutOverlay(units: units, downloading: downloading);
}

/// The way of the image from the board to the unit with [mac], for the
/// packets on a Rede map: [central] (the CENTRAL chip, where the board is),
/// then the unit's parents from the mesh root down, then the unit. Null
/// when the unit is not on the map.
List<String>? otaDownloadPath(
  Iterable<TopologyNode> nodes,
  String mac,
  String central,
) {
  final byMac = {
    for (final n in nodes)
      if (n.layer > 0) n.mac: n
  };
  var cursor = byMac[mac];
  if (cursor == null) return null;
  final up = <String>[mac];
  var guard = 0;
  while (cursor != null && guard++ < 8) {
    final parent = cursor.parentMac;
    if (parent == null || !byMac.containsKey(parent) || up.contains(parent)) {
      break;
    }
    up.add(parent);
    cursor = byMac[parent];
  }
  up.add(central);
  return up.reversed.toList();
}

/// `endedAt` of the rollout whose outcome the operator closed on the Rede
/// banner. The outcome of another rollout shows again.
final otaRolloutDismissedProvider = StateProvider<DateTime?>((_) => null);

final otaRolloutOverlayProvider = Provider<OtaRolloutOverlay>((ref) {
  return otaRolloutOverlay(
    ref.watch(otaRolloutViewProvider),
    rootMac: ref.watch(rootElectionProvider.select((e) => e.rootMac)),
    dismissed: ref.watch(otaRolloutDismissedProvider),
  );
});

// ── The banner ──────────────────────────────────────────────────────────────

enum OtaRolloutBannerKind { rolling, paused, done, partial }

/// One line for the strip on top of the Rede maps.
class OtaRolloutBanner {
  const OtaRolloutBanner({
    required this.kind,
    required this.line,
    this.tail,
    this.progress,
    this.endedAt,
  });

  final OtaRolloutBannerKind kind;

  /// "Atualização: placa → Sirene hall (2 de 5)".
  final String line;

  /// How far: "40 %", "verificando". Apart from [line] so a narrow screen
  /// never cuts it off.
  final String? tail;

  /// 0…1 of the unit that downloads; null = no bar.
  final double? progress;

  /// Set for an outcome: what closing the banner remembers.
  final DateTime? endedAt;

  bool get running =>
      kind == OtaRolloutBannerKind.rolling ||
      kind == OtaRolloutBannerKind.paused;

  String get fullLine => tail == null ? line : '$line · $tail';

  OtaReportTone get tone => switch (kind) {
        OtaRolloutBannerKind.rolling => OtaReportTone.progress,
        OtaRolloutBannerKind.paused => OtaReportTone.warning,
        OtaRolloutBannerKind.done => OtaReportTone.good,
        OtaRolloutBannerKind.partial => OtaReportTone.warning,
      };

  @override
  bool operator ==(Object other) =>
      other is OtaRolloutBanner &&
      other.kind == kind &&
      other.line == line &&
      other.tail == tail &&
      other.progress == progress &&
      other.endedAt == endedAt;

  @override
  int get hashCode => Object.hash(kind, line, tail, progress, endedAt);
}

/// Null when there is nothing to say. [nameOf]: the name of a unit by its
/// MAC (the MAC itself when it has none).
OtaRolloutBanner? otaRolloutBanner(
  OtaRolloutState s, {
  required String Function(String mac) nameOf,
  DateTime? dismissed,
}) {
  final f = otaRolloutOnTheMap(s, dismissed);
  if (f == null) return null;
  final total = f.unitCount;

  switch (f.state) {
    case SafrOtaRolloutState.rolling:
      final u = f.current;
      if (u == null) {
        return OtaRolloutBanner(
          kind: OtaRolloutBannerKind.rolling,
          line: 'Atualização: placa → ${otaUnitsWord(f.family)} '
              '(${f.settledCount} de $total concluídos)',
          tail: 'próximo',
        );
      }
      final index = (f.settledCount + 1).clamp(1, total < 1 ? 1 : total);
      return OtaRolloutBanner(
        kind: OtaRolloutBannerKind.rolling,
        line: 'Atualização: placa → ${nameOf(u.mac)} ($index de $total)',
        tail: u.state == SafrOtaUnitState.downloading
            ? '${u.percent} %'
            : otaUnitStateLog(u.state, u.percent),
        progress:
            u.state == SafrOtaUnitState.downloading ? u.percent / 100 : null,
      );

    case SafrOtaRolloutState.paused:
      final u = f.current;
      return OtaRolloutBanner(
        kind: OtaRolloutBannerKind.paused,
        line: 'Atualização pausada'
            '${f.pauseCause == OtaPauseCause.alarm ? ' por alarme' : ''}: '
            '${f.settledCount} de $total concluídos'
            '${u == null ? '' : ' · ${nameOf(u.mac)} termina a sua'}',
        tail: 'pausado',
      );

    case SafrOtaRolloutState.done:
      return OtaRolloutBanner(
        kind: OtaRolloutBannerKind.done,
        line: f.skippedCount == 0
            ? 'Atualização concluída: ${f.doneCount} de $total dispositivos '
                'na versão ${f.target}'
            : 'Atualização concluída: ${otaCountsText(f)} · versão '
                '${f.target}',
        endedAt: f.endedAt,
      );

    case SafrOtaRolloutState.partial:
      return OtaRolloutBanner(
        kind: OtaRolloutBannerKind.partial,
        line: 'Atualização parcial: ${otaCountsText(f)} · versão ${f.target}',
        endedAt: f.endedAt,
      );

    case SafrOtaRolloutState.idle || SafrOtaRolloutState.staged:
      return null;
  }
}

final otaRolloutBannerProvider = Provider<OtaRolloutBanner?>((ref) {
  final names = <String, String>{
    for (final n in ref.watch(topologyProvider)) n.mac: _nameOf(n),
  };
  return otaRolloutBanner(
    ref.watch(otaRolloutViewProvider),
    nameOf: (mac) => names[mac] ?? mac,
    dismissed: ref.watch(otaRolloutDismissedProvider),
  );
});
