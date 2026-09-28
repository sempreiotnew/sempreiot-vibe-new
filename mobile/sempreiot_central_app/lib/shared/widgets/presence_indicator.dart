import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_ext.dart';
import '../../features/iot/application/presence_provider.dart';

/// Dot + label showing a central's live online/offline state. Used anywhere
/// a central's identityId is known — lookup results, saved-central cards,
/// the central status screen — backed by the same live MQTT subscription.
class PresenceIndicator extends ConsumerWidget {
  const PresenceIndicator({
    super.key,
    required this.identityId,
    this.dotSize = 7,
    this.fontSize = 11,
  });

  final String identityId;
  final double dotSize;
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(presenceStatusProvider(identityId));

    final color = switch (status) {
      PresenceStatus.unknown => context.textSecondary.withValues(alpha: 0.3),
      PresenceStatus.online => AppColors.success,
      PresenceStatus.offline => context.textSecondary.withValues(alpha: 0.5),
    };
    final label = switch (status) {
      PresenceStatus.unknown => 'Verificando…',
      PresenceStatus.online => 'Online',
      PresenceStatus.offline => 'Offline',
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        SizedBox(width: dotSize * 0.85),
        Text(
          label,
          style: TextStyle(
            color: status == PresenceStatus.unknown
                ? context.textSecondary.withValues(alpha: 0.7)
                : (status == PresenceStatus.online ? context.textPrimary : color),
            fontSize: fontSize,
            fontWeight: status == PresenceStatus.unknown ? FontWeight.w400 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
