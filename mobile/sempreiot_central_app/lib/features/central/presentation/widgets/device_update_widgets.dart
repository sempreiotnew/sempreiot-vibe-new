import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart' show OtaRun, OtaRunUnit;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/credentials_admin_provider.dart'
    show EditorRole, EditorRoleLabel;
import '../../application/device_update_controller.dart';
import '../../application/device_update_history.dart';
import '../../application/device_update_selection.dart';
import '../../application/device_update_state.dart';
import '../../application/device_update_words.dart';
import '../../application/firmware_library_provider.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_pin_policy.dart';
import '../../application/ota_push_state.dart';
import '../../application/ota_rollout_state.dart' show OtaPauseCause;
import '../../application/ota_rollout_report.dart' show otaRolloutViewProvider;
import '../../application/ota_rollout_words.dart' show otaFirmwareWord;
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_product.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import 'device_avatar.dart' show deviceDisplayName;
import 'editor_gate.dart' show requestEditorRole;
import 'firmware_update_widgets.dart'
    show OtaCounters, OtaLogCard, OtaStepList, otaMergedLog;

// The pieces of "Atualizar dispositivos" around the map: the pill on the
// status strip, the bar under the map, the firmware sheet and a unit's
// details. They lay out what application/device_update_* decide.

/// Ticks once a second while a run is on screen (elapsed time, what is left).
class _Clock extends StateNotifier<DateTime> {
  _Clock() : super(DateTime.now()) {
    _timer = Timer.periodic(
        const Duration(seconds: 1), (_) => state = DateTime.now());
  }

  late final Timer _timer;

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
}

final deviceUpdateClockProvider =
    StateNotifierProvider.autoDispose<_Clock, DateTime>((ref) => _Clock());

Color _toneColor(BuildContext context, DeviceUpdateTone tone) => switch (tone) {
      DeviceUpdateTone.info => context.textPrimary,
      DeviceUpdateTone.ok => AppColors.success,
      DeviceUpdateTone.warn => AppColors.warning,
      DeviceUpdateTone.error => AppColors.error,
    };

/// The units of [family] the tablet hears now (the board: its key).
List<String> deviceUpdateOnline(
    List<TopologyNode> nodes, SafrProductFamily family) {
  if (family == SafrProductFamily.board) return const [deviceUpdateBoardKey];
  return [
    for (final n in nodes)
      if (n.layer > 0 && n.online && unitFamily(n) == family) n.mac,
  ];
}

/// While the mesh joins the restarted board again: how many of the nodes
/// the run waits for were heard since the restart.
({int back, int total})? _meshBackCount(
    DeviceUpdateRun run, List<TopologyNode> nodes) {
  final since = run.boardRestartedAt;
  if (run.stage != DeviceUpdateStage.reconnecting || since == null) {
    return null;
  }
  final wanted = {...?run.queues[SafrProductFamily.node]};
  if (wanted.isEmpty) return null;
  var back = 0;
  for (final n in nodes) {
    if (wanted.contains(n.mac) && n.lastSeenAt.isAfter(since)) back++;
  }
  return (back: back, total: wanted.length);
}

/// Name of a unit of a run, for the bar and the details.
String deviceUpdateNameOf(List<TopologyNode> nodes, String key) {
  if (key == deviceUpdateBoardKey) return 'Central (placa)';
  for (final n in nodes) {
    if (n.mac == key) return deviceDisplayName(n);
  }
  return key;
}

// ── The pill on the status strip ────────────────────────────────────────────

class DeviceUpdatePill extends StatelessWidget {
  const DeviceUpdatePill({super.key, required this.run, required this.push});
  final DeviceUpdateRun run;
  final OtaPushState push;

  @override
  Widget build(BuildContext context) {
    final fam = run.family;
    final phase = run.all
        ? 'FASE ${run.phase + 1} DE ${run.phases.length} · '
            '${deviceUpdatePhaseName(fam).toUpperCase()} · '
        : '';
    final units = run.unitsOf(fam);
    final done = units.where((u) => u.state == SafrOtaUnitState.done).length;
    final (String label, Color color, bool spin) = switch (run.stage) {
      DeviceUpdateStage.pushing => (
          '${phase}ENVIANDO À PLACA · ${(push.progress * 100).round()} %',
          AppColors.secondary,
          true
        ),
      DeviceUpdateStage.reconnecting => (
          '${phase}AGUARDANDO A REDE',
          AppColors.secondary,
          true
        ),
      DeviceUpdateStage.rolling when run.pausedBy == OtaPauseCause.alarm => (
          'PAUSADO POR ALARME',
          AppColors.error,
          false
        ),
      DeviceUpdateStage.rolling when run.paused => (
          'PAUSADO',
          AppColors.warning,
          false
        ),
      DeviceUpdateStage.rolling => (
          '${phase}ATUALIZANDO · $done DE ${units.length}',
          AppColors.secondary,
          true
        ),
      DeviceUpdateStage.deciding => (
          'AGUARDANDO SUA DECISÃO',
          AppColors.warning,
          false
        ),
      DeviceUpdateStage.ended => switch (run.end) {
          DeviceUpdateEnd.done => ('CONCLUÍDO', AppColors.success, false),
          DeviceUpdateEnd.failed => ('FALHOU', AppColors.error, false),
          DeviceUpdateEnd.stopped => ('PARADO', AppColors.warning, false),
          DeviceUpdateEnd.cancelled => ('CANCELADO', AppColors.warning, false),
          _ => ('PARCIAL', AppColors.warning, false),
        },
    };
    return Container(
      key: const ValueKey('device-update-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spin) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

// ── The bar under the map ───────────────────────────────────────────────────

class DeviceUpdateBar extends ConsumerWidget {
  const DeviceUpdateBar({super.key, required this.nodes});

  /// Every unit the tablet knows, the board included.
  final List<TopologyNode> nodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(deviceUpdateProvider);
    if (run != null) return _RunBar(run: run, nodes: nodes);
    return _SelectBar(nodes: nodes);
  }
}

/// Wide: one line. Narrow (a phone, the tablet upright): the leading part
/// on top, the words and the buttons under it.
class _BarFrame extends StatelessWidget {
  const _BarFrame({
    required this.border,
    required this.texts,
    required this.actions,
    this.leading,
  });

  final Color border;
  final Widget? leading;
  final Widget texts;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('device-update-bar'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final buttons = Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        );
        if (wide) {
          return Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(child: texts),
              const SizedBox(width: 12),
              buttons,
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (leading != null) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: leading,
              ),
              const SizedBox(height: 8),
            ],
            texts,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: buttons),
            ],
          ],
        );
      }),
    );
  }
}

class _BarTexts extends StatelessWidget {
  const _BarTexts({required this.title, required this.sub, this.color});
  final String title;
  final String sub;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color ?? context.textPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.textSecondary, fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}

/// Nothing running: choose units, or update everything.
class _SelectBar extends ConsumerWidget {
  const _SelectBar({required this.nodes});
  final List<TopologyNode> nodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = ref.watch(deviceUpdateSelectionProvider);
    final pick = ref.read(deviceUpdateSelectionProvider.notifier);

    Widget quick(SafrProductFamily f, String label, IconData icon) {
      final keys = deviceUpdateOnline(nodes, f);
      final on = sel.family == f &&
          sel.keys.length == keys.length &&
          sel.keys.containsAll(keys);
      return _QuickChip(
        key: ValueKey('quick-${f.name}'),
        label: f == SafrProductFamily.board ? label : '$label (${keys.length})',
        icon: on ? Icons.check_rounded : icon,
        on: on,
        enabled: keys.isNotEmpty,
        onTap: () => pick.pickAll(f, keys),
      );
    }

    final chips = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        quick(SafrProductFamily.board, 'Central', Icons.developer_board_rounded),
        const SizedBox(width: 8),
        quick(SafrProductFamily.node, 'Nodes', Icons.cell_tower_rounded),
        const SizedBox(width: 8),
        quick(SafrProductFamily.leaf, 'Leafs',
            Icons.sensors_rounded),
      ],
    );

    if (sel.isEmpty) {
      return _BarFrame(
        border: context.borderColor.withValues(alpha: 0.6),
        leading: chips,
        texts: _BarTexts(
          title: '',
          sub: sel.note ?? 'ou toque nos dispositivos no mapa',
          color: sel.note != null ? AppColors.warning : null,
        ),
        actions: [
          FilledButton.icon(
            key: const ValueKey('update-all'),
            onPressed: () => showDeviceUpdateSheet(context, all: true),
            icon: const Icon(Icons.system_update_alt_rounded, size: 18),
            label: const Text('Atualizar tudo'),
          ),
        ],
      );
    }

    final runs = deviceUpdateRunsText(_runsOf(nodes, sel.keys));
    return _BarFrame(
      border: AppColors.secondary.withValues(alpha: 0.45),
      leading: chips,
      texts: _BarTexts(
        title: deviceUpdateSelectionTitle(sel),
        sub: sel.note ?? runs,
        color: null,
      ),
      actions: [
        TextButton(
          onPressed: pick.clear,
          child: const Text('Limpar'),
        ),
        FilledButton.icon(
          key: const ValueKey('update-chosen'),
          onPressed: () => showDeviceUpdateSheet(context, all: false),
          icon: const Icon(Icons.system_update_alt_rounded, size: 18),
          label: const Text('Atualizar'),
        ),
      ],
    );
  }
}

String _versionOf(List<TopologyNode> nodes, String mac) {
  for (final n in nodes) {
    if (n.mac == mac) return n.fwVersion ?? '';
  }
  return '';
}

/// What each of [keys] runs ('' = never said).
List<String> _runsOf(List<TopologyNode> nodes, Iterable<String> keys) => [
      for (final k in keys)
        k == deviceUpdateBoardKey ? _boardVersion(nodes) : _versionOf(nodes, k),
    ];

String _boardVersion(List<TopologyNode> nodes) {
  for (final n in nodes) {
    if (unitFamily(n) == SafrProductFamily.board) return n.fwVersion ?? '';
  }
  return '';
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    super.key,
    required this.label,
    required this.icon,
    required this.on,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool on;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = on ? AppColors.secondary : context.textPrimary;
    return Semantics(
      button: true,
      selected: on,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Material(
          color: on
              ? AppColors.secondary.withValues(alpha: 0.16)
              : Colors.transparent,
          shape: StadiumBorder(
            side: BorderSide(
              color: on
                  ? AppColors.secondary
                  : AppColors.secondary.withValues(alpha: 0.35),
            ),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: enabled ? onTap : null,
            child: Container(
              height: 40,
              padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A run on screen: where it is, and its controls.
class _RunBar extends ConsumerWidget {
  const _RunBar({required this.run, required this.nodes});
  final DeviceUpdateRun run;
  final List<TopologyNode> nodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final push = ref.watch(otaPushViewProvider);
    final now =
        run.running ? ref.watch(deviceUpdateClockProvider) : DateTime.now();
    final ctl = ref.read(deviceUpdateProvider.notifier);
    final text = deviceUpdateBarText(run, push, now,
        nameOf: (k) => deviceUpdateNameOf(nodes, k),
        meshBack: _meshBackCount(run, nodes));
    final tone = _toneColor(context, text.tone);
    // Every unit of this family that does not run the target ("Tentar de
    // novo" offers them all again): failed, skipped, never offered.
    final failed = run.notUpdated(run.family).length;

    Future<void> say(Future<String?> f) async {
      final why = await f;
      if (why != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(why)));
      }
    }

    // Anything that starts something on the units asks the PIN first.
    Future<void> withPin(Future<String?> Function(String by) action) async {
      final role = await ensureOtaPin(context, ref);
      if (role == null || !context.mounted) return;
      await say(action(role.auditName));
    }

    final actions = <Widget>[
      if (run.stage == DeviceUpdateStage.rolling &&
          !run.paused &&
          run.family != SafrProductFamily.board)
        OutlinedButton.icon(
          onPressed: () => say(ctl.pause()),
          icon: const Icon(Icons.pause_rounded, size: 18),
          label: const Text('Pausar'),
        ),
      if (run.running && run.paused)
        FilledButton.icon(
          onPressed: () => withPin((by) => ctl.resume(by: by)),
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('Retomar'),
        ),
      if (run.stage == DeviceUpdateStage.deciding) ...[
        OutlinedButton.icon(
          onPressed: () =>
              withPin((by) => Future.value(ctl.retryFailed(by: by))),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text('Tentar de novo ($failed)'),
        ),
        OutlinedButton(
          onPressed: () => ctl.decide(goOn: false),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            side: BorderSide(
                color: AppColors.error.withValues(alpha: 0.6), width: 1.2),
          ),
          child: const Text('Parar aqui'),
        ),
        FilledButton(
          onPressed: () => withPin((by) async {
            ctl.decide(goOn: true, by: by);
            return null;
          }),
          child: const Text('Continuar'),
        ),
      ],
      if (run.running &&
          run.stage != DeviceUpdateStage.deciding &&
          !(run.family == SafrProductFamily.board &&
              push.phase == OtaPushPhase.boardRestarting))
        OutlinedButton(
          onPressed: () => _confirmAbort(context, ctl),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            side: BorderSide(
                color: AppColors.error.withValues(alpha: 0.6), width: 1.2),
          ),
          child: const Text('Cancelar'),
        ),
      if (!run.running && run.end == DeviceUpdateEnd.partial && failed > 0)
        FilledButton.icon(
          onPressed: () =>
              withPin((by) => Future.value(ctl.retryFailed(by: by))),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text('Tentar de novo ($failed)'),
        ),
      if (!run.running)
        OutlinedButton(
          key: const ValueKey('update-done'),
          onPressed: ctl.dismiss,
          child: const Text('Concluir'),
        ),
    ];

    return _BarFrame(
      border: text.tone == DeviceUpdateTone.info
          ? AppColors.secondary.withValues(alpha: 0.35)
          : tone.withValues(alpha: 0.5),
      leading: run.all ? _PhaseStepper(run: run) : null,
      texts: _BarTexts(
        title: text.title,
        sub: text.sub,
        color: text.tone == DeviceUpdateTone.info ? null : tone,
      ),
      actions: actions,
    );
  }

  Future<void> _confirmAbort(
      BuildContext context, DeviceUpdateController ctl) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancelar a atualização?'),
        content: const Text(
            'O dispositivo que está baixando agora termina. Os que ainda '
            'aguardam ficam na versão que têm.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Voltar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancelar a atualização')),
        ],
      ),
    );
    if (ok == true) await ctl.abort();
  }
}

/// "Placa ✓ › Nós 2/4 › Detectores 0/2".
class _PhaseStepper extends StatelessWidget {
  const _PhaseStepper({required this.run});
  final DeviceUpdateRun run;

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    for (var i = 0; i < run.phases.length; i++) {
      final f = run.phases[i];
      final units = run.unitsOf(f);
      final done = units.where((u) => u.state == SafrOtaUnitState.done).length;
      // A phase that is over with a unit not updated is not a check.
      final failed = i < run.phase || !run.running
          ? run.notUpdated(f).length
          : units.where((u) => u.state == SafrOtaUnitState.failed).length;
      final ended = !run.running;
      final (Color color, IconData icon) = i < run.phase
          ? (failed > 0
              ? (AppColors.warning, Icons.error_rounded)
              : (AppColors.success, Icons.check_circle_rounded))
          : i == run.phase
              ? (failed > 0 || run.stage == DeviceUpdateStage.deciding
                  ? (AppColors.warning, Icons.error_rounded)
                  : ended && run.end == DeviceUpdateEnd.done
                      ? (AppColors.success, Icons.check_circle_rounded)
                      : (AppColors.secondary, _icon(f)))
              : ended
                  ? (context.textSecondary, Icons.block_rounded)
                  : (context.textSecondary, _icon(f));
      if (i > 0) {
        parts.add(Icon(Icons.chevron_right_rounded,
            size: 16, color: context.textSecondary.withValues(alpha: 0.6)));
      }
      parts.add(Container(
        height: 30,
        padding: const EdgeInsets.fromLTRB(7, 0, 10, 0),
        decoration: BoxDecoration(
          color: i == run.phase && run.running
              ? color.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              f == SafrProductFamily.board
                  ? deviceUpdatePhaseName(f)
                  : '${deviceUpdatePhaseName(f)} $done/${units.length}',
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ));
    }
    return Row(
      key: const ValueKey('phase-stepper'),
      mainAxisSize: MainAxisSize.min,
      children: parts,
    );
  }

  static IconData _icon(SafrProductFamily f) => switch (f) {
        SafrProductFamily.board => Icons.developer_board_rounded,
        SafrProductFamily.node => Icons.cell_tower_rounded,
        _ => Icons.sensors_rounded,
      };
}

// ── The firmware sheet ──────────────────────────────────────────────────────

/// "Atualizar" (the units chosen) or "Atualizar tudo": which firmware, what
/// happens, confirm.
Future<void> showDeviceUpdateSheet(BuildContext context, {required bool all}) {
  final size = MediaQuery.sizeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxWidth: 640, maxHeight: size.height * 0.92),
    builder: (_) => DeviceUpdateSheet(all: all),
  );
}

class DeviceUpdateSheet extends ConsumerStatefulWidget {
  const DeviceUpdateSheet({super.key, required this.all});
  final bool all;

  @override
  ConsumerState<DeviceUpdateSheet> createState() => _DeviceUpdateSheetState();
}

class _DeviceUpdateSheetState extends ConsumerState<DeviceUpdateSheet> {
  String? _chosen;
  bool _starting = false;

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(firmwareLibraryProvider);
    final sel = ref.watch(deviceUpdateSelectionProvider);
    final nodes = ref.watch(topologyProvider);
    final family = sel.family;

    // What can be chosen, newest first; null = enabled.
    final options = <({
      String version,
      String file,
      String desc,
      DeviceUpdateVersionKind kind,
    })>[];
    // Against what the chosen units run (the board, for "Atualizar tudo").
    final runs = widget.all
        ? [_boardVersion(nodes)].where((v) => v.isNotEmpty).toList()
        : _runsOf(nodes, sel.keys);
    if (widget.all) {
      for (final v in lib.completeVersions) {
        final kind = deviceUpdateVersionKind(v, runs);
        options.add((
          version: v,
          file: 'placa · nós · detectores',
          desc: kind == DeviceUpdateVersionKind.newer
              ? '3 imagens assinadas'
              : deviceUpdateNotNewerText(v, runs)
                  .replaceFirst('eles rodam', 'a placa roda')
                  .replaceFirst('ele roda', 'a placa roda')
                  .replaceFirst('ele já roda', 'a placa já roda'),
          kind: kind,
        ));
      }
    } else if (family != null) {
      for (final e in lib.of(family)) {
        final kind = deviceUpdateVersionKind(e.version, runs);
        options.add((
          version: e.version,
          file: e.fileName,
          desc: kind == DeviceUpdateVersionKind.newer
              ? '${_capital(otaFirmwareWord(family))} · ${_mb(e.size)}'
              : deviceUpdateNotNewerText(e.version, runs),
          kind: kind,
        ));
      }
    }
    // Pre-chosen: the newest version that is newer; none when there is none
    // (going back or reinstalling is always the operator's own tap).
    final newest = options
        .where((o) => o.kind == DeviceUpdateVersionKind.newer)
        .map((o) => o.version)
        .firstOrNull;
    final chosen = _chosen ?? newest;
    final chosenKind = options
        .where((o) => o.version == chosen)
        .map((o) => o.kind)
        .firstOrNull;

    final who = widget.all
        ? 'A placa, ${deviceUpdateCount(SafrProductFamily.node, deviceUpdateOnline(nodes, SafrProductFamily.node).length)} '
            'e ${deviceUpdateCount(SafrProductFamily.leaf, deviceUpdateOnline(nodes, SafrProductFamily.leaf).length)}'
        : [
            family == SafrProductFamily.board
                ? 'A central (placa)'
                : sel.keys.map((k) => deviceUpdateNameOf(nodes, k)).join(', '),
            deviceUpdateRunsText(_runsOf(nodes, sel.keys)),
          ].where((t) => t.isNotEmpty).join(' · ');
    final title = widget.all
        ? 'Atualizar tudo'
        : family == SafrProductFamily.board
            ? 'Atualizar a placa'
            : 'Atualizar ${deviceUpdateCount(family ?? SafrProductFamily.node, sel.keys.length)}';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(title,
              style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(who,
              style: TextStyle(color: context.textSecondary, fontSize: 13)),
          const SizedBox(height: 16),
          _Label(widget.all ? 'VERSÃO NO TABLET' : 'FIRMWARE NO TABLET'),
          const SizedBox(height: 8),
          if (options.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                widget.all
                    ? 'O tablet não tem as três imagens (placa, nós e '
                        'detectores) de uma mesma versão. Toque em "Procurar '
                        'no tablet" e escolha os arquivos .bin.'
                    : 'Nenhum ${otaFirmwareWord(family ?? SafrProductFamily.node)} '
                        'no tablet. Toque em "Procurar no tablet" e escolha o '
                        'arquivo .bin.',
                style: TextStyle(color: context.textSecondary, fontSize: 13),
              ),
            ),
          for (final o in options) ...[
            _VersionOption(
              version: o.version,
              file: o.file,
              desc: o.desc,
              badge: o.version == newest
                  ? ('MAIS NOVO', AppColors.success)
                  : switch (o.kind) {
                      DeviceUpdateVersionKind.older => (
                          'VERSÃO ANTERIOR',
                          AppColors.warning
                        ),
                      DeviceUpdateVersionKind.same => (
                          'REINSTALAR',
                          AppColors.secondary
                        ),
                      _ => null,
                    },
              chosen: o.version == chosen,
              onTap: () => setState(() => _chosen = o.version),
            ),
            const SizedBox(height: 8),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: lib.busy ? null : _import,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Procurar no tablet'),
            ),
          ),
          if (widget.all && chosen != null) ...[
            const SizedBox(height: 8),
            const _Label('EM FASES, UMA DEPOIS DA OUTRA'),
            const SizedBox(height: 8),
            _Plan(nodes: nodes, target: chosen),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.bgColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 18, color: AppColors.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    deviceUpdateSheetInfo(family, all: widget.all),
                    style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 12.5,
                        height: 1.45),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                key: const ValueKey('update-confirm'),
                onPressed: chosen == null || chosenKind == null || _starting
                    ? null
                    : () => _start(chosen, family, chosenKind, runs),
                child: Text(chosen == null || chosenKind == null
                    ? (widget.all ? 'Atualizar tudo' : 'Atualizar')
                    : deviceUpdateConfirmText(chosenKind, chosen,
                        all: widget.all)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _import() async {
    final said =
        await ref.read(firmwareLibraryProvider.notifier).importFromTablet();
    if (said != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
    }
  }

  Future<void> _start(String version, SafrProductFamily? family,
      DeviceUpdateVersionKind kind, List<String> runs) async {
    // Going back or reinstalling: asked once more, never by default.
    final ask = deviceUpdateAskFirst(kind, version, runs);
    if (ask != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ask.title),
          content: Text(ask.body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Voltar')),
            FilledButton(
                key: const ValueKey('update-confirm-older'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                    deviceUpdateConfirmText(kind, version, all: widget.all))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final reinstall = kind == DeviceUpdateVersionKind.same;
    final role = await ensureOtaPin(context, ref);
    if (role == null || !mounted) return;
    final by = role.auditName;
    setState(() => _starting = true);
    final ctl = ref.read(deviceUpdateProvider.notifier);
    final String? refused;
    if (widget.all) {
      refused = await ctl.startAll(version, reinstall: reinstall, by: by);
    } else {
      final sel = ref.read(deviceUpdateSelectionProvider);
      final image = family == null
          ? null
          : ref.read(firmwareLibraryProvider).image(family, version);
      refused = image == null
          ? 'O firmware escolhido não está mais no tablet.'
          : await ctl.start(
              family: family!,
              keys: sel.keys,
              image: image,
              reinstall: reinstall,
              by: by);
    }
    if (!mounted) return;
    setState(() => _starting = false);
    if (refused != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(refused)));
      return;
    }
    ref.read(deviceUpdateSelectionProvider.notifier).clear();
    Navigator.pop(context);
  }
}

String _capital(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _mb(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(2).replaceAll('.', ',')} MB';

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: context.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      );
}

class _VersionOption extends StatelessWidget {
  const _VersionOption({
    required this.version,
    required this.file,
    required this.desc,
    required this.badge,
    required this.chosen,
    required this.onTap,
  });

  final String version;
  final String file;
  final String desc;

  /// "MAIS NOVO" / "VERSÃO ANTERIOR" / "REINSTALAR"; null = none.
  final (String, Color)? badge;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = this.badge;
    return Material(
      color: chosen
          ? AppColors.secondary.withValues(alpha: 0.08)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: chosen ? AppColors.secondary : context.borderColor),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                chosen
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: chosen ? AppColors.secondary : context.textSecondary,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(vText(version),
                            style: TextStyle(
                                color: context.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        Text(file,
                            style: TextStyle(
                                color: context.textSecondary,
                                fontSize: 12,
                                fontFamily: 'monospace')),
                        if (badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: badge.$2.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(badge.$1,
                                style: TextStyle(
                                    color: badge.$2,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.6)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(desc,
                        style: TextStyle(
                            color: context.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The three phases of "Atualizar tudo", in the sheet.
class _Plan extends StatelessWidget {
  const _Plan({required this.nodes, required this.target});
  final List<TopologyNode> nodes;
  final String target;

  @override
  Widget build(BuildContext context) {
    final n = deviceUpdateOnline(nodes, SafrProductFamily.node).length;
    final l = deviceUpdateOnline(nodes, SafrProductFamily.leaf).length;
    final board = _boardVersion(nodes);
    final rows = [
      (SafrProductFamily.board, 'Placa', board, '~1 min'),
      if (n > 0)
        (
          SafrProductFamily.node,
          'Nós ($n)',
          '',
          '~${((n * 40) / 60).ceil()} min'
        ),
      if (l > 0)
        (SafrProductFamily.leaf, 'Detectores ($l)', '', '~${l * 3} min'),
    ];
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(top: BorderSide(color: context.borderColor)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: Colors.transparent,
                    foregroundColor: AppColors.secondary,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: AppColors.secondary, width: 1.6),
                      ),
                      alignment: Alignment.center,
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rows[i].$2,
                            style: TextStyle(
                                color: context.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600)),
                        Text(deviceUpdatePhaseHow(rows[i].$1),
                            style: TextStyle(
                                color: context.textSecondary, fontSize: 11.5)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        rows[i].$3.isEmpty
                            ? '→ ${vText(target)}'
                            : '${vText(rows[i].$3)} → ${vText(target)}',
                        style: const TextStyle(
                            color: AppColors.secondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600),
                      ),
                      Text(rows[i].$4,
                          style: TextStyle(
                              color: context.textSecondary, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── A unit of the run ───────────────────────────────────────────────────────

Future<void> showDeviceUpdateUnitSheet(BuildContext context, String key) {
  final size = MediaQuery.sizeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxWidth: 520, maxHeight: size.height * 0.8),
    builder: (_) => _UnitSheet(unitKey: key),
  );
}

class _UnitSheet extends ConsumerWidget {
  const _UnitSheet({required this.unitKey});
  final String unitKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(deviceUpdateProvider);
    final nodes = ref.watch(topologyProvider);
    final u = run?.units[unitKey];
    final name = deviceUpdateNameOf(nodes, unitKey);
    final color = switch (u?.state) {
      SafrOtaUnitState.done => AppColors.success,
      SafrOtaUnitState.failed => AppColors.error,
      final s? when s.active => AppColors.secondary,
      _ => context.textSecondary,
    };
    final why = u == null ? '' : deviceUpdateWhy(u);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (u == null || run == null)
            Text('Fora desta atualização.',
                style: TextStyle(color: context.textSecondary, fontSize: 13))
          else ...[
            Text(
              u.state == SafrOtaUnitState.done
                  ? '${vText(u.versionBefore.isEmpty ? '?' : u.versionBefore)} → ${vText(u.version)}'
                  : 'Roda ${vText(u.version.isEmpty ? '?' : u.version)} · alvo ${vText(run.target)}',
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(deviceUpdateUnitText(u),
                    style: TextStyle(
                        color: color,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                if (u.attempts > 1 || u.state == SafrOtaUnitState.failed)
                  Text(
                    u.attempts == 1
                        ? '1 tentativa'
                        : '${u.attempts} tentativas',
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 12.5),
                  ),
              ],
            ),
            if (why.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(why,
                  style: TextStyle(
                      color: context.textPrimary, fontSize: 13, height: 1.45)),
            ],
          ],
          _UnitHistory(unitKey: unitKey),
        ],
      ),
    );
  }
}

// ── The log ─────────────────────────────────────────────────────────────────

/// "Registro": the steps of the last push to the board, its counters, and
/// every line of the push and of the rollouts by time ("Copiar" takes all).
Future<void> showDeviceUpdateLog(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxWidth: 720, maxHeight: size.height * 0.92),
    builder: (_) => const _LogSheet(),
  );
}

class _LogSheet extends ConsumerWidget {
  const _LogSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final push = ref.watch(otaPushViewProvider);
    final rollout = ref.watch(otaRolloutViewProvider);
    final now = ref.watch(deviceUpdateClockProvider);
    final log = otaMergedLog(push.log, rollout.log);
    return SingleChildScrollView(
      key: const ValueKey('device-update-log'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Registro',
              style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w500)),
          if (push.steps.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _Label('ENVIO À PLACA'),
            const SizedBox(height: 8),
            OtaStepList(state: push, now: now),
          ],
          if (push.finished) ...[
            const SizedBox(height: 12),
            OtaCounters(state: push),
          ],
          const SizedBox(height: 16),
          const _Label('REGISTRO'),
          const SizedBox(height: 8),
          OtaLogCard(state: push, log: log),
          const SizedBox(height: 20),
          const _HistorySection(),
        ],
      ),
    );
  }
}

/// The update history of a unit, newest first (OtaRunUnits).
final _unitHistoryProvider =
    FutureProvider.autoDispose.family<List<(OtaRun, OtaRunUnit)>, String>(
  (ref, key) => ref.watch(deviceUpdateHistoryProvider).ofUnit(key),
);

/// The last updates, newest first, with their units (OtaRuns).
final _recentRunsProvider =
    FutureProvider.autoDispose<List<(OtaRun, List<OtaRunUnit>)>>(
  (ref) => ref.watch(deviceUpdateHistoryProvider).recent(limit: 50),
);

class _UnitHistory extends ConsumerWidget {
  const _UnitHistory({required this.unitKey});
  final String unitKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_unitHistoryProvider(unitKey)).valueOrNull ?? [];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Label('ATUALIZAÇÕES ANTERIORES'),
          const SizedBox(height: 6),
          for (final (run, unit) in rows)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(deviceUpdateHistoryLine(run, unit),
                  style:
                      TextStyle(color: context.textSecondary, fontSize: 12.5)),
            ),
        ],
      ),
    );
  }
}

/// "Registro" → Histórico: every update kept on the tablet, and "Copiar
/// histórico" (CSV) — what a lab asks for (OTA brief step 6).
class _HistorySection extends ConsumerWidget {
  const _HistorySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodes = ref.watch(topologyProvider);
    final runs = ref.watch(_recentRunsProvider).valueOrNull ?? [];
    return Column(
      key: const ValueKey('device-update-history'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _Label('HISTÓRICO')),
            if (runs.isNotEmpty)
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: deviceUpdateHistoryCsv(runs)));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Histórico copiado (CSV).')));
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copiar histórico'),
              ),
          ],
        ),
        if (runs.isEmpty)
          Text('Nenhuma atualização registrada neste tablet.',
              style: TextStyle(color: context.textSecondary, fontSize: 12.5)),
        for (final (run, units) in runs) ...[
          const SizedBox(height: 10),
          Text(_runTitle(run, units),
              style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          for (final u in units)
            if (u.state != SafrOtaUnitState.done.name)
              Text(
                '  ${deviceUpdateNameOf(nodes, u.unitKey)} · '
                '${deviceUpdateHistoryLine(run, u).split(' · ').skip(1).join(' · ')}',
                style: TextStyle(color: context.textSecondary, fontSize: 12),
              ),
        ],
      ],
    );
  }

  static String _runTitle(OtaRun run, List<OtaRunUnit> units) {
    String two(int v) => v.toString().padLeft(2, '0');
    final at = run.startedAt.toLocal();
    final done = units.where((u) => u.state == SafrOtaUnitState.done.name);
    final outcome = switch (run.outcome) {
      'done' => 'concluído',
      'partial' => 'parcial',
      'failed' => 'falhou',
      'cancelled' => 'cancelado',
      'stopped' => 'parado',
      _ => 'em andamento',
    };
    return '${two(at.day)}/${two(at.month)} ${two(at.hour)}:${two(at.minute)} · '
        '${run.allPhases ? 'Atualizar tudo' : run.families} · '
        '${vText(run.target)} · ${done.length} de ${units.length} · $outcome · '
        '${run.startedBy}';
  }
}

// ── The PIN ─────────────────────────────────────────────────────────────────

/// The Master or Nível 4 PIN before an action that starts something on the
/// units; null = the operator backed out. On the bench it is asked once per
/// app session (`otaPinOncePerSession`, before-production item 8).
Future<EditorRole?> ensureOtaPin(BuildContext context, WidgetRef ref) async {
  final granted = ref.read(otaPinGrantProvider);
  if (otaPinOncePerSession && granted != null) return granted;
  final role = await requestEditorRole(
    context,
    subtitle: 'Atualizar o firmware exige o PIN Master ou de Nível 4.',
  );
  if (role != null) ref.read(otaPinGrantProvider.notifier).state = role;
  return role;
}
