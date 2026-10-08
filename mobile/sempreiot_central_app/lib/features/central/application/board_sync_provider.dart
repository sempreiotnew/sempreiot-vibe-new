import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import 'safr_downlink_provider.dart';

enum BoardSyncPhase { idle, syncing, done, failed }

class BoardSyncState {
  const BoardSyncState({
    this.phase = BoardSyncPhase.idle,
    this.listed = 0,
    this.removed = 0,
  });

  final BoardSyncPhase phase;

  /// Done: how many units the board's table lists.
  final int listed;

  /// Done: how many rows left the map (not listed, and silent).
  final int removed;

  static const idle = BoardSyncState();
}

/// How long the board has to send its whole table.
const boardSyncTimeout = Duration(seconds: 12);

/// How long "Sincronizado" / "A placa não respondeu" stays up.
const boardSyncResultFor = Duration(seconds: 6);

/// A unit silent this long, and not in the board's table, leaves the map on
/// a sync. A unit heard more recently is plainly there and stays.
const boardSyncSilentFor = Duration(minutes: 5);

/// "Sincronizar com a placa" on the Rede strip. It never erases the map:
/// the tablet asks the board for INSTALLATION and its DEVICE_TABLE, every
/// unit stays where it is (a sleeping detector does not vanish until its
/// next wake), units the board lists but this tablet never heard appear as
/// "aguardando o primeiro sinal", and only units the board does not list
/// and that have been silent for [boardSyncSilentFor] are removed.
///
/// It replaces "Ressincronizar com a placa", which wiped the registry: the
/// map emptied and every unit came back only with its own next frame —
/// battery detectors a minute or more later.
class BoardSyncNotifier extends StateNotifier<BoardSyncState> {
  BoardSyncNotifier({
    required Future<void> Function() request,
    required Future<int> Function(Set<String> listed, DateTime silentBefore)
        prune,
    DateTime Function()? clock,
  })  : _request = request,
        _prune = prune,
        _clock = clock ?? DateTime.now,
        super(BoardSyncState.idle);

  final Future<void> Function() _request;
  final Future<int> Function(Set<String> listed, DateTime silentBefore) _prune;
  final DateTime Function() _clock;
  Timer? _timer;

  Future<void> start() async {
    if (state.phase == BoardSyncPhase.syncing) return;
    _set(const BoardSyncState(phase: BoardSyncPhase.syncing), boardSyncTimeout,
        then: const BoardSyncState(phase: BoardSyncPhase.failed));
    try {
      await _request();
    } catch (_) {
      if (mounted && state.phase == BoardSyncPhase.syncing) {
        _set(const BoardSyncState(phase: BoardSyncPhase.failed),
            boardSyncResultFor);
      }
    }
  }

  /// The board's table arrived complete. Outside a sync (the table sent at
  /// every link-up) it changes nothing here.
  Future<void> tableArrived(Set<String> listed) async {
    if (state.phase != BoardSyncPhase.syncing) return;
    var removed = 0;
    try {
      removed =
          await _prune(listed, _clock().toUtc().subtract(boardSyncSilentFor));
    } catch (_) {
      // The map keeps a row too many: never worth failing the sync for.
    }
    if (!mounted) return;
    _set(
      BoardSyncState(
        phase: BoardSyncPhase.done,
        listed: listed.length,
        removed: removed,
      ),
      boardSyncResultFor,
    );
  }

  /// Sets [s]; after [after] goes to [then] (idle by default), unless
  /// something else happened meanwhile.
  void _set(BoardSyncState s, Duration after, {BoardSyncState? then}) {
    _timer?.cancel();
    state = s;
    _timer = Timer(after, () {
      if (!mounted || !identical(state, s)) return;
      final next = then ?? BoardSyncState.idle;
      if (next.phase == BoardSyncPhase.failed) {
        _set(next, boardSyncResultFor);
      } else {
        state = next;
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final boardSyncProvider =
    StateNotifierProvider<BoardSyncNotifier, BoardSyncState>((ref) {
  return BoardSyncNotifier(
    request: () async {
      final downlink = ref.read(safrDownlinkProvider);
      await downlink.sendGetInstallation();
      await downlink.sendGetDeviceTable();
    },
    prune: (listed, before) =>
        ref.read(appDatabaseProvider).pruneUnlistedSilentRows(listed, before),
  );
});
