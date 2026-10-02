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
  final session = ref.watch(otaPushViewProvider.select((s) => s.storedOnBoard));
  return otaHeldOnBoard(rollout, session);
});

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

final otaRolloutOverlayProvider = Provider<OtaRolloutOverlay>((ref) {
  return otaRolloutOverlay(
    ref.watch(otaRolloutViewProvider),
    rootMac: ref.watch(rootElectionProvider.select((e) => e.rootMac)),
  );
});
