import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'ota_rollout_state.dart' show OtaPauseCause;

/// Key of the board in an update run (the CENTRAL on the map): it is
/// updated by the push itself, not by a rollout.
const deviceUpdateBoardKey = '@board';

/// Where an update run is.
enum DeviceUpdateStage {
  /// The image goes from the tablet to the board over the cable.
  pushing,

  /// The board restarted into its new image: its access point went down
  /// and the mesh is joining it again. Nothing is offered until the units
  /// of the run are heard again.
  reconnecting,

  /// The board offers the image to the units, one at a time.
  rolling,

  /// "Atualizar tudo": a node failed; the operator decides whether the
  /// detectors go next.
  deciding,
  ended,
}

/// How a run ended.
enum DeviceUpdateEnd {
  /// Every unit runs the new version.
  done,

  /// Some unit failed or was left out.
  partial,

  /// The image did not reach the board, or the board did not take it.
  failed,

  /// The operator cancelled.
  cancelled,

  /// "Atualizar tudo": the operator stopped before the detectors.
  stopped,
}

/// One unit of a run, as this run saw it — the board's table is replaced
/// by every rollout it starts, so the run keeps its own record.
class DeviceUpdateUnit {
  const DeviceUpdateUnit({
    required this.key,
    required this.family,
    this.state = SafrOtaUnitState.waiting,
    this.percent = 0,
    this.attempts = 0,
    this.reasonRaw = 0,
    this.versionBefore = '',
    this.version = '',
    this.note,
  });

  /// The unit's MAC, or [deviceUpdateBoardKey].
  final String key;
  final SafrProductFamily family;
  final SafrOtaUnitState state;
  final int percent;
  final int attempts;
  final int reasonRaw;

  /// What it ran when the run started; empty = not known.
  final String versionBefore;

  /// What it runs now, as far as the run knows; empty = not known.
  final String version;

  /// Why it failed or was left out when the unit itself did not say:
  /// the board refused the offer, nobody answered in time, a cancel.
  final String? note;

  SafrOtaReason get reason => SafrOtaReason.fromWire(reasonRaw);

  DeviceUpdateUnit copyWith({
    SafrOtaUnitState? state,
    int? percent,
    int? attempts,
    int? reasonRaw,
    String? version,
    Object? note = _keep,
  }) =>
      DeviceUpdateUnit(
        key: key,
        family: family,
        state: state ?? this.state,
        percent: percent ?? this.percent,
        attempts: attempts ?? this.attempts,
        reasonRaw: reasonRaw ?? this.reasonRaw,
        versionBefore: versionBefore,
        version: version ?? this.version,
        note: identical(note, _keep) ? this.note : note as String?,
      );
}

const _keep = Object();

/// One update, started on "Atualizar dispositivos": a family to the units
/// the operator chose, or "Atualizar tudo" — board, then nodes, then
/// detectors.
class DeviceUpdateRun {
  const DeviceUpdateRun({
    required this.all,
    required this.phases,
    required this.target,
    this.targets = const {},
    required this.queues,
    required this.units,
    required this.stage,
    required this.startedAt,
    this.phase = 0,
    this.end,
    this.message,
    this.holding = false,
    this.pausedBy,
    this.endedAt,
    this.boardRestartedAt,
    this.runId = '',
    this.startedBy = 'system',
  });

  /// "Atualizar tudo".
  final bool all;

  /// The families, in the order they are updated.
  final List<SafrProductFamily> phases;
  final int phase;

  /// The version(s) of the run in one line: the one version of a
  /// single-family run; for "Atualizar tudo", one per family
  /// ("placa v0.3.0 · nós v0.2.1 · …").
  final String target;

  /// The version each family goes to ("Atualizar tudo" takes the newest
  /// image the tablet has of each). Empty = [target] for every family.
  final Map<SafrProductFamily, String> targets;

  /// The version the units of [family] go to.
  String targetOf(SafrProductFamily family) => targets[family] ?? target;

  /// Per family, the units in the order they are updated (the root last).
  final Map<SafrProductFamily, List<String>> queues;
  final Map<String, DeviceUpdateUnit> units;
  final DeviceUpdateStage stage;
  final DeviceUpdateEnd? end;

  /// Why the run stopped or waits, in plain words; null = nothing to say.
  final String? message;

  /// The operator paused: no unit starts until "Retomar".
  final bool holding;

  /// The board paused the rollout (or the run waits for an alarm to be
  /// reset before the next unit); null = not paused.
  final OtaPauseCause? pausedBy;

  final DateTime startedAt;
  final DateTime? endedAt;

  /// The run in the history (`OtaRuns.runId`).
  final String runId;

  /// Audit actor who started it: 'master' | 'admin' | 'system'.
  final String startedBy;

  /// When the board restarted into a new image (this run or one shortly
  /// before): a unit counts as back once heard after it.
  final DateTime? boardRestartedAt;

  SafrProductFamily get family => phases[phase];
  bool get running => stage != DeviceUpdateStage.ended;
  bool get paused => holding || pausedBy != null;

  /// The units of [family], in their order.
  List<DeviceUpdateUnit> unitsOf(SafrProductFamily family) => [
        for (final k in queues[family] ?? const <String>[])
          if (units[k] != null) units[k]!,
      ];

  int countOf(SafrProductFamily family, SafrOtaUnitState s) =>
      unitsOf(family).where((u) => u.state == s).length;

  int count(SafrOtaUnitState s) =>
      units.values.where((u) => u.state == s).length;

  /// The units of [family] that do not run the target: failed, left out by
  /// the board (skipped), or never offered.
  List<DeviceUpdateUnit> notUpdated(SafrProductFamily family) => [
        for (final u in unitsOf(family))
          if (u.state != SafrOtaUnitState.done) u,
      ];

  /// Every unit of the run that does not run the target.
  int get notUpdatedCount =>
      units.values.where((u) => u.state != SafrOtaUnitState.done).length;

  /// The unit the run is busy with now, if any.
  DeviceUpdateUnit? get current {
    for (final u in unitsOf(family)) {
      if (u.state.active) return u;
    }
    return null;
  }

  DeviceUpdateRun copyWith({
    int? phase,
    Map<SafrProductFamily, List<String>>? queues,
    Map<String, DeviceUpdateUnit>? units,
    DeviceUpdateStage? stage,
    Object? end = _keep,
    Object? message = _keep,
    bool? holding,
    Object? pausedBy = _keep,
    Object? endedAt = _keep,
    Object? boardRestartedAt = _keep,
  }) =>
      DeviceUpdateRun(
        all: all,
        phases: phases,
        phase: phase ?? this.phase,
        target: target,
        targets: targets,
        queues: queues ?? this.queues,
        units: units ?? this.units,
        stage: stage ?? this.stage,
        end: identical(end, _keep) ? this.end : end as DeviceUpdateEnd?,
        message: identical(message, _keep) ? this.message : message as String?,
        holding: holding ?? this.holding,
        pausedBy: identical(pausedBy, _keep)
            ? this.pausedBy
            : pausedBy as OtaPauseCause?,
        startedAt: startedAt,
        endedAt:
            identical(endedAt, _keep) ? this.endedAt : endedAt as DateTime?,
        boardRestartedAt: identical(boardRestartedAt, _keep)
            ? this.boardRestartedAt
            : boardRestartedAt as DateTime?,
        runId: runId,
        startedBy: startedBy,
      );
}
