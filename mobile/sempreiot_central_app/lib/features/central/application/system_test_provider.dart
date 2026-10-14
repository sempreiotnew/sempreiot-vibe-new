import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/system_test/system_test_run.dart';
import '../../iot/application/iot_provider.dart';
import 'central_mirror_codec.dart';
import 'central_mirror_viewer.dart';
import 'device_command_provider.dart';
import 'topology_provider.dart';

/// The system test running now and the last ones — on the tablet from
/// its own tracker and database, on a phone from the central's retained
/// `test` message (`mirrorTestsProvider`). One shape for both, so the
/// Central's popover, the history and the report are the same screens.
class SystemTestsState {
  const SystemTestsState({this.running, this.recent = const []});

  final SystemTestRun? running;

  /// Newest first.
  final List<SystemTestRun> recent;

  static const empty = SystemTestsState();
}

/// The tablet's side: starts and cancels the test through the command
/// tracker (the map's clocks and ticks are the tracker's, unchanged),
/// keeps a `SystemTestRun` of it as the tracker moves, writes it to the
/// database on every change and once more when it ends, and holds the
/// last runs for the popover, the history and the mirror.
class SystemTestController extends StateNotifier<SystemTestsState> {
  SystemTestController({
    required DeviceCommandTracker tracker,
    required List<TopologyNode> Function() nodes,
    Future<void> Function(SystemTestRun run)? save,
    Future<List<SystemTestRun>> Function()? load,
    DateTime Function()? clock,
  })  : _tracker = tracker,
        _nodes = nodes,
        _save = save,
        _load = load,
        _clock = clock ?? DateTime.now,
        super(SystemTestsState.empty) {
    _restore();
  }

  final DeviceCommandTracker _tracker;
  final List<TopologyNode> Function() _nodes;
  final Future<void> Function(SystemTestRun run)? _save;
  final Future<List<SystemTestRun>> Function()? _load;
  final DateTime Function() _clock;

  /// How many past tests are kept in memory (the database keeps them all).
  static const keep = 20;

  /// The run being followed; null = no test of this controller runs.
  SystemTestRun? _current;

  Future<void> _restore() async {
    final load = _load;
    if (load == null) return;
    try {
      final recent = await load();
      if (!mounted) return;
      // A test that was running when the app died is closed as failed:
      // nothing of it was followed since.
      final closed = [
        for (final r in recent)
          r.running
              ? r.copyWith(
                  verdict: SystemTestVerdict.failed,
                  endedAt: r.endedAt ?? _clock(),
                  units: [
                    for (final u in r.units)
                      u.outcome.isPending
                          ? SystemTestUnit(
                              mac: u.mac,
                              name: u.name,
                              outcome: SystemTestOutcome.noAnswer,
                              at: u.at)
                          : u,
                  ],
                )
              : r,
      ];
      for (var i = 0; i < recent.length; i++) {
        if (recent[i].running) await _write(closed[i]);
      }
      if (!mounted) return;
      state = SystemTestsState(
          running: state.running, recent: closed.take(keep).toList());
    } catch (e) {
      debugPrint('[SystemTest] history not read: $e');
    }
  }

  /// Starts a system test: TESTAR to every unit at once. False when one
  /// already runs, or the board did not take it at all.
  Future<bool> start({String? by}) async {
    if (_current != null || state.running != null) return false;
    final startedAt = _clock();
    // The tracker lists the units and sends before its first await: the
    // run is built from its state right after the call, the board's
    // answer comes through onCommands.
    final sent = _tracker.run(safrBroadcastMac, DeviceCommandKind.test, by: by);
    final all = _tracker.state[safrBroadcastMac];
    if (all == null || all.kind != DeviceCommandKind.test) {
      return false; // another broadcast (Rearmar) is on its way
    }
    _current = SystemTestRun(
      id: SystemTestRun.idFor(startedAt),
      startedAt: startedAt,
      verdict: SystemTestVerdict.running,
      by: by,
      units: _unitsFrom(_tracker.state),
    );
    _publish();
    await _write(_current!);
    return sent;
  }

  /// Cancels the running test: the units still waiting are "cancelado",
  /// the report says so. False when nothing runs.
  bool cancel() => _tracker.cancelBroadcast();

  /// The tracker moved (every change of its state).
  void onCommands(Map<String, DeviceCommandStatus> commands) {
    final cur = _current;
    if (cur == null) return;
    final all = commands[safrBroadcastMac];
    final units = _unitsFrom(commands, previous: cur.units);
    if (all == null || all.kind != DeviceCommandKind.test) {
      // Gone before its end was seen (never in practice: the broadcast
      // lingers after its verdict): closed from what the units say.
      _end(cur.copyWith(units: units), _verdictOf(units));
      return;
    }
    final boardAcked = all.step.index >= DeviceCommandStep.boardAck.index;
    switch (all.step) {
      case DeviceCommandStep.sending:
      case DeviceCommandStep.boardAck:
        _current = cur.copyWith(units: units, boardAcked: boardAcked);
        _publish();
        _write(_current!);
      case DeviceCommandStep.delivered:
      case DeviceCommandStep.answered:
        _end(cur.copyWith(units: units, boardAcked: true),
            SystemTestVerdict.passed);
      case DeviceCommandStep.failed:
        _end(
            cur.copyWith(units: units, boardAcked: boardAcked),
            all.note == DeviceCommandTracker.cancelledNote
                ? SystemTestVerdict.cancelled
                : SystemTestVerdict.failed);
    }
  }

  SystemTestVerdict _verdictOf(List<SystemTestUnit> units) =>
      units.any((u) => u.outcome.isPending || u.outcome.isFailure)
          ? SystemTestVerdict.failed
          : SystemTestVerdict.passed;

  void _end(SystemTestRun run, SystemTestVerdict verdict) {
    final ended = run.copyWith(verdict: verdict, endedAt: _clock());
    _current = null;
    state = SystemTestsState(
      running: null,
      recent: [ended, ...state.recent.where((r) => r.id != ended.id)]
          .take(keep)
          .toList(),
    );
    _write(ended);
  }

  void _publish() {
    final cur = _current;
    if (!mounted) return;
    state = SystemTestsState(running: cur, recent: state.recent);
  }

  Future<void> _write(SystemTestRun run) async {
    final save = _save;
    if (save == null) return;
    try {
      await save(run);
    } catch (e) {
      debugPrint('[SystemTest] not written: $e');
    }
  }

  /// The units of the broadcast as the tracker has them. A unit's name
  /// is taken once (a rename during the test does not change the report);
  /// the time of its answer is kept from the moment it was first seen.
  List<SystemTestUnit> _unitsFrom(
    Map<String, DeviceCommandStatus> commands, {
    List<SystemTestUnit> previous = const [],
  }) {
    final names = {for (final n in _nodes()) n.mac: n.name};
    final before = {for (final u in previous) u.mac: u};
    final macs = _tracker.broadcastUnits;
    final units = <SystemTestUnit>[];
    for (final mac in macs) {
      final s = commands[mac];
      final old = before[mac];
      if (s == null || s.kind != DeviceCommandKind.test) {
        if (old != null) units.add(old);
        continue;
      }
      final outcome = switch (s.step) {
        DeviceCommandStep.sending ||
        DeviceCommandStep.boardAck =>
          s.waitsForWake
              ? SystemTestOutcome.pendingWake
              : SystemTestOutcome.pending,
        DeviceCommandStep.delivered ||
        DeviceCommandStep.answered =>
          SystemTestOutcome.confirmed,
        DeviceCommandStep.failed => s.note == DeviceCommandTracker.missingNote
            ? SystemTestOutcome.missing
            : s.note == DeviceCommandTracker.cancelledNote
                ? SystemTestOutcome.cancelled
                : SystemTestOutcome.noAnswer,
      };
      units.add(SystemTestUnit(
        mac: mac,
        name: old?.name ?? names[mac],
        outcome: outcome,
        at: outcome.isPending
            ? null
            : (old?.outcome == outcome ? old?.at : null) ?? s.updatedAt,
      ));
    }
    units.sort((a, b) => a.displayName.compareTo(b.displayName));
    return units;
  }
}

/// The tablet's controller. Never read on a phone (the popover reads
/// [systemTestsViewProvider] and offers no start there).
final systemTestControllerProvider =
    StateNotifierProvider<SystemTestController, SystemTestsState>((ref) {
  final controller = SystemTestController(
    tracker: ref.watch(deviceCommandProvider.notifier),
    nodes: () => ref.read(topologyProvider),
    save: (run) => ref.read(appDatabaseProvider).saveSystemTest(run),
    load: () => ref.read(appDatabaseProvider).recentSystemTests(),
  );
  ref.listen<Map<String, DeviceCommandStatus>>(
    deviceCommandProvider,
    (_, next) => controller.onCommands(next),
  );
  return controller;
});

/// A phone: the retained `test` message of the viewed central — the test
/// running now and the last ones — there after a reload, a late join, or
/// with the central offline (what it last said). Null until it arrives.
final mirrorTestsProvider =
    Provider.family<MirrorTests?, String>((ref, identityId) {
  final msg = ref.watch(iotMessageStreamProvider(mirrorTestTopic(identityId)));
  final payload = msg.valueOrNull?.payload;
  return payload == null ? null : decodeMirrorTests(payload);
});

/// The tests as this device sees them: the tablet's own, or the viewed
/// central's mirror.
final systemTestsViewProvider = Provider<SystemTestsState>((ref) {
  final id = ref.watch(viewedCentralProvider);
  if (id != null) {
    final tests = ref.watch(mirrorTestsProvider(id));
    return tests == null
        ? SystemTestsState.empty
        : SystemTestsState(running: tests.running, recent: tests.recent);
  }
  return ref.watch(systemTestControllerProvider);
});
