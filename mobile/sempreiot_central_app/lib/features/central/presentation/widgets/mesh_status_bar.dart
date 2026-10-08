import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../screens/network_3d_screen.dart';
import 'device_avatar.dart';

// ── Status bar ───────────────────────────────────────────────────────────────

class MeshStatusBar extends StatelessWidget {
  const MeshStatusBar({
    super.key,
    required this.nodes,
    required this.election,
    this.onSync,
    this.syncing = false,
    this.show3d,
    this.leading = const [],
    this.electionPill = true,
  });
  final List<TopologyNode> nodes;
  final RootElectionState election;

  /// "Sincronizar com a placa" lives here, not floating over the canvas, so
  /// it can never collide with the zoom controls on a short landscape
  /// screen. Null: no sync button — and no 3D button either, unless
  /// [show3d].
  final VoidCallback? onSync;

  /// A sync is running: the icon turns.
  final bool syncing;

  /// The 3D button; null = shown with the sync button. True with no
  /// [onSync]: a user's phone viewing a central — it may look, not sync.
  final bool? show3d;

  /// Pills ahead of the counts (an update in progress, say).
  final List<Widget> leading;

  /// "REORGANIZANDO" in the strip; Rede shows the election as its own
  /// banner under the strip instead (root_election_banner.dart).
  final bool electionPill;

  @override
  Widget build(BuildContext context) {
    // A unit the tablet never heard is no "offline" unit: it waits for its
    // first frame (aguardando), and is not in the tree yet.
    final placed = nodes.where((n) => !n.awaitingSignal);
    final awaiting = nodes.where((n) => n.awaitingSignal).toList();
    final online = placed.where((n) => n.online && !n.sleeping).length;
    final sleeping = placed.where((n) => n.sleeping).length;
    final offline = placed.where((n) => !n.online).length;
    DateTime? lastSeen;
    for (final n in placed) {
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
                  if (electionPill && election.electing) ...[
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
                  if (awaiting.isNotEmpty) ...[
                    const SizedBox(width: 14),
                    Tooltip(
                      message: 'Conhecidos pela placa, ainda sem sinal neste '
                          'tablet',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _showAwaiting(context, awaiting),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 2),
                          child: _StatusCount(
                            color: AppColors.secondary,
                            label: 'AGUARDANDO',
                            count: awaiting.length,
                          ),
                        ),
                      ),
                    ),
                  ],
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
          if (show3d ?? onSync != null) ...[
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
          if (onSync != null) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Sincronizar com a placa',
              // M3 pads the tap target to 48 px, which alone made the strip
              // two lines tall; the strip stays one compact line.
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                fixedSize: const Size(30, 30),
                minimumSize: const Size(30, 30),
                padding: EdgeInsets.zero,
                foregroundColor: AppColors.secondary,
                // Turning while it runs: keep the colour, not a grey look.
                disabledForegroundColor: AppColors.secondary,
              ),
              icon: _SyncIcon(spinning: syncing),
              onPressed: syncing ? null : onSync,
            ),
          ],
        ],
      ),
    );
  }

  /// Who the board knows and this tablet has not heard yet, and why.
  void _showAwaiting(BuildContext context, List<TopologyNode> awaiting) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon:
            const Icon(Icons.hourglass_top_rounded, color: AppColors.secondary),
        title: const Text('Aguardando o primeiro sinal'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
            maxWidth: 420,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'A placa conhece estes dispositivos, mas este tablet ainda '
                  'não recebeu nenhum sinal deles. Cada um entra no mapa com '
                  'o primeiro sinal: os alimentados em até 15 s, os '
                  'detectores a bateria quando acordarem (até 1 min).',
                ),
                const SizedBox(height: 12),
                for (final n in awaiting)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          n.isLeaf
                              ? Icons.sensors_rounded
                              : Icons.router_outlined,
                          size: 16,
                          color: ctx.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            deviceDisplayName(n),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendi'),
          ),
        ],
      ),
    );
  }
}

/// The sync icon; it turns while the board sends its table.
class _SyncIcon extends StatefulWidget {
  const _SyncIcon({required this.spinning});
  final bool spinning;

  @override
  State<_SyncIcon> createState() => _SyncIconState();
}

class _SyncIconState extends State<_SyncIcon>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _c.repeat();
  }

  @override
  void didUpdateWidget(_SyncIcon old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.spinning && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        turns: _c,
        child: const Icon(Icons.sync_rounded, size: 20),
      );
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
