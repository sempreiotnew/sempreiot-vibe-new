import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/board_sync_provider.dart';

/// "Sincronizar com a placa" (board_sync_provider.dart): nothing is erased;
/// only units the board does not list AND that are silent leave the map.
void main() {
  test('asks the board, then reports what its table said', () {
    fakeAsync((async) {
      var asked = 0;
      Set<String>? prunedWith;
      DateTime? silentBefore;
      final now = DateTime.utc(2026, 10, 8, 12);
      final sync = BoardSyncNotifier(
        request: () async => asked++,
        prune: (listed, before) async {
          prunedWith = listed;
          silentBefore = before;
          return 2;
        },
        clock: () => now,
      );
      sync.start();
      async.flushMicrotasks();
      expect(asked, 1);
      expect(sync.state.phase, BoardSyncPhase.syncing);

      sync.tableArrived({'A', 'B', 'C'});
      async.flushMicrotasks();
      expect(prunedWith, {'A', 'B', 'C'});
      expect(silentBefore, now.subtract(boardSyncSilentFor));
      expect(sync.state.phase, BoardSyncPhase.done);
      expect(sync.state.listed, 3);
      expect(sync.state.removed, 2);

      async.elapse(boardSyncResultFor);
      expect(sync.state.phase, BoardSyncPhase.idle);
      sync.dispose();
    });
  });

  test('a table outside a sync (every link-up sends one) prunes nothing', () {
    fakeAsync((async) {
      var pruned = false;
      final sync = BoardSyncNotifier(
        request: () async {},
        prune: (_, __) async {
          pruned = true;
          return 0;
        },
      );
      sync.tableArrived({'A'});
      async.flushMicrotasks();
      expect(pruned, isFalse);
      expect(sync.state.phase, BoardSyncPhase.idle);
      sync.dispose();
    });
  });

  test('no table in time: the board did not answer, the map is unchanged', () {
    fakeAsync((async) {
      var pruned = false;
      final sync = BoardSyncNotifier(
        request: () async {},
        prune: (_, __) async {
          pruned = true;
          return 0;
        },
      );
      sync.start();
      async.elapse(boardSyncTimeout);
      expect(sync.state.phase, BoardSyncPhase.failed);
      expect(pruned, isFalse);
      async.elapse(boardSyncResultFor);
      expect(sync.state.phase, BoardSyncPhase.idle);
      sync.dispose();
    });
  });
}
