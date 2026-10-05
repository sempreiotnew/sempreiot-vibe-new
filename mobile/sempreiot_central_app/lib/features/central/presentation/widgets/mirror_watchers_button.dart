import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../../access/application/central_access_provider.dart';
import '../../../access/domain/entities/access_relation.dart';
import '../../application/central_mirror_publisher.dart';

/// The eye on the tablet's top bar: how many users' phones have this
/// central open right now. The central sends its live map to the cloud only
/// while that number is not zero (docs/cloud/central-mirror.md), so the eye
/// is also "is the map being sent": lit with the count = yes, crossed out =
/// no. A tap lists who.
class MirrorWatchersButton extends ConsumerWidget {
  const MirrorWatchersButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(mirrorWatchersProvider.select((w) => w.length));
    final watched = count > 0;
    final color = watched
        ? AppColors.secondary
        : context.textSecondary.withValues(alpha: 0.6);

    return Tooltip(
      message: watched
          ? (count == 1 ? '1 usuário assistindo' : '$count usuários assistindo')
          : 'Ninguém assistindo',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showWatchers(context),
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    watched
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_outlined,
                    color: color,
                    size: 19,
                  ),
                  if (watched) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$count',
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showWatchers(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      // Landscape tablet: little height, so the sheet scrolls and is capped.
      isScrollControlled: true,
      backgroundColor: context.surfaceColor,
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => UncontrolledProviderScope(
        container: ProviderScope.containerOf(context),
        child: const _WatchersSheet(),
      ),
    );
  }
}

class _WatchersSheet extends ConsumerWidget {
  const _WatchersSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchers = ref.watch(mirrorWatchersProvider);
    final relations = ref.watch(centralAccessRelationsProvider);
    AccessRelation? relationOf(MirrorWatcher w) {
      for (final r in relations) {
        if (r.userSubId == w.sub) return r;
      }
      return null;
    }

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: context.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(
                  watchers.isEmpty
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_rounded,
                  color: watchers.isEmpty
                      ? context.textSecondary
                      : AppColors.secondary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    watchers.isEmpty
                        ? 'Ninguém assistindo'
                        : watchers.length == 1
                            ? '1 usuário assistindo'
                            : '${watchers.length} usuários assistindo',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              watchers.isEmpty
                  ? 'O mapa ao vivo não está sendo enviado para a nuvem. '
                      'Ele só é enviado enquanto um usuário está com esta '
                      'central aberta no aplicativo. Os alarmes são enviados '
                      'sempre.'
                  : 'O mapa ao vivo está sendo enviado para a nuvem. O envio '
                      'para sozinho pouco mais de um minuto depois que o '
                      'último usuário fecha a central no aplicativo.',
              style: TextStyle(color: context.textSecondary, fontSize: 12.5),
            ),
            if (watchers.isNotEmpty) const SizedBox(height: 14),
            for (final w in watchers)
              _WatcherRow(watcher: w, relation: relationOf(w)),
          ],
        ),
      ),
    );
  }
}

class _WatcherRow extends StatelessWidget {
  const _WatcherRow({required this.watcher, required this.relation});

  final MirrorWatcher watcher;

  /// This user's row in Acessos; null = the id the phone reported is not
  /// in the central's access list (not synced yet, or not reported).
  final AccessRelation? relation;

  @override
  Widget build(BuildContext context) {
    final name = watcher.name ?? 'Usuário';
    final level = relation?.level;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.person_rounded,
                color: AppColors.secondary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (watcher.sub != null) ...[
                  const SizedBox(height: 2),
                  SelectableText(
                    watcher.sub!,
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  [
                    if (level != null) level.label,
                    'assistindo ${relativeTime(watcher.since)}',
                  ].join(' · '),
                  style:
                      TextStyle(color: context.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
