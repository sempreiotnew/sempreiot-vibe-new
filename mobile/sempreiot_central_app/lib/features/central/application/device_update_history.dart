import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'central_mirror_codec.dart' show MirrorOtaHistoryRun;
import 'central_mirror_viewer.dart';
import 'device_update_state.dart';
import 'device_update_words.dart';

/// The firmware update history on the tablet (OTA brief decision 9, §6):
/// `OtaRuns` (one row per update) and `OtaRunUnits` (one row per unit per
/// update). Written by [DeviceUpdateController] as a run changes; read by
/// "Atualizar dispositivos" (a unit's details, "Registro" → Histórico) and,
/// later, sent to the cloud (`syncedAt`).
class DeviceUpdateHistory {
  DeviceUpdateHistory(this._db);
  final AppDatabase _db;

  /// Writes what changed between [before] and [next]: the run's row when
  /// it starts and when its stage or outcome changes, a unit's row when its
  /// state, tries, version or reason change (not on every percent).
  Future<void> record(DeviceUpdateRun? before, DeviceUpdateRun next) async {
    final fresh = before == null || before.runId != next.runId;
    if (fresh ||
        before.stage != next.stage ||
        before.end != next.end ||
        before.message != next.message) {
      await _db.into(_db.otaRuns).insertOnConflictUpdate(_runRow(next));
    }
    for (final u in next.units.values) {
      final was = fresh ? null : before.units[u.key];
      if (was != null &&
          was.state == u.state &&
          was.attempts == u.attempts &&
          was.version == u.version &&
          was.reasonRaw == u.reasonRaw &&
          was.note == u.note) {
        continue;
      }
      await _db.into(_db.otaRunUnits).insertOnConflictUpdate(
            OtaRunUnitsCompanion.insert(
              runId: next.runId,
              unitKey: u.key,
              family: u.family.name,
              versionBefore: u.versionBefore,
              versionAfter: u.version,
              state: u.state.name,
              attempts: u.attempts,
              reasonRaw: u.reasonRaw,
              note: Value(u.note),
              updatedAt: DateTime.now(),
            ),
          );
    }
  }

  OtaRunsCompanion _runRow(DeviceUpdateRun r) => OtaRunsCompanion.insert(
        runId: r.runId,
        startedAt: r.startedAt,
        endedAt: Value(r.endedAt),
        startedBy: r.startedBy,
        allPhases: r.all,
        target: r.target,
        families: r.phases.map((f) => f.name).join(','),
        outcome: Value(r.running ? null : r.end?.name),
        message: Value(r.message),
        source: Value(r.source.name),
        publishedBy: Value(r.publishedBy),
      );

  /// The last updates, newest first, each with its units.
  Future<List<(OtaRun, List<OtaRunUnit>)>> recent({int limit = 20}) async {
    final runs = await (_db.select(_db.otaRuns)
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(limit))
        .get();
    final out = <(OtaRun, List<OtaRunUnit>)>[];
    for (final r in runs) {
      final units = await (_db.select(_db.otaRunUnits)
            ..where((t) => t.runId.equals(r.runId)))
          .get();
      out.add((r, units));
    }
    return out;
  }

  /// What happened to the unit [key] in the last updates, newest first.
  Future<List<(OtaRun, OtaRunUnit)>> ofUnit(String key, {int limit = 5}) async {
    final query = _db.select(_db.otaRunUnits).join([
      innerJoin(
          _db.otaRuns, _db.otaRuns.runId.equalsExp(_db.otaRunUnits.runId)),
    ])
      ..where(_db.otaRunUnits.unitKey.equals(key))
      ..orderBy([OrderingTerm.desc(_db.otaRuns.startedAt)])
      ..limit(limit);
    final rows = await query.get();
    return [
      for (final row in rows)
        (row.readTable(_db.otaRuns), row.readTable(_db.otaRunUnits)),
    ];
  }
}

/// One line of the history, for a person: "02/10 15:42 · v0.1.0 → v0.2.6 ·
/// Atualizado" (+ the reason when it was not).
String deviceUpdateHistoryLine(OtaRun run, OtaRunUnit unit) {
  String two(int v) => v.toString().padLeft(2, '0');
  final at = run.startedAt.toLocal();
  final when =
      '${two(at.day)}/${two(at.month)} ${two(at.hour)}:${two(at.minute)}';
  final state =
      SafrOtaUnitState.values.where((s) => s.name == unit.state).firstOrNull ??
          SafrOtaUnitState.waiting;
  final word = switch (state) {
    SafrOtaUnitState.done => 'Atualizado',
    SafrOtaUnitState.failed => 'Falhou',
    SafrOtaUnitState.skipped => 'Não atualizado',
    _ => run.outcome == null ? 'Em andamento' : 'Não atualizado',
  };
  final versions = unit.versionAfter == unit.versionBefore
      ? vText(unit.versionBefore)
      : '${vText(unit.versionBefore)} → ${vText(unit.versionAfter)}';
  return '$when · $versions · $word';
}

/// The history as CSV (one line per unit per update), for "Copiar".
String deviceUpdateHistoryCsv(List<(OtaRun, List<OtaRunUnit>)> runs) {
  String q(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';
  final out = StringBuffer(
      'inicio,fim,por,tudo,alvo,resultado,unidade,familia,antes,depois,estado,tentativas,motivo,nota\n');
  for (final (run, units) in runs) {
    for (final u in units) {
      out.writeln([
        run.startedAt.toIso8601String(),
        run.endedAt?.toIso8601String(),
        run.startedBy,
        run.allPhases ? 'sim' : 'não',
        run.target,
        run.outcome ?? 'em andamento',
        u.unitKey,
        u.family,
        u.versionBefore,
        u.versionAfter,
        u.state,
        u.attempts,
        u.reasonRaw,
        u.note,
      ].map(q).join(','));
    }
  }
  return out.toString();
}

/// The history of a central viewed from a user's phone: what the central
/// sent when asked (central mirror), read only.
class MirrorDeviceUpdateHistory implements DeviceUpdateHistory {
  MirrorDeviceUpdateHistory(this._runs);

  /// Newest first.
  final List<MirrorOtaHistoryRun> _runs;

  @override
  AppDatabase get _db => throw UnsupportedError('read only');

  @override
  Future<void> record(DeviceUpdateRun? before, DeviceUpdateRun next) async {}

  @override
  OtaRunsCompanion _runRow(DeviceUpdateRun r) =>
      throw UnsupportedError('read only');

  @override
  Future<List<(OtaRun, List<OtaRunUnit>)>> recent({int limit = 20}) async =>
      _runs.take(limit).toList();

  @override
  Future<List<(OtaRun, OtaRunUnit)>> ofUnit(String key,
          {int limit = 5}) async =>
      [
        for (final (run, units) in _runs)
          for (final u in units)
            if (u.unitKey == key) (run, u),
      ].take(limit).toList();
}

final deviceUpdateHistoryProvider = Provider<DeviceUpdateHistory>((ref) {
  if (ref.watch(viewedCentralProvider) != null) {
    return MirrorDeviceUpdateHistory(
        ref.watch(centralMirrorProvider.select((v) => v.otaHistory)));
  }
  return DeviceUpdateHistory(ref.watch(appDatabaseProvider));
});
