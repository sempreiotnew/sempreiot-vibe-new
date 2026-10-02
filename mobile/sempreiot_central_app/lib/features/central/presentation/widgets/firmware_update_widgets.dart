import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/ota_push_state.dart';

// The push's steps, counters and log, for "Registro" on "Atualizar
// dispositivos". They draw an [OtaPushState]; nothing here decides anything
// about the push.

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

BoxDecoration _cardDecoration(BuildContext context) => BoxDecoration(
      color: context.surfaceColor,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: context.borderColor.withValues(alpha: 0.6),
        width: 0.5,
      ),
    );

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

/// The log of the push and the log of the rollout as one, oldest first. Two
/// lines of the same instant keep the order they have in their own log, the
/// push's first.
List<OtaLogLine> otaMergedLog(List<OtaLogLine> push, List<OtaLogLine> rollout) {
  if (rollout.isEmpty) return push;
  if (push.isEmpty) return rollout;
  final out = <OtaLogLine>[];
  var i = 0, j = 0;
  while (i < push.length && j < rollout.length) {
    if (rollout[j].at.isBefore(push[i].at)) {
      out.add(rollout[j++]);
    } else {
      out.add(push[i++]);
    }
  }
  return out
    ..addAll(push.skip(i))
    ..addAll(rollout.skip(j));
}

/// What happened, oldest first, with the time to the second; "Copiar" puts
/// all of it on the clipboard.
class OtaLogCard extends StatelessWidget {
  const OtaLogCard({super.key, required this.state, this.log});
  final OtaPushState state;

  /// The lines to show; null = the push's own.
  final List<OtaLogLine>? log;

  List<OtaLogLine> get _lines => log ?? state.log;

  @override
  Widget build(BuildContext context) {
    final log = _lines;
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
    await Clipboard.setData(
        ClipboardData(text: _lines.map((l) => l.toString()).join('\n')));
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
