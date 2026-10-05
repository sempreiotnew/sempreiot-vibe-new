import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/central_mirror_viewer.dart';

/// On a user's phone, above the Dispositivos and Rede screens of a viewed
/// central: says so whenever the picture below is not live — never stale
/// data shown as live. Renders nothing while it is live.
class MirrorStatusStrip extends ConsumerWidget {
  const MirrorStatusStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(centralMirrorProvider);
    if (view.live) return const SizedBox.shrink();

    final at = view.snapshotAt;
    final (IconData icon, Color color, String text) = !view.connected
        ? (
            Icons.cloud_off_rounded,
            AppColors.warning,
            'Sem conexão com a nuvem — sem dados ao vivo',
          )
        : !view.centralOnline
            ? (
                Icons.sensors_off_rounded,
                AppColors.error,
                at == null
                    ? 'Central sem conexão — sem dados ao vivo'
                    : 'Central sem conexão — última imagem '
                        '${relativeTime(at)}',
              )
            : (
                Icons.sync_rounded,
                context.textSecondary,
                'Conectando à central…',
              );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.7),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
