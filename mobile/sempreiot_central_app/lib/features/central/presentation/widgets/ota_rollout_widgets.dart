import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_rollout_report.dart';
import '../../application/ota_rollout_state.dart';
import '../../application/ota_rollout_words.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_product.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import 'firmware_update_widgets.dart';

// The rollout on the "Atualização de firmware" screen: what the board holds
// for a family, the form that sends it to the units, and — once it was sent
// — the header, the table and the buttons. These widgets draw an
// [OtaFamilyRollout]; nothing here decides anything about the rollout.

/// Below this width a row of the table stacks its two halves.
const _narrow = 520.0;

Color otaUnitStateColor(BuildContext context, SafrOtaUnitState s) =>
    switch (s) {
      SafrOtaUnitState.waiting => context.textSecondary,
      SafrOtaUnitState.done => AppColors.success,
      SafrOtaUnitState.failed => AppColors.error,
      SafrOtaUnitState.skipped => context.textSecondary,
      _ => AppColors.secondary,
    };

IconData otaUnitStateIcon(SafrOtaUnitState s) => switch (s) {
      SafrOtaUnitState.waiting => Icons.hourglass_empty_rounded,
      SafrOtaUnitState.offered => Icons.outbox_rounded,
      SafrOtaUnitState.downloading => Icons.download_rounded,
      SafrOtaUnitState.verifying => Icons.fact_check_outlined,
      SafrOtaUnitState.rebooting => Icons.restart_alt_rounded,
      SafrOtaUnitState.selfTest => Icons.health_and_safety_outlined,
      SafrOtaUnitState.done => Icons.check_circle_rounded,
      SafrOtaUnitState.failed => Icons.error_rounded,
      SafrOtaUnitState.skipped => Icons.remove_circle_outline_rounded,
    };

Color _headlineColor(BuildContext context, OtaFamilyRollout f) =>
    switch (f.state) {
      SafrOtaRolloutState.rolling => AppColors.secondary,
      SafrOtaRolloutState.paused => AppColors.warning,
      SafrOtaRolloutState.done => AppColors.success,
      SafrOtaRolloutState.partial => AppColors.warning,
      _ => context.textSecondary,
    };

/// What the operator chose in the form: the filter and the units the
/// tablet counts for it.
class OtaRolloutRequest {
  const OtaRolloutRequest({
    required this.family,
    required this.filter,
    required this.units,
    required this.filterText,
  });

  final SafrProductFamily family;
  final SafrOtaFilter filter;

  /// Online units the filter lets through, as the tablet's registry says.
  final List<TopologyNode> units;

  /// "todos os dispositivos", "produto Sirene (0x0201)", …
  final String filterText;
}

/// One family the board holds an image of: "Na placa: firmware de rede
/// elétrica 0.1.1", and under it either the form "Enviar aos dispositivos"
/// or the rollout that runs (or ran).
class OtaRolloutCard extends StatefulWidget {
  const OtaRolloutCard({
    super.key,
    required this.family,
    required this.version,
    required this.rollout,
    required this.candidates,
    required this.nodes,
    required this.now,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onAbort,
    this.rootMac,
    this.fromBoard = true,
    this.blocked,
    this.busy = false,
  });

  final SafrProductFamily family;

  /// The version the board holds.
  final String version;

  /// What the board said of this family; null = only this session's memory
  /// of a push is left.
  final OtaFamilyRollout? rollout;
  final OtaRolloutCandidates candidates;

  /// Every unit the tablet knows, by MAC: names and versions of the rows.
  final Map<String, TopologyNode> nodes;

  /// The unit that is the mesh root: updated last.
  final String? rootMac;

  /// The clock of the screen: it ticks every second while a rollout runs.
  final DateTime now;

  /// False: the board never answered GET_ROLLOUT; [version] is what this
  /// session saw stored.
  final bool fromBoard;

  /// Why nothing can be sent now (cable, alarm, another update); null =
  /// it can.
  final String? blocked;

  /// An OTA_CONTROL waits for its answer.
  final bool busy;

  final ValueChanged<OtaRolloutRequest> onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onAbort;

  @override
  State<OtaRolloutCard> createState() => _OtaRolloutCardState();
}

class _OtaRolloutCardState extends State<OtaRolloutCard> {
  SafrOtaFilterKind _kind = SafrOtaFilterKind.all;
  int? _product;
  String? _zone;
  String? _mac;

  /// The filter as chosen, with what is left of the choice when the units
  /// changed under it. Null = nothing to choose from.
  SafrOtaFilter? _filter() {
    final c = widget.candidates;
    switch (_kind) {
      case SafrOtaFilterKind.all:
        return const SafrOtaFilter.all();
      case SafrOtaFilterKind.product:
        final codes = [for (final p in c.products) p.code];
        if (codes.isEmpty) return null;
        return SafrOtaFilter.product(
            codes.contains(_product) ? _product! : codes.first);
      case SafrOtaFilterKind.zone:
        final zones = c.zones;
        if (zones.isEmpty) return null;
        return SafrOtaFilter.zone(zones.contains(_zone) ? _zone! : zones.first);
      case SafrOtaFilterKind.unit:
        final macs = [for (final n in c.units) n.mac];
        if (macs.isEmpty) return null;
        return SafrOtaFilter.unit(macs.contains(_mac) ? _mac! : macs.first);
    }
  }

  String _name(String mac) {
    final n = widget.nodes[mac];
    return n?.name?.isNotEmpty == true ? n!.name! : mac;
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.rollout;
    final shown = f != null && (f.running || f.ended);
    final isLeaf = widget.family == SafrProductFamily.leaf;

    return Container(
      key: ValueKey('ota-rollout-${widget.family.name}'),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Held(
            family: widget.family,
            version: widget.version,
            fromBoard: widget.fromBoard,
            nothingSent: f == null || f.state == SafrOtaRolloutState.staged,
          ),
          if (shown) ...[
            const SizedBox(height: 16),
            OtaRolloutHeader(rollout: f, now: widget.now),
            const SizedBox(height: 12),
            OtaRolloutTable(
              rollout: f,
              nodes: widget.nodes,
              rootMac: widget.rootMac,
            ),
            if (f.failures.isNotEmpty && f.ended) ...[
              const SizedBox(height: 14),
              OtaRolloutFailures(rollout: f, nameOf: _name),
            ],
          ],
          if (f != null && f.running) ...[
            const SizedBox(height: 14),
            _RunningActions(
              rollout: f,
              busy: widget.busy,
              onPause: widget.onPause,
              onResume: widget.onResume,
              onAbort: widget.onAbort,
            ),
            const SizedBox(height: 10),
            const _Note('Pode sair desta tela: a atualização continua e '
                'aparece na tela Rede.'),
          ] else if (isLeaf) ...[
            const SizedBox(height: 14),
            const _LeafNotYet(),
          ] else ...[
            const SizedBox(height: 16),
            _form(context, again: shown),
          ],
        ],
      ),
    );
  }

  Widget _form(BuildContext context, {required bool again}) {
    final c = widget.candidates;
    final filter = _filter();
    final passing = filter == null ? const <TopologyNode>[] : c.passing(filter);
    final reach = filter == null ? const <TopologyNode>[] : c.reachable(filter);
    final offline = passing.length - reach.length;
    final blocked = widget.blocked;
    final canSend =
        blocked == null && !widget.busy && filter != null && reach.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          again ? 'ENVIAR DE NOVO' : 'ENVIAR AOS DISPOSITIVOS',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (kind, label) in const [
              (SafrOtaFilterKind.all, 'Todos'),
              (SafrOtaFilterKind.product, 'Por produto'),
              (SafrOtaFilterKind.zone, 'Por zona'),
              (SafrOtaFilterKind.unit, 'Um dispositivo'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _kind == kind,
                onSelected: (_) => setState(() => _kind = kind),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        if (_kind != SafrOtaFilterKind.all) ...[
          const SizedBox(height: 10),
          _choice(context, filter),
        ],
        const SizedBox(height: 12),
        _FormSummary(
          family: widget.family,
          version: widget.version,
          reach: reach.length,
          offline: offline,
          unknownProduct: _kind == SafrOtaFilterKind.all
              ? c.unknownProduct.length
              : 0,
          atTarget:
              reach.where((n) => n.fwVersion == widget.version).length,
          nothingToChoose: filter == null,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: canSend
                ? () => widget.onStart(OtaRolloutRequest(
                      family: widget.family,
                      filter: filter,
                      units: reach,
                      filterText: otaFilterText(
                        filter,
                        unitName: filter.kind == SafrOtaFilterKind.unit
                            ? _name(filter.mac)
                            : null,
                      ),
                    ))
                : null,
            icon: widget.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded, size: 18),
            label: const Text('Enviar aos dispositivos'),
          ),
        ),
        if (blocked != null) ...[
          const SizedBox(height: 8),
          _Note(blocked, warning: true),
        ],
      ],
    );
  }

  /// The list the chosen kind of filter picks from.
  Widget _choice(BuildContext context, SafrOtaFilter? filter) {
    final c = widget.candidates;
    if (filter == null) {
      return _Note(switch (_kind) {
        SafrOtaFilterKind.product =>
          'Nenhum dispositivo informou o produto ainda.',
        SafrOtaFilterKind.zone => 'Nenhum dispositivo tem zona definida.',
        _ => 'Nenhum dispositivo deste tipo é conhecido.',
      });
    }
    switch (_kind) {
      case SafrOtaFilterKind.product:
        return _Dropdown<int>(
          label: 'Produto',
          value: filter.product,
          items: {
            for (final p in c.products)
              p.code: '${p.label} · ${c.passing(SafrOtaFilter.product(p.code)).length}',
          },
          onChanged: (v) => setState(() => _product = v),
        );
      case SafrOtaFilterKind.zone:
        return _Dropdown<String>(
          label: 'Zona',
          value: filter.zone,
          items: {
            for (final z in c.zones)
              z: '$z · ${c.passing(SafrOtaFilter.zone(z)).length}',
          },
          onChanged: (v) => setState(() => _zone = v),
        );
      case SafrOtaFilterKind.unit:
        return _Dropdown<String>(
          label: 'Dispositivo',
          value: filter.mac,
          items: {
            for (final n in c.units)
              n.mac: '${_name(n.mac)}${n.online ? '' : ' (sem comunicação)'}',
          },
          onChanged: (v) => setState(() => _mac = v),
        );
      case SafrOtaFilterKind.all:
        return const SizedBox.shrink();
    }
  }
}

class _Held extends StatelessWidget {
  const _Held({
    required this.family,
    required this.version,
    required this.fromBoard,
    required this.nothingSent,
  });

  final SafrProductFamily family;
  final String version;
  final bool fromBoard;
  final bool nothingSent;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.inventory_2_outlined,
              size: 20, color: context.textSecondary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Na placa: ${otaFirmwareWord(family)} $version',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              if (nothingSent || !fromBoard) ...[
                const SizedBox(height: 3),
                Text(
                  fromBoard
                      ? 'Guardado na placa. Nenhum dispositivo recebeu esta '
                          'versão ainda.'
                      : 'A placa não informou o que guarda: isto é o que '
                          'este tablet enviou a ela nesta sessão.',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _LeafNotYet extends StatelessWidget {
  const _LeafNotYet();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: null,
            child: Text('Enviar aos dispositivos'),
          ),
        ),
        SizedBox(height: 8),
        _Note(otaLeafNotYet),
      ],
    );
  }
}

class _FormSummary extends StatelessWidget {
  const _FormSummary({
    required this.family,
    required this.version,
    required this.reach,
    required this.offline,
    required this.unknownProduct,
    required this.atTarget,
    required this.nothingToChoose,
  });

  final SafrProductFamily family;
  final String version;
  final int reach;
  final int offline;
  final int unknownProduct;
  final int atTarget;
  final bool nothingToChoose;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (offline > 0)
        '$offline sem comunicação: ${offline == 1 ? 'não será atualizado' : 'não serão atualizados'}.',
      if (unknownProduct > 0)
        '$unknownProduct ${unknownProduct == 1 ? 'não informou o produto e não será atualizado' : 'não informaram o produto e não serão atualizados'}.',
      if (atTarget > 0)
        '$atTarget já ${atTarget == 1 ? 'está' : 'estão'} na versão $version.',
    ];
    final headline = nothingToChoose
        ? 'Nada a enviar com este filtro.'
        : reach == 0
            ? 'Nenhum dispositivo online para receber a versão $version.'
            : '$reach ${reach == 1 ? 'dispositivo receberá' : 'dispositivos receberão'} '
                'a versão $version, um de cada vez.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headline,
          key: const ValueKey('ota-rollout-count'),
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              l,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.warning = false});
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          warning ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
          size: 16,
          color: warning ? AppColors.warning : context.textSecondary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;

  /// Value → what is written.
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: false,
          dropdownColor: context.surfaceColor,
          style: TextStyle(color: context.textPrimary, fontSize: 14),
          items: [
            for (final e in items.entries)
              DropdownMenuItem<T>(
                value: e.key,
                child: Text(
                  e.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ── A rollout that runs or ran ───────────────────────────────────────────────

/// ENVIANDO / PAUSADO / CONCLUÍDO / PARCIAL, how many units are done, for
/// how long it runs.
class OtaRolloutHeader extends StatelessWidget {
  const OtaRolloutHeader({super.key, required this.rollout, required this.now});

  final OtaFamilyRollout rollout;
  final DateTime now;

  String? _elapsed() {
    final started = rollout.startedAt;
    if (started == null) return null;
    final end = rollout.ended ? rollout.endedAt : now;
    if (end == null) return null;
    final d = end.difference(started);
    final text = otaDurationText(d.isNegative ? Duration.zero : d);
    if (rollout.ended) return 'em $text';
    return rollout.startedAtExact ? 'há $text' : 'há pelo menos $text';
  }

  @override
  Widget build(BuildContext context) {
    final f = rollout;
    final color = _headlineColor(context, f);
    final total = f.unitCount;
    final elapsed = _elapsed();
    final counts = <String>[
      '${f.doneCount} de $total ${f.doneCount == 1 ? 'atualizado' : 'atualizados'}',
      if (f.skippedCount > 0)
        '${f.skippedCount} ${f.skippedCount == 1 ? 'ignorado' : 'ignorados'}',
      if (f.failedCount > 0) '${f.failedCount} com falha',
      if (elapsed != null) elapsed,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              key: const ValueKey('ota-rollout-headline'),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha: 0.6)),
              ),
              child: Text(
                otaRolloutHeadline(f),
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            Text(
              counts.join(' · '),
              key: const ValueKey('ota-rollout-counts'),
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : f.settledCount / total,
            minHeight: 6,
            backgroundColor: context.borderColor.withValues(alpha: 0.5),
            color: color,
          ),
        ),
        if (f.state == SafrOtaRolloutState.paused) ...[
          const SizedBox(height: 10),
          _Note(otaPauseHint(f.pauseCause), warning: true),
        ],
      ],
    );
  }
}

/// One row per unit, in the order of the board's table: name, product,
/// "versão agora → alvo", the state in words with the percent, the tries,
/// why it failed. The unit that is the mesh root is marked "por último".
class OtaRolloutTable extends StatelessWidget {
  const OtaRolloutTable({
    super.key,
    required this.rollout,
    required this.nodes,
    this.rootMac,
  });

  final OtaFamilyRollout rollout;
  final Map<String, TopologyNode> nodes;
  final String? rootMac;

  @override
  Widget build(BuildContext context) {
    final units = rollout.units;
    if (units.isEmpty) {
      return Text(
        'A placa ainda não enviou a lista dos dispositivos.',
        style: TextStyle(color: context.textSecondary, fontSize: 12.5),
      );
    }
    return Container(
      key: const ValueKey('ota-rollout-table'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < units.length; i++) ...[
            if (i > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                color: context.borderColor.withValues(alpha: 0.5),
              ),
            OtaRolloutRow(
              unit: units[i],
              node: nodes[units[i].mac],
              target: rollout.target,
              last: units[i].mac == rootMac &&
                  units[i].state == SafrOtaUnitState.waiting,
              isRoot: units[i].mac == rootMac,
            ),
          ],
        ],
      ),
    );
  }
}

class OtaRolloutRow extends StatelessWidget {
  const OtaRolloutRow({
    super.key,
    required this.unit,
    required this.target,
    this.node,
    this.last = false,
    this.isRoot = false,
  });

  final OtaRolloutUnit unit;
  final TopologyNode? node;
  final String target;

  /// The mesh root, still waiting: the board updates it after the others.
  final bool last;
  final bool isRoot;

  @override
  Widget build(BuildContext context) {
    final u = unit;
    final hasName = node?.name?.isNotEmpty == true;
    final name = hasName ? node!.name! : u.mac;
    final product = u.product?.label ?? node?.product?.label;
    final color = otaUnitStateColor(context, u.state);
    final attempts = otaAttemptsText(u);
    final why = u.reasonRaw == 0
        ? ''
        : otaUnitReasonText(u.reason, raw: u.reasonRaw);
    final downloading = u.state == SafrOtaUnitState.downloading;

    final who = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFamily: hasName ? null : 'monospace',
                ),
              ),
            ),
            if (isRoot) ...[
              const SizedBox(width: 6),
              _Tag(last ? 'ROOT · POR ÚLTIMO' : 'ROOT'),
            ],
          ],
        ),
        const SizedBox(height: 1),
        Text(
          product == null || product.isEmpty
              ? 'Produto não informado'
              : product,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.textSecondary, fontSize: 12),
        ),
      ],
    );

    final version = Text(
      otaVersionChangeText(u, target, known: node?.fwVersion),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: context.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    final state = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (u.state.active && !downloading)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        else
          Icon(otaUnitStateIcon(u.state), size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            last ? 'Aguardando · por último' : otaUnitStateText(u.state, u.percent),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );

    return Padding(
      key: ValueKey('ota-rollout-row-${u.mac}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < _narrow;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (narrow) ...[
                who,
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: version),
                    const SizedBox(width: 10),
                    Flexible(child: state),
                  ],
                ),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(flex: 5, child: who),
                    const SizedBox(width: 12),
                    Expanded(flex: 3, child: version),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: state,
                      ),
                    ),
                  ],
                ),
              if (downloading) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: u.percent / 100,
                    minHeight: 4,
                    backgroundColor:
                        context.borderColor.withValues(alpha: 0.5),
                    color: AppColors.secondary,
                  ),
                ),
              ],
              if (attempts != null || why.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  [
                    if (attempts != null) _capital(attempts),
                    if (why.isNotEmpty) why,
                  ].join(' · '),
                  style: TextStyle(
                    color: u.state == SafrOtaUnitState.failed
                        ? AppColors.error
                        : context.textSecondary,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _capital(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: const TextStyle(
          color: AppColors.warning,
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// The units that were not updated, together, at the end.
class OtaRolloutFailures extends StatelessWidget {
  const OtaRolloutFailures({
    super.key,
    required this.rollout,
    required this.nameOf,
  });

  final OtaFamilyRollout rollout;
  final String Function(String mac) nameOf;

  @override
  Widget build(BuildContext context) {
    final failures = rollout.failures;
    return Container(
      key: const ValueKey('ota-rollout-failures'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            AppColors.error.withValues(alpha: 0.07), context.surfaceColor),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            failures.length == 1
                ? 'NÃO FOI ATUALIZADO'
                : 'NÃO FORAM ATUALIZADOS · ${failures.length}',
            style: const TextStyle(
              color: AppColors.error,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
          for (final u in failures)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${nameOf(u.mac)}: '
                '${_orUnknown(otaUnitReasonText(u.reason, raw: u.reasonRaw))}'
                '${u.version.isEmpty ? '' : ' Continua na versão ${u.version}.'}',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Para tentar de novo, envie outra vez escolhendo "Um '
            'dispositivo".',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  static String _orUnknown(String reason) =>
      reason.isEmpty ? 'A placa não disse o motivo.' : reason;
}

class _RunningActions extends StatelessWidget {
  const _RunningActions({
    required this.rollout,
    required this.busy,
    required this.onPause,
    required this.onResume,
    required this.onAbort,
  });

  final OtaFamilyRollout rollout;
  final bool busy;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onAbort;

  @override
  Widget build(BuildContext context) {
    final paused = rollout.state == SafrOtaRolloutState.paused;
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      children: [
        if (paused)
          FilledButton.icon(
            onPressed: busy ? null : onResume,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Retomar'),
          )
        else
          OutlinedButton.icon(
            onPressed: busy ? null : onPause,
            icon: const Icon(Icons.pause_rounded, size: 18),
            label: const Text('Pausar'),
          ),
        OutlinedButton.icon(
          onPressed: busy ? null : onAbort,
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
          icon: const Icon(Icons.close_rounded, size: 18),
          label: const Text('Cancelar'),
        ),
      ],
    );
  }
}

/// What the "Guardado na placa" line of the link card says of a family.
String otaHeldLine(
  SafrProductFamily family,
  String version,
  OtaFamilyRollout? rollout,
) {
  final what = '${otaFirmwareShortName(family)} $version';
  return switch (rollout?.state) {
    null ||
    SafrOtaRolloutState.staged ||
    SafrOtaRolloutState.idle =>
      '$what · ainda não enviado aos dispositivos',
    SafrOtaRolloutState.rolling => '$what · sendo enviado aos dispositivos',
    SafrOtaRolloutState.paused => '$what · envio aos dispositivos pausado',
    SafrOtaRolloutState.done => '$what · enviado aos dispositivos',
    SafrOtaRolloutState.partial =>
      '$what · enviado a parte dos dispositivos',
  };
}
