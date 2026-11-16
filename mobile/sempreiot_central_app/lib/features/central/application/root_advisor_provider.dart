import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'central_mirror_viewer.dart';
import 'root_election_provider.dart';
import 'topology_provider.dart';

/// RELAXED FOR THE BENCH (2026-11-13, docs/ota/before-production.md item
/// 10): a unit is suggested after ONE minute of hearing the board better,
/// so the suggestion can be tried without waiting. Production: `false` —
/// ten minutes ([RootAdvisor.productionHoldFor]). `firmware/ci/check.sh
/// --release` fails while this is true.
const rootAdviceHoldBench = true;

/// "Another unit hears the central better than the root": what the Rede
/// screen tells the operator, who then decides (2026-11-13). The central
/// finds the unit; a person says yes — nothing changes by itself.
@immutable
class RootAdvice {
  const RootAdvice({
    required this.mac,
    required this.rssi,
    required this.rootMac,
    required this.rootRssi,
  });

  /// The unit that would be a better root, and how it hears the board.
  final String mac;
  final int rssi;

  /// The root now, and how it hears the board.
  final String rootMac;
  final int rootRssi;

  int get gainDb => rssi - rootRssi;

  @override
  bool operator ==(Object other) =>
      other is RootAdvice &&
      other.mac == mac &&
      other.rssi == rssi &&
      other.rootMac == rootMac &&
      other.rootRssi == rootRssi;

  @override
  int get hashCode => Object.hash(mac, rssi, rootMac, rootRssi);
}

/// Finds the unit of [RootAdvice], on the central, from what every mains
/// unit says of the board's signal (TopologyNode.boardRssi).
///
/// A unit is suggested when it has heard the board at least [minGainDb]
/// better than the root does for [holdFor] without a break — one reading
/// moves by several dB on its own. Nothing is suggested while an alarm is
/// held, while the root is being chosen, with the board off the link, for
/// [quietAfterAttempt] after a change was tried (it worked: the mesh
/// settles; it did not: no nagging), nor for a unit the operator said "not
/// now" to, for [dismissedFor].
class RootAdvisor extends StateNotifier<RootAdvice?> {
  RootAdvisor({DateTime Function()? clock, Duration? holdFor})
      : _clock = clock ?? DateTime.now,
        holdFor =
            holdFor ?? (rootAdviceHoldBench ? benchHoldFor : productionHoldFor),
        super(null);

  static const minGainDb = 10;
  static const productionHoldFor = Duration(minutes: 10);
  static const benchHoldFor = Duration(minutes: 1);

  /// For how long a unit must hear the board better, without a break.
  final Duration holdFor;
  static const quietAfterAttempt = Duration(hours: 1);
  static const dismissedFor = Duration(hours: 24);

  final DateTime Function() _clock;
  final _betterSince = <String, DateTime>{};
  final _dismissedUntil = <String, DateTime>{};
  DateTime? _quietUntil;

  void update(
    List<TopologyNode> nodes, {
    required String? rootMac,
    required bool linkUp,
  }) {
    if (!mounted) return;
    final now = _clock();
    final root = rootMac == null
        ? null
        : nodes.where((n) => n.mac == rootMac).firstOrNull;
    // The root's own station is on the board: its parent link is the same
    // measure, for a root whose firmware does not say BOARD_RSSI yet.
    final rootRssi = root?.boardRssi ?? root?.rssi;
    if (!linkUp ||
        root == null ||
        rootRssi == null ||
        nodes.any((n) => n.alarmLatched)) {
      _betterSince.clear();
      _set(null);
      return;
    }
    final better = <TopologyNode>[
      for (final n in nodes)
        if (n.layer >= 2 &&
            !n.isLeaf &&
            n.online &&
            n.heard &&
            !n.updating &&
            n.boardRssi != null &&
            n.boardRssi! - rootRssi >= minGainDb)
          n,
    ];
    final macs = {for (final n in better) n.mac};
    _betterSince.removeWhere((mac, _) => !macs.contains(mac));
    for (final mac in macs) {
      _betterSince.putIfAbsent(mac, () => now);
    }
    final quiet = _quietUntil;
    if (quiet != null && now.isBefore(quiet)) {
      _set(null);
      return;
    }
    TopologyNode? best;
    for (final n in better) {
      if (now.difference(_betterSince[n.mac]!) < holdFor) continue;
      final dismissed = _dismissedUntil[n.mac];
      if (dismissed != null && now.isBefore(dismissed)) continue;
      if (best == null || n.boardRssi! > best.boardRssi!) best = n;
    }
    _set(best == null
        ? null
        : RootAdvice(
            mac: best.mac,
            rssi: best.boardRssi!,
            rootMac: root.mac,
            rootRssi: rootRssi,
          ));
  }

  /// A change of root was sent: nothing more is suggested for a while.
  void noteAttempt() {
    _quietUntil = _clock().add(quietAfterAttempt);
    _betterSince.clear();
    _set(null);
  }

  /// "Agora não": this unit is not suggested again for a day.
  void dismiss(String mac) {
    _dismissedUntil[mac] = _clock().add(dismissedFor);
    if (state?.mac == mac) _set(null);
  }

  void _set(RootAdvice? next) {
    if (next != state) state = next;
  }
}

/// The central's own advisor. Never built on a phone.
final rootAdvisorProvider =
    StateNotifierProvider<RootAdvisor, RootAdvice?>((ref) {
  final advisor = RootAdvisor();
  void feed() => advisor.update(
        ref.read(topologyProvider),
        rootMac: ref.read(rootElectionProvider).rootMac,
        linkUp: ref.read(boardLinkUpProvider),
      );
  ref.listen<List<TopologyNode>>(topologyProvider, (_, __) => feed(),
      fireImmediately: true);
  ref.listen<RootElectionState>(rootElectionProvider, (_, __) => feed());
  ref.listen<bool>(boardLinkUpProvider, (_, __) => feed());
  return advisor;
});

/// What the screens show: the central's own advice, or — on a phone viewing
/// a central — the one the central published (the unit its snapshot marks,
/// TopologyNode.suggestedRoot). A phone never works one out by itself.
final rootAdviceProvider = Provider<RootAdvice?>((ref) {
  if (ref.watch(viewedCentralProvider) == null) {
    return ref.watch(rootAdvisorProvider);
  }
  final nodes = ref.watch(topologyProvider);
  final rootMac = ref.watch(rootElectionProvider).rootMac;
  final suggested = nodes.where((n) => n.suggestedRoot).firstOrNull;
  final root =
      rootMac == null ? null : nodes.where((n) => n.mac == rootMac).firstOrNull;
  final rootRssi = root?.boardRssi ?? root?.rssi;
  if (suggested == null ||
      suggested.boardRssi == null ||
      root == null ||
      rootRssi == null) {
    return null;
  }
  return RootAdvice(
    mac: suggested.mac,
    rssi: suggested.boardRssi!,
    rootMac: root.mac,
    rootRssi: rootRssi,
  );
});
