import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_v2_frame.dart' show safrCentralMac;
import 'central_mirror_viewer.dart';
import 'serial_link_provider.dart';
import 'topology_provider.dart';

/// Who bridges the mesh to the board right now — or that the mesh is still
/// deciding.
///
/// A root is a unit at level 1: attached to the board's access point
/// directly. Mesh-Lite lets every unit that hears the access point attach to
/// it, so for a few seconds there can be two. **The board holds one root**
/// (2026-10-29, `link_mesh_board.c`): it refuses a second one, which bans
/// itself from level 1 and joins the mesh under a parent node. Two ROOT
/// badges together are therefore a passing state, never a stable mesh —
/// until 2026-10-29 the board let the newest root replace the old one, two
/// roots took turns on it every 4 s and the map called that legitimate; it
/// was the bench's broken afternoon. An election is a *change*: a settled root vanished, or
/// the set of level-1 units moved and has not held still for
/// [rootElectionSettle] yet. After the root dies, Mesh-Lite lets every
/// survivor that hears the board associate to it; for up to ~10 s two or
/// three units genuinely are level 1, each reporting itself as root, until
/// the weaker ones back off — or do not. Nobody, not even the board, can name
/// the roots during that window, so the map must not: it shows the candidates
/// and "reorganizando" instead. The units earn the ROOT badge together once
/// the set has held for [rootElectionSettle].
class RootElectionState {
  const RootElectionState({
    this.roots = const {},
    this.electingSince,
    this.candidates = const {},
    this.settlingSet,
    this.settlingSince,
    this.lostRoots = const {},
    this.electedMac,
    this.electedAfter,
    this.electedAt,
  });

  /// The settled roots; empty while electing, or with no mesh at all.
  final Set<String> roots;

  /// The one root when exactly one is settled, else null (several roots,
  /// an election, or no mesh). For what needs a single unit, such as the
  /// update's "root last"; everything that draws a unit asks [isRoot].
  String? get rootMac => roots.length == 1 ? roots.first : null;

  bool isRoot(String mac) => roots.contains(mac);

  /// Non-null while an election runs (a settled root was lost).
  final DateTime? electingSince;

  /// Online level-1 units right now — the contenders while electing.
  final Set<String> candidates;

  /// The level-1 set waiting to hold still, and since when (settle timer).
  final Set<String>? settlingSet;
  final DateTime? settlingSince;

  /// The roots this election replaces (empty when none was known).
  final Set<String> lostRoots;

  /// The first lost root, for the banner's one line.
  String? get lostRootMac => lostRoots.isEmpty ? null : lostRoots.first;

  /// The last election's outcome — who won, how long it took and when —
  /// kept while that root holds, so the Rede banner can say so for a few
  /// seconds after. Null when the election settled on several roots.
  final String? electedMac;
  final Duration? electedAfter;
  final DateTime? electedAt;

  bool get electing => electingSince != null;

  Duration elapsed(DateTime now) =>
      electingSince == null ? Duration.zero : now.difference(electingSince!);

  /// A failover is supposed to finish well inside this; past it the strip
  /// turns into a trouble.
  bool overdue(DateTime now) => elapsed(now) > rootElectionOverdue;

  static const none = RootElectionState();
}

const rootElectionSettle = Duration(seconds: 3);
const rootElectionOverdue = Duration(seconds: 30);

bool _same(Set<String>? a, Set<String> b) =>
    a != null && a.length == b.length && a.containsAll(b);

/// Pure step: previous state + the online level-1 units now → next state.
///
/// - the same set as the settled roots → settled, as it was;
/// - a set that differs → it must hold still for [rootElectionSettle], then
///   every unit in it is a root (one or several);
/// - a settled root missing from the set → an election ("root lost") until
///   the set holds still;
/// - none, after roots were known (or mid-election) → electing;
/// - none, and no root was ever known → nothing (empty mesh, not an election).
/// A fresh start, with one unit or several, settles silently: no election is
/// declared unless a root was known and vanished.
RootElectionState stepRootElection(
  RootElectionState prev,
  Set<String> candidates,
  DateTime now,
) {
  // The roots an election replaces: the settled ones that are gone, kept
  // for as long as the election runs.
  final lost = prev.electing
      ? prev.lostRoots
      : prev.roots.where((m) => !candidates.contains(m)).toSet();

  if (candidates.isEmpty) {
    if (prev.roots.isEmpty && !prev.electing) return RootElectionState.none;
    return RootElectionState(
      electingSince: prev.electingSince ?? now,
      lostRoots: lost,
    );
  }

  if (_same(prev.roots, candidates) && !prev.electing) {
    // Holding: keep the last outcome.
    final one = candidates.length == 1 ? candidates.first : null;
    return RootElectionState(
      roots: candidates,
      candidates: candidates,
      electedMac: prev.electedMac == one ? prev.electedMac : null,
      electedAfter: prev.electedMac == one ? prev.electedAfter : null,
      electedAt: prev.electedMac == one ? prev.electedAt : null,
    );
  }

  // The set moved: an election only when a settled root is gone; a unit
  // joining at level 1 (or a fresh start) settles quietly.
  final electingSince = prev.electingSince ?? (lost.isNotEmpty ? now : null);
  final since = _same(prev.settlingSet, candidates) ? prev.settlingSince! : now;
  if (now.difference(since) >= rootElectionSettle) {
    final one = candidates.length == 1 ? candidates.first : null;
    if (electingSince == null) {
      return RootElectionState(roots: candidates, candidates: candidates);
    }
    return RootElectionState(
      roots: candidates,
      candidates: candidates,
      electedMac: one,
      electedAfter: now.difference(electingSince),
      electedAt: now,
    );
  }
  return RootElectionState(
    // No election: the known roots keep their badge while a newcomer settles.
    roots: electingSince == null ? prev.roots : const {},
    electingSince: electingSince,
    candidates: candidates,
    settlingSet: candidates,
    settlingSince: since,
    lostRoots: electingSince == null ? const {} : lost,
  );
}

class RootElectionNotifier extends StateNotifier<RootElectionState> {
  RootElectionNotifier(this._db) : super(RootElectionState.none);

  /// Null on a phone viewing a central through the mirror: the event log
  /// is the central's, written by its own tablet.
  final AppDatabase? _db;
  Set<String> _candidates = const {};
  bool _linkUp = false;

  /// New map contents from [topologyProvider].
  void update(List<TopologyNode> nodes, {required bool linkUp}) {
    _linkUp = linkUp;
    _candidates = {
      for (final n in nodes)
        // Heard, not only supervised as present: a unit that is silent
        // because it restarts into a new firmware (protocol §13.4) bridges
        // nothing and is no contender.
        if (n.online && n.heard && n.layer == 1) n.mac
    };
    _evaluate();
  }

  /// Once a second: advances the settle timer and the elapsed display.
  void tick() {
    if (!mounted) return;
    if (state.electing || state.settlingSet != null) _evaluate();
  }

  void _evaluate() {
    final now = DateTime.now().toUtc();
    // With the USB link down nothing is reachable: that is a link trouble
    // (serial_link_provider), not a root election.
    final next = _linkUp
        ? stepRootElection(state, _candidates, now)
        : RootElectionState.none;
    final prev = state;
    state = next;
    if (!prev.electing && next.electing) {
      _log(
        kind: 'root_election_started',
        description: 'Root ${next.lostRoots.join(', ')} perdido — a malha '
            'está reorganizando',
      );
    } else if (prev.electing && !next.electing && next.roots.isNotEmpty) {
      final s = now.difference(prev.electingSince!).inSeconds;
      _log(
        kind: 'root_elected',
        description: next.roots.length == 1
            ? 'Novo root: ${next.rootMac} após $s s'
            : 'Novos roots: ${next.roots.join(', ')} após $s s',
        deviceMac: next.rootMac,
      );
    }
  }

  Future<void> _log({
    required String kind,
    required String description,
    String? deviceMac,
  }) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.into(db.deviceEvents).insert(DeviceEventsCompanion.insert(
            receivedAt: DateTime.now().toUtc(),
            deviceMac: deviceMac ?? safrCentralMac,
            msgType: 0, // synthetic
            severity: 0,
            detailJson: jsonEncode({
              'synthetic': true,
              'kind': kind,
              'description': description,
            }),
          ));
    } catch (_) {
      // The log is evidence, not state: never let it break the map.
    }
  }
}

/// The board link is up: this tablet's serial link, or — on a phone viewing
/// a central — that central's, as its mirror reports it.
final boardLinkUpProvider = Provider<bool>((ref) {
  if (ref.watch(viewedCentralProvider) != null) {
    return ref.watch(centralMirrorProvider.select((v) => v.linkUp));
  }
  return ref.watch(serialLinkProvider) == SerialLinkStatus.connected;
});

final rootElectionProvider =
    StateNotifierProvider<RootElectionNotifier, RootElectionState>((ref) {
  final mirrored = ref.watch(viewedCentralProvider) != null;
  final notifier =
      RootElectionNotifier(mirrored ? null : ref.watch(appDatabaseProvider));
  void push() => notifier.update(
        ref.read(topologyProvider),
        linkUp: ref.read(boardLinkUpProvider),
      );
  ref.listen<List<TopologyNode>>(topologyProvider, (_, __) => push(),
      fireImmediately: true);
  ref.listen<bool>(boardLinkUpProvider, (_, __) => push());
  final timer =
      Timer.periodic(const Duration(seconds: 1), (_) => notifier.tick());
  ref.onDispose(timer.cancel);
  return notifier;
});
