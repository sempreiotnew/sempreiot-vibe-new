import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/system_test_provider.dart';
import '../../domain/system_test/system_test_run.dart';

/// The report of one system test, as a sheet: when, how long, who, how it
/// ended, the counts, and every unit with its answer. The same on the
/// tablet and on a phone (the mirror's copy).
Future<void> showSystemTestReport(BuildContext context, SystemTestRun run) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SystemTestReportSheet(run: run),
    );

/// The last tests, newest first; a tap opens the report.
Future<void> showSystemTestHistory(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SystemTestHistorySheet(),
    );

Color systemTestVerdictColor(BuildContext context, SystemTestVerdict v) =>
    switch (v) {
      SystemTestVerdict.running => AppColors.secondary,
      SystemTestVerdict.passed => AppColors.ledCyan,
      SystemTestVerdict.failed => AppColors.error,
      SystemTestVerdict.cancelled => context.textSecondary,
    };

Color systemTestOutcomeColor(BuildContext context, SystemTestOutcome o) =>
    switch (o) {
      SystemTestOutcome.pending ||
      SystemTestOutcome.pendingWake =>
        context.textSecondary,
      SystemTestOutcome.confirmed => AppColors.ledCyan,
      SystemTestOutcome.noAnswer ||
      SystemTestOutcome.missing =>
        AppColors.error,
      SystemTestOutcome.cancelled => context.textSecondary,
    };

IconData systemTestOutcomeIcon(SystemTestOutcome o) => switch (o) {
      SystemTestOutcome.pending ||
      SystemTestOutcome.pendingWake =>
        Icons.schedule_rounded,
      SystemTestOutcome.confirmed => Icons.done_all_rounded,
      SystemTestOutcome.noAnswer ||
      SystemTestOutcome.missing =>
        Icons.error_rounded,
      SystemTestOutcome.cancelled => Icons.block_rounded,
    };

String _two(int n) => n.toString().padLeft(2, '0');

/// "14/10/2026 · 15:42"
String systemTestWhen(DateTime at) {
  final t = at.toLocal();
  return '${_two(t.day)}/${_two(t.month)}/${t.year} · '
      '${_two(t.hour)}:${_two(t.minute)}';
}

/// "1 min 12 s" / "48 s"
String systemTestDuration(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '$s s';
  return '${s ~/ 60} min ${_two(s % 60)} s';
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame(
      {super.key, required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // A sheet in landscape has little height: capped, and it scrolls.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                  IconButton(
                    tooltip: 'Fechar',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: context.textSecondary),
                  ),
                ],
              ),
            ),
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}

class _VerdictChip extends StatelessWidget {
  const _VerdictChip(this.verdict);
  final SystemTestVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final color = systemTestVerdictColor(context, verdict);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        verdict.label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class SystemTestReportSheet extends ConsumerWidget {
  const SystemTestReportSheet({super.key, required this.run});

  /// The run as it was when the sheet opened; while the sheet is up it
  /// follows the same run as the tests move (a test that ends while its
  /// report is open reads "Concluído", not "Em andamento" for ever).
  final SystemTestRun run;

  static const sheetKey = ValueKey('system-test-report');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tests = ref.watch(systemTestsViewProvider);
    final run = [
          if (tests.running case final r?) r,
          ...tests.recent,
        ].where((r) => r.id == this.run.id).firstOrNull ??
        this.run;
    final counts = <(String, int, Color)>[
      ('confirmaram', run.confirmed, AppColors.ledCyan),
      if (run.pending > 0) ('pendentes', run.pending, context.textSecondary),
      if (run.missing > 0) ('sem comunicação', run.missing, AppColors.error),
      if (run.noAnswer > 0) ('sem resposta', run.noAnswer, AppColors.error),
      if (run.cancelled > 0)
        ('cancelados', run.cancelled, context.textSecondary),
    ];
    return _SheetFrame(
      key: sheetKey,
      title: 'Teste do sistema',
      trailing: _VerdictChip(run.verdict),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        children: [
          Text(
            [
              systemTestWhen(run.startedAt),
              if (run.endedAt != null) systemTestDuration(run.elapsed()),
              if (run.by != null) 'por ${run.by}',
            ].join('  ·  '),
            style: TextStyle(color: context.textSecondary, fontSize: 11.5),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, n, color) in counts)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color.withValues(alpha: 0.4)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$n',
                        style: TextStyle(
                          color: color,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        label,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'DISPOSITIVOS · ${run.total}',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 6),
          for (final u in run.units)
            _UnitRow(unit: u, startedAt: run.startedAt),
          if (run.units.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nenhum dispositivo estava na rede.',
                style: TextStyle(color: context.textSecondary, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({required this.unit, required this.startedAt});
  final SystemTestUnit unit;
  final DateTime startedAt;

  @override
  Widget build(BuildContext context) {
    final color = systemTestOutcomeColor(context, unit.outcome);
    final at = unit.at;
    return Container(
      key: ValueKey('system-test-unit-${unit.mac}'),
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.borderColor.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          Icon(systemTestOutcomeIcon(unit.outcome), size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              unit.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            unit.outcome.label +
                (at != null && unit.outcome == SystemTestOutcome.confirmed
                    ? ' · ${systemTestDuration(at.difference(startedAt))}'
                    : ''),
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class SystemTestHistorySheet extends ConsumerWidget {
  const SystemTestHistorySheet({super.key});

  static const sheetKey = ValueKey('system-test-history');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tests = ref.watch(systemTestsViewProvider);
    final runs = [
      if (tests.running case final r?) r,
      ...tests.recent.where((r) => r.id != tests.running?.id),
    ];
    return _SheetFrame(
      key: sheetKey,
      title: 'Últimos testes',
      child: runs.isEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
              child: Text(
                'Nenhum teste do sistema ainda. Um teste envia TESTAR a '
                'todos os dispositivos de uma vez; o relatório de cada um '
                'fica aqui.',
                style: TextStyle(
                    color: context.textSecondary, fontSize: 12.5, height: 1.4),
              ),
            )
          : ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
              itemCount: runs.length,
              itemBuilder: (context, i) {
                final r = runs[i];
                final color = systemTestVerdictColor(context, r.verdict);
                return ListTile(
                  key: ValueKey('system-test-row-${r.id}'),
                  dense: true,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  leading: Icon(
                    r.running
                        ? Icons.pending_rounded
                        : r.verdict == SystemTestVerdict.passed
                            ? Icons.task_alt_rounded
                            : r.verdict == SystemTestVerdict.cancelled
                                ? Icons.block_rounded
                                : Icons.report_rounded,
                    color: color,
                  ),
                  title: Text(
                    systemTestWhen(r.startedAt),
                    style: TextStyle(
                      color: context.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    '${r.verdict.label} · ${r.summary}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 11),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded,
                      color: context.textSecondary),
                  onTap: () => showSystemTestReport(context, r),
                );
              },
            ),
    );
  }
}
