import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_push_state.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_product.dart';

// Pieces of the "Atualização de firmware" screen. They draw an
// [OtaPushState]; nothing here decides anything about the push.

/// `1,2 s`, `47 s`, `2 min 05 s`.
String otaDurationText(Duration d) {
  if (d.inMilliseconds < 10000) {
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';
  }
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '${d.inMinutes} min $s s';
}

/// `912 KB`, `1,4 MB`.
String otaSizeText(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB';
}

// ── Steps ─────────────────────────────────────────────────────────────────────

/// The steps of the push, each with its state and the time it took. The
/// step that runs shows what it waits for and for how long: never a bare
/// spinner.
class OtaStepList extends StatelessWidget {
  const OtaStepList({super.key, required this.state, required this.now});

  final OtaPushState state;

  /// The clock of the screen: it ticks every second while a push runs.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < state.steps.length; i++) ...[
          if (i > 0)
            Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 52,
              endIndent: 16,
              color: context.borderColor.withValues(alpha: 0.5),
            ),
          _StepRow(step: state.steps[i], state: state, now: now),
        ],
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.state, required this.now});

  final OtaStep step;
  final OtaPushState state;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final running = step.status == OtaStepStatus.running;
    final waiting = step.status == OtaStepStatus.waiting;
    final failed = step.status == OtaStepStatus.failed;
    final sending = step.id == OtaStepId.send && running;

    final started = step.startedAt;
    final time = step.took != null
        ? otaDurationText(step.took!)
        : running && started != null
            ? '${now.difference(started).inSeconds.clamp(0, 99999)} s'
            : '';

    final detail = _detail(running);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 24, height: 24, child: _icon(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        step.id.label,
                        style: TextStyle(
                          color: waiting
                              ? context.textSecondary
                              : context.textPrimary,
                          fontSize: 14,
                          fontWeight:
                              running ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (time.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        time,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
                if (sending) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: state.progress,
                      minHeight: 8,
                      backgroundColor:
                          context.borderColor.withValues(alpha: 0.5),
                      color: AppColors.secondary,
                    ),
                  ),
                ],
                if (detail != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: TextStyle(
                      color: failed ? AppColors.error : context.textSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The line under the name of the step.
  String? _detail(bool running) {
    if (!running) return step.note;
    if (step.id == OtaStepId.send) {
      final left = state.remaining;
      final parts = [
        '${state.chunksDone} de ${state.chunksTotal} blocos',
        '${(state.progress * 100).floor()} %',
        if (state.kbPerSecond > 0) '${state.kbPerSecond.round()} KB/s',
        if (left != null) 'faltam ${otaDurationText(left)}',
      ];
      final waits = _waiting();
      return waits == null ? parts.join(' · ') : '${parts.join(' · ')}\n$waits';
    }
    return _waiting() ?? step.note;
  }

  /// "placa verificando a imagem · 4 s".
  String? _waiting() {
    final what = state.waitingFor;
    if (what == null) return null;
    final since = state.waitingSince;
    if (since == null) return what;
    return '$what · ${now.difference(since).inSeconds.clamp(0, 99999)} s';
  }

  Widget _icon(BuildContext context) => switch (step.status) {
        OtaStepStatus.waiting => Icon(
            Icons.radio_button_unchecked_rounded,
            size: 22,
            color: context.textSecondary.withValues(alpha: 0.5),
          ),
        OtaStepStatus.running => const Padding(
            padding: EdgeInsets.all(3),
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.secondary,
            ),
          ),
        OtaStepStatus.done => const Icon(
            Icons.check_circle_rounded,
            size: 22,
            color: AppColors.success,
          ),
        OtaStepStatus.failed => const Icon(
            Icons.error_rounded,
            size: 22,
            color: AppColors.error,
          ),
      };
}

// ── Report ───────────────────────────────────────────────────────────────────

Color otaToneColor(BuildContext context, OtaReportTone tone) => switch (tone) {
      OtaReportTone.progress => AppColors.secondary,
      // Stored, not delivered: informative, never the look of a success.
      OtaReportTone.neutral => context.textSecondary,
      OtaReportTone.good => AppColors.success,
      OtaReportTone.warning => AppColors.warning,
      OtaReportTone.bad => AppColors.error,
    };

IconData otaReportIcon(OtaReportKind kind) => switch (kind) {
      OtaReportKind.sending => Icons.upload_rounded,
      OtaReportKind.verifying => Icons.fact_check_outlined,
      OtaReportKind.boardRestarting => Icons.restart_alt_rounded,
      OtaReportKind.stored => Icons.inventory_2_outlined,
      OtaReportKind.boardUpdated => Icons.verified_rounded,
      OtaReportKind.boardRolledBack => Icons.settings_backup_restore_rounded,
      OtaReportKind.failed => Icons.error_outline_rounded,
    };

/// The card at the top of the screen: what was sent, who received it, what
/// changed — while the push runs and when it ended. The words come from
/// [otaPushReport]; nothing here decides what happened.
class OtaReportCard extends StatelessWidget {
  const OtaReportCard({
    super.key,
    required this.report,
    required this.state,
    required this.now,
  });

  final OtaPushReport report;
  final OtaPushState state;

  /// The clock of the screen: it ticks every second while a push runs.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final color = otaToneColor(context, report.tone);
    final change = report.versionChange;
    final reason = report.reason;
    final waiting = _waiting();
    final sending = state.phase == OtaPushPhase.sending;

    return Container(
      key: const ValueKey('ota-report-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            color.withValues(alpha: 0.08), context.surfaceColor),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(otaReportIcon(report.kind), color: color, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  report.title,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
          if (change != null) ...[
            const SizedBox(height: 10),
            Text(
              change,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (sending) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: state.progress,
                minHeight: 8,
                backgroundColor: context.borderColor.withValues(alpha: 0.5),
                color: AppColors.secondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${otaPercentText(state.progress)} · ${state.chunksDone} de '
              '${state.chunksTotal} blocos',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 12.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (waiting != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.secondary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    waiting,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (reason != null) ...[
            const SizedBox(height: 10),
            Text(
              reason,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 14),
          _Answer(question: 'O que foi enviado', answer: report.sent),
          const SizedBox(height: 10),
          _Answer(question: 'Quem recebeu', answer: report.receiver),
          const SizedBox(height: 10),
          _Answer(
            question: 'O que mudou',
            answer: report.changed,
            strong: !report.running,
          ),
        ],
      ),
    );
  }

  /// "Aguardando a placa reiniciar · 7 s".
  String? _waiting() {
    final what = state.waitingFor;
    if (what == null || !state.running) return null;
    final text = '${what[0].toUpperCase()}${what.substring(1)}';
    final since = state.waitingSince;
    if (since == null) return text;
    return '$text · ${now.difference(since).inSeconds.clamp(0, 99999)} s';
  }
}

class _Answer extends StatelessWidget {
  const _Answer({
    required this.question,
    required this.answer,
    this.strong = false,
  });

  final String question;
  final String answer;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question.toUpperCase(),
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          answer,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 14,
            fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

// ── Versions ─────────────────────────────────────────────────────────────────

/// "Versões em execução": every unit the tablet knows with the firmware it
/// runs now — the board first, then the mains powered units, then the
/// battery units. An image of the unit's family that is stored on the board
/// and was not delivered shows as pending; the version the unit runs is the
/// one it reported, never the one that waits.
class OtaRunningVersions extends StatefulWidget {
  const OtaRunningVersions({
    super.key,
    required this.units,
    required this.storedOnBoard,
    this.collapsedRows = 4,
  });

  final OtaUnitGroups units;
  final Map<SafrProductFamily, String> storedOnBoard;

  /// Rows of a group shown before "Mostrar todas".
  final int collapsedRows;

  @override
  State<OtaRunningVersions> createState() => _OtaRunningVersionsState();
}

class _OtaRunningVersionsState extends State<OtaRunningVersions> {
  final _open = <SafrProductFamily>{};

  @override
  Widget build(BuildContext context) {
    final units = widget.units;
    if (units.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDecoration(context),
        child: Text(
          'Nenhuma unidade conhecida ainda. As versões aparecem quando a '
          'placa e os dispositivos se anunciarem.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.35,
          ),
        ),
      );
    }

    final board = units.board;
    return Container(
      decoration: _cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ..._group(context, SafrProductFamily.board, 'Placa',
              [if (board != null) board],
              empty: 'A placa ainda não se anunciou.'),
          if (units.mains.isNotEmpty)
            ..._group(context, SafrProductFamily.node, 'Rede elétrica',
                units.mains),
          if (units.battery.isNotEmpty)
            ..._group(
                context, SafrProductFamily.leaf, 'Bateria', units.battery),
        ],
      ),
    );
  }

  List<Widget> _group(
    BuildContext context,
    SafrProductFamily family,
    String title,
    List<TopologyNode> rows, {
    String? empty,
  }) {
    final open = _open.contains(family);
    final cut = !open && rows.length > widget.collapsedRows;
    final shown = cut ? rows.sublist(0, widget.collapsedRows) : rows;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
        child: Text(
          '${title.toUpperCase()}'
          '${family == SafrProductFamily.board ? '' : ' · ${rows.length}'}',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
      ),
      if (rows.isEmpty && empty != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Text(
            empty,
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
        ),
      for (final node in shown)
        _UnitRow(
          node: node,
          family: family,
          pending: pendingFirmwareFor(node, widget.storedOnBoard),
        ),
      if (rows.length > widget.collapsedRows)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 6),
            child: TextButton(
              onPressed: () => setState(
                  () => open ? _open.remove(family) : _open.add(family)),
              child: Text(open
                  ? 'Mostrar menos'
                  : 'Mostrar todas (${rows.length})'),
            ),
          ),
        ),
    ];
  }
}

BoxDecoration _cardDecoration(BuildContext context) => BoxDecoration(
      color: context.surfaceColor,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: context.borderColor.withValues(alpha: 0.6),
        width: 0.5,
      ),
    );

class _UnitRow extends StatelessWidget {
  const _UnitRow({
    required this.node,
    required this.family,
    required this.pending,
  });

  final TopologyNode node;
  final SafrProductFamily family;
  final String? pending;

  @override
  Widget build(BuildContext context) {
    final isBoard = family == SafrProductFamily.board;
    final hasName = node.name?.isNotEmpty == true;
    final name = hasName ? node.name! : (isBoard ? 'Placa' : node.mac);
    final product = node.productLabel;
    final version = node.firmwareLabel;
    final known = version.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              switch (family) {
                SafrProductFamily.board => Icons.developer_board_rounded,
                SafrProductFamily.leaf => Icons.battery_std_rounded,
                _ => Icons.power_rounded,
              },
              size: 18,
              color: context.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFamily: hasName || isBoard ? null : 'monospace',
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  product.isEmpty ? 'Produto não informado' : product,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  known ? version : '—',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: known ? context.textPrimary : context.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (pending != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    otaPendingText(pending!),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: AppColors.warning,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Details ──────────────────────────────────────────────────────────────────

/// The header of "Detalhes": the steps, the numbers and the log of the push
/// sit under it and open on a tap.
class OtaDetailsHeader extends StatelessWidget {
  const OtaDetailsHeader({
    super.key,
    required this.open,
    required this.summary,
    required this.onToggle,
  });

  final bool open;

  /// "7 passos · 12 linhas de registro".
  final String summary;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onToggle,
        child: Semantics(
          button: true,
          expanded: open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.list_alt_rounded,
                    size: 20, color: context.textSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Detalhes',
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        summary,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  open
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: context.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The numbers of a push that ended.
class OtaCounters extends StatelessWidget {
  const OtaCounters({super.key, required this.state});
  final OtaPushState state;

  @override
  Widget build(BuildContext context) {
    final total = state.totalTime;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(context),
      child: Wrap(
        spacing: 20,
        runSpacing: 10,
        children: [
          if (total != null)
            _Counter(label: 'Tempo total', value: otaDurationText(total)),
          _Counter(
            label: 'Velocidade média',
            value: '${state.kbPerSecond.round()} KB/s',
          ),
          _Counter(label: 'Blocos reenviados', value: '${state.retries}'),
          _Counter(label: 'Retomadas', value: '${state.resumes}'),
        ],
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(color: context.textSecondary, fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ── Log ───────────────────────────────────────────────────────────────────────

/// What happened, oldest first, with the time to the second; "Copiar" puts
/// all of it on the clipboard.
class OtaLogCard extends StatelessWidget {
  const OtaLogCard({super.key, required this.state});
  final OtaPushState state;

  @override
  Widget build(BuildContext context) {
    final log = state.log;
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    log.isEmpty
                        ? 'Nada aconteceu ainda.'
                        : '${log.length} ${log.length == 1 ? 'linha' : 'linhas'}',
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 12),
                  ),
                ),
                TextButton.icon(
                  onPressed: log.isEmpty ? null : () => _copy(context),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copiar'),
                ),
              ],
            ),
          ),
          if (log.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final line in log) _LogRow(line: line)],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: state.logText));
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Registro copiado.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.line});
  final OtaLogLine line;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.time,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.35,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              line.text,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
