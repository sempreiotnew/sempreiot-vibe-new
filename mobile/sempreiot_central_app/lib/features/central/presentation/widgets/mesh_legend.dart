import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/topology_provider.dart';

/// What a unit's dot says on the radial Rede map (2026-10-15): one colour
/// per state, the loud ones first. The LED on the dot is the unit's LED
/// and keeps the LED language; the dot's fill is the app's reading of
/// the unit, the same the strip counts and the popover says.
enum RadialStatus {
  alarm('Alarme'),
  offline('Offline'),
  warning('Atenção'),
  sleeping('Dormindo'),
  online('Ativo');

  const RadialStatus(this.label);
  final String label;
}

RadialStatus radialStatusOf(TopologyNode n) {
  if (!n.online) return RadialStatus.offline;
  if (n.alarmLatched) return RadialStatus.alarm;
  // A weak bound link or a low battery: the unit works, someone should
  // look (walk test §12.7, battery as the sheet shows it).
  if (n.weakLink || (n.batteryPct != null && n.batteryPct! < 20)) {
    return RadialStatus.warning;
  }
  if (n.sleeping) return RadialStatus.sleeping;
  return RadialStatus.online;
}

Color radialStatusColor(RadialStatus s, {required bool isDark}) => switch (s) {
      RadialStatus.alarm => AppColors.error,
      RadialStatus.offline => AppColors.error,
      RadialStatus.warning => AppColors.warning,
      RadialStatus.sleeping => sleepingLinkColor(isDark),
      RadialStatus.online => AppColors.success,
    };

/// The big picture in numbers, at the bottom left of the map (the tree
/// and the radial picture alike): how many units, and how many in each
/// state with its share — "is everything fine?" answered without opening
/// anything. Units the tablet never heard are counted apart (aguardando),
/// as the strip does.
class MeshLegend extends StatelessWidget {
  const MeshLegend({super.key, required this.nodes});

  final List<TopologyNode> nodes;

  static const legendKey = ValueKey('rede-radial-legend');

  @override
  Widget build(BuildContext context) {
    final placed = nodes.where((n) => !n.awaitingSignal).toList();
    final awaiting = nodes.length - placed.length;
    final counts = <RadialStatus, int>{};
    for (final n in placed) {
      counts.update(radialStatusOf(n), (c) => c + 1, ifAbsent: () => 1);
    }
    final total = placed.length;
    String pct(int c) => total == 0 ? '' : ' · ${(c * 100 / total).round()} %';

    final rows = <Widget>[
      for (final s in RadialStatus.values)
        if ((counts[s] ?? 0) > 0 || s == RadialStatus.online)
          _Row(
            color: radialStatusColor(s, isDark: context.isDark),
            hollow: s == RadialStatus.offline,
            text: '${counts[s] ?? 0} ${s.label.toLowerCase()}'
                '${pct(counts[s] ?? 0)}',
          ),
      if (awaiting > 0)
        _Row(
          color: AppColors.secondary,
          hollow: true,
          text: '$awaiting aguardando sinal',
        ),
    ];

    return Semantics(
      label: '$total dispositivos. ${[
        for (final s in RadialStatus.values)
          if ((counts[s] ?? 0) > 0) '${counts[s]} ${s.label}',
      ].join(', ')}',
      excludeSemantics: true,
      child: Container(
        key: legendKey,
        padding: const EdgeInsets.fromLTRB(10, 7, 12, 8),
        decoration: BoxDecoration(
          color: context.surfaceColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$total ${total == 1 ? 'DISPOSITIVO' : 'DISPOSITIVOS'}',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
            ...rows,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.color, required this.text, this.hollow = false});
  final Color color;
  final String text;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hollow ? null : color,
              border: Border.all(color: color, width: hollow ? 1.6 : 0),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
