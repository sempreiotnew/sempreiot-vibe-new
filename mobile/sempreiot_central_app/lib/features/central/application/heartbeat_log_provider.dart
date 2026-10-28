import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_v2_frame.dart';
import 'central_mirror_viewer.dart';
import 'safr_traffic_provider.dart';

/// Every HEARTBEAT the tablet hears, by sender (protocol §7.3): when the
/// last one arrived and how many arrived in a window. The board's own
/// HEARTBEAT reaches the tablet over the cable at the very moment the board
/// broadcasts it down the mesh, so the board's count here is "beats sent"
/// — the number a node's DL_HEARD is measured against (8 in 120 s). A
/// node's HEARTBEAT is its uplink, every 15 s; a leaf's every 60 s.
///
/// Nothing is invented: a beat is one real frame that arrived. What the
/// tablet never sees — the board's HEARTBEAT landing on a node — is not
/// here; the node's own DL_HEARD says that, 15 s later.
///
/// On a phone viewing a central (central mirror) the same log runs on the
/// ticks the central publishes.
class HeartbeatLog extends ChangeNotifier {
  HeartbeatLog({
    required Stream<SafrTrafficTick> traffic,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    startedAt = _clock();
    _sub = traffic.listen(onTick);
  }

  /// The monitor shows 5 min (20 beats at 15 s); a jittery board may fit a
  /// few more. Kept for every sender.
  static const _keep = 24;

  /// The window DL_HEARD is counted over (siot_hbwin.h SPAN).
  static const window = Duration(seconds: 120);

  final DateTime Function() _clock;
  late final StreamSubscription<SafrTrafficTick> _sub;

  /// When this log started listening: totals count from here.
  late final DateTime startedAt;

  final _recent = <String, List<HeartbeatBeat>>{};
  final _total = <String, int>{};

  @visibleForTesting
  void onTick(SafrTrafficTick tick) {
    if (tick.msgType != SafrMsgType.heartbeat ||
        tick.direction != SafrTrafficDirection.uplink) {
      return;
    }
    final now = _clock();
    final list = _recent.putIfAbsent(tick.mac, () => <HeartbeatBeat>[]);
    list.add(HeartbeatBeat(at: now, dlHeard: tick.dlHeard, dlMap: tick.dlMap));
    if (list.length > _keep) list.removeRange(0, list.length - _keep);
    _total[tick.mac] = (_total[tick.mac] ?? 0) + 1;
    notifyListeners();
  }

  /// When the sender's last HEARTBEAT arrived; null = none heard yet.
  DateTime? lastBeatAt(String mac) => _recent[mac]?.lastOrNull?.at;

  /// The sender's last HEARTBEATs, oldest first (up to 24).
  List<HeartbeatBeat> recent(String mac) =>
      List.unmodifiable(_recent[mac] ?? const <HeartbeatBeat>[]);

  /// HEARTBEATs of the sender that arrived in the last [span].
  int beatsIn(String mac, [Duration span = window]) {
    final list = _recent[mac];
    if (list == null) return 0;
    final since = _clock().subtract(span);
    return list.where((b) => b.at.isAfter(since)).length;
  }

  /// HEARTBEATs of the sender since [startedAt].
  int total(String mac) => _total[mac] ?? 0;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// One HEARTBEAT that arrived: when, and (a powered node's) how many of the
/// board's last 8 it had heard then (v3.6) and which (v3.7, bit 0 the
/// newest).
class HeartbeatBeat {
  const HeartbeatBeat({required this.at, this.dlHeard, this.dlMap});
  final DateTime at;
  final int? dlHeard;
  final int? dlMap;
}

final heartbeatLogProvider = ChangeNotifierProvider<HeartbeatLog>((ref) {
  // A new log for each central a user opens, like the LED engine.
  ref.watch(viewedCentralProvider);
  return HeartbeatLog(traffic: ref.watch(safrTrafficProvider).stream);
});
