import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_v2_frame.dart' show safrCentralMac;
import 'serial_link_provider.dart';
import 'topology_provider.dart';

/// Who bridges the mesh to the board right now — or that the mesh is still
/// deciding.
///
/// After the root dies, Mesh-Lite lets every survivor that hears the board's
/// AP associate to it; for up to ~10 s two or three units genuinely are level
/// 1, each reporting itself as root, until the weaker ones back off. Nobody
/// — not even the board — can name the root during that window, so the map
/// must not: it shows the candidates and "reorganizando" instead. A unit
/// earns the ROOT badge only after being the sole online level-1 device for
/// [rootElectionSettle].
class RootElectionState {
  const RootElectionState({
    this.rootMac,
    this.electingSince,
    this.candidates = const {},
    this.settlingMac,
    this.settlingSince,
  });

  /// The settled root; null while electing, or with no mesh at all.
  final String? rootMac;

  /// Non-null while an election runs (root lost or several candidates).
  final DateTime? electingSince;

  /// Online level-1 units right now — the contenders while electing.
  final Set<String> candidates;

  /// The single candidate currently alone, and since when (settle timer).
  final String? settlingMac;
  final DateTime? settlingSince;

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

/// Pure step: previous state + the online level-1 units now → next state.
///
/// - one candidate, alone for [rootElectionSettle] → settled root;
/// - several candidates → electing;
/// - none, after a root was known (or mid-election) → electing ("root lost");
/// - none, and no root was ever known → nothing (empty mesh, not an election).
/// A fresh start with a single unit settles silently: no election is
/// declared unless a root was known or several units contend.
RootElectionState stepRootElection(
  RootElectionState prev,
  Set<String> candidates,
  DateTime now,
) {
  if (candidates.length == 1) {
    final mac = candidates.first;
    if (prev.rootMac == mac && !prev.electing) {
      return RootElectionState(rootMac: mac, candidates: candidates);
    }
    final since = prev.settlingMac == mac ? prev.settlingSince! : now;
    if (now.difference(since) >= rootElectionSettle) {
      return RootElectionState(rootMac: mac, candidates: candidates);
    }
    final electingSince =
        prev.electingSince ?? (prev.rootMac != null ? now : null);
    return RootElectionState(
      electingSince: electingSince,
      candidates: candidates,
      settlingMac: mac,
      settlingSince: since,
    );
  }
  if (candidates.length > 1) {
    return RootElectionState(
      electingSince: prev.electingSince ?? now,
      candidates: candidates,
    );
  }
  if (prev.rootMac != null || prev.electing) {
    return RootElectionState(electingSince: prev.electingSince ?? now);
  }
  return RootElectionState.none;
}

class RootElectionNotifier extends StateNotifier<RootElectionState> {
  RootElectionNotifier(this._db) : super(RootElectionState.none);

  final AppDatabase _db;
  Set<String> _candidates = const {};
  bool _linkUp = false;

  /// New map contents from [topologyProvider].
  void update(List<TopologyNode> nodes, {required bool linkUp}) {
    _linkUp = linkUp;
    _candidates = {
      for (final n in nodes)
        if (n.online && n.layer == 1) n.mac
    };
    _evaluate();
  }

  /// Once a second: advances the settle timer and the elapsed display.
  void tick() {
    if (!mounted) return;
    if (state.electing || state.settlingMac != null) _evaluate();
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
        description: prev.rootMac != null
            ? 'Root ${prev.rootMac} perdido — a malha está reorganizando'
            : 'Eleição de root: ${next.candidates.length} candidatos',
      );
    } else if (prev.electing && !next.electing && next.rootMac != null) {
      final s = now.difference(prev.electingSince!).inSeconds;
      _log(
        kind: 'root_elected',
        description: 'Novo root: ${next.rootMac} após $s s',
        deviceMac: next.rootMac,
      );
    }
  }

  Future<void> _log({
    required String kind,
    required String description,
    String? deviceMac,
  }) async {
    try {
      await _db.into(_db.deviceEvents).insert(DeviceEventsCompanion.insert(
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

final rootElectionProvider =
    StateNotifierProvider<RootElectionNotifier, RootElectionState>((ref) {
  final notifier = RootElectionNotifier(ref.watch(appDatabaseProvider));
  void push() => notifier.update(
        ref.read(topologyProvider),
        linkUp: ref.read(serialLinkProvider) == SerialLinkStatus.connected,
      );
  ref.listen<List<TopologyNode>>(topologyProvider, (_, __) => push(),
      fireImmediately: true);
  ref.listen<SerialLinkStatus>(serialLinkProvider, (_, __) => push());
  final timer = Timer.periodic(const Duration(seconds: 1), (_) => notifier.tick());
  ref.onDispose(timer.cancel);
  return notifier;
});
