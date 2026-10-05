import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../screens/network_3d_screen.dart';

// ── Status bar ───────────────────────────────────────────────────────────────

class MeshStatusBar extends StatelessWidget {
  const MeshStatusBar({
    super.key,
    required this.nodes,
    required this.election,
    this.onClear,
    this.show3d,
    this.leading = const [],
  });
  final List<TopologyNode> nodes;
  final RootElectionState election;

  /// "Limpar dispositivos" lives here, not floating over the canvas, so it
  /// can never collide with the zoom controls on a short landscape screen.
  /// Null: no clear button — and no 3D button either, unless [show3d].
  final VoidCallback? onClear;

  /// The 3D button; null = shown with the clear button. True with no
  /// [onClear]: a user's phone viewing a central — it may look, not clear.
  final bool? show3d;

  /// Pills ahead of the counts (an update in progress, say).
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    final online = nodes.where((n) => n.online && !n.sleeping).length;
    final sleeping = nodes.where((n) => n.sleeping).length;
    final offline = nodes.where((n) => !n.online).length;
    DateTime? lastSeen;
    for (final n in nodes) {
      if (lastSeen == null || n.lastSeenAt.isAfter(lastSeen)) {
        lastSeen = n.lastSeenAt;
      }
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          // One line always: on a narrow phone the counts scale down a
          // little instead of wrapping and doubling the strip's height.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final pill in leading) ...[
                    pill,
                    const SizedBox(width: 14),
                  ],
                  if (election.electing) ...[
                    _ElectionPill(election: election),
                    const SizedBox(width: 14),
                  ],
                  _StatusCount(
                      color: AppColors.success, label: 'ATIVOS', count: online),
                  const SizedBox(width: 14),
                  _StatusCount(
                      color: context.textSecondary,
                      label: 'DORMINDO',
                      count: sleeping),
                  const SizedBox(width: 14),
                  _StatusCount(
                      color: AppColors.error, label: 'OFFLINE', count: offline),
                ],
              ),
            ),
          ),
          if (lastSeen != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  relativeTime(lastSeen),
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'ÚLTIMO QUADRO',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 7.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          if (show3d ?? onClear != null) ...[
            const SizedBox(width: 10),
            // PROTOTYPE: the same network as a 3D cloud (network_3d_screen).
            IconButton(
              tooltip: 'Ver em 3D (protótipo)',
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                fixedSize: const Size(30, 30),
                minimumSize: const Size(30, 30),
                padding: EdgeInsets.zero,
                foregroundColor: AppColors.secondary,
              ),
              icon: const Icon(Icons.view_in_ar_rounded, size: 20),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const Network3dScreen()),
              ),
            ),
          ],
          if (onClear != null) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Ressincronizar com a placa',
              // M3 pads the tap target to 48 px, which alone made the strip
              // two lines tall; the strip stays one compact line.
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                fixedSize: const Size(30, 30),
                minimumSize: const Size(30, 30),
                padding: EdgeInsets.zero,
                foregroundColor: AppColors.error,
              ),
              icon: const Icon(Icons.delete_sweep_rounded, size: 20),
              onPressed: onClear,
            ),
          ],
        ],
      ),
    );
  }
}

/// "The mesh is choosing its root": shown while several units claim level 1
/// or the root was just lost, with the elapsed time so the operator sees it
/// is transient — and as a trouble once it has run past what a failover is
/// allowed to take (root_election_provider).
class _ElectionPill extends StatelessWidget {
  const _ElectionPill({required this.election});
  final RootElectionState election;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final overdue = election.overdue(now);
    final color = overdue ? AppColors.error : AppColors.warning;
    final secs = election.elapsed(now).inSeconds;
    final label = overdue ? 'SEM ROOT' : 'REORGANIZANDO';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            '$label · ${secs}s',
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

class _StatusCount extends StatelessWidget {
  const _StatusCount({
    required this.color,
    required this.label,
    required this.count,
  });

  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: count > 0 ? color : color.withValues(alpha: 0.3),
            shape: BoxShape.circle,
            boxShadow: count > 0
                ? [
                    BoxShadow(
                        color: color.withValues(alpha: 0.5), blurRadius: 5)
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}
