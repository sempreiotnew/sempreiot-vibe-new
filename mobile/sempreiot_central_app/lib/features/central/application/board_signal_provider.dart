import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_v2_frame.dart';
import 'safr_traffic_provider.dart';

/// How each mains unit hears the CENTRAL's board, in dBm — the BOARD_RSSI
/// of its HEARTBEAT (protocol §7.3, v3.11): the root from its own station,
/// every other unit by listening to the board's beacons. It is what the
/// unit's link would be if it were the root.
///
/// Kept in memory only, from the heartbeats as they arrive: a unit that
/// stops reporting it (0x7F — the board is not heard from there) leaves
/// the map at its next heartbeat. Central only; a phone gets the value on
/// each unit of the mirror's snapshot.
class BoardSignalNotifier extends StateNotifier<Map<String, int>> {
  BoardSignalNotifier() : super(const {});

  void onTick(SafrTrafficTick tick) {
    if (tick.direction != SafrTrafficDirection.uplink ||
        tick.msgType != SafrMsgType.heartbeat) {
      return;
    }
    final rssi = tick.boardRssi;
    if (rssi == state[tick.mac]) return;
    state = rssi == null
        ? ({...state}..remove(tick.mac))
        : {...state, tick.mac: rssi};
  }
}

final boardSignalProvider =
    StateNotifierProvider<BoardSignalNotifier, Map<String, int>>((ref) {
  final notifier = BoardSignalNotifier();
  final sub = ref.watch(safrTrafficProvider).stream.listen(notifier.onTick);
  ref.onDispose(sub.cancel);
  return notifier;
});
