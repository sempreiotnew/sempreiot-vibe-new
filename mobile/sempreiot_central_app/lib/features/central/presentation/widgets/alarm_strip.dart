import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/alarm_latch_provider.dart';
import '../../application/central_mirror_viewer.dart';

/// An alarm is never one tab away (2026-11-19): while the central holds
/// one, Dispositivos and Rede wear this one-line red strip on top — how
/// many devices, which ones — and a tap goes to Principal, where the
/// alarm is listed and rearmed. Renders nothing while no alarm is held.
///
/// On the tablet ([centralId] null) it reads its own latches; on a user's
/// phone, the viewed central's retained alarm list.
class AlarmStrip extends ConsumerWidget {
  const AlarmStrip({super.key, this.centralId, required this.onOpen});

  final String? centralId;

  /// Opens Principal.
  final VoidCallback onOpen;

  static const keyStrip = ValueKey('alarm-strip');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<String> names;
    if (centralId == null) {
      names = [
        for (final d
            in ref.watch(latchedAlarmsProvider).valueOrNull ?? const [])
          d.name?.isNotEmpty == true ? d.name! : d.mac,
      ];
    } else {
      names = [
        for (final a
            in ref.watch(centralAlarmsProvider(centralId!))?.alarms ?? const [])
          a.name?.isNotEmpty == true ? a.name! : a.mac,
      ];
    }
    if (names.isEmpty) return const SizedBox.shrink();

    final dark = context.isDark;
    final ink = dark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
    return Material(
      key: keyStrip,
      color: Color.alphaBlend(
          AppColors.error.withValues(alpha: dark ? 0.22 : 0.10),
          context.bgColor),
      child: InkWell(
        onTap: onOpen,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.error)),
          ),
          // Wide: how many and which. Narrow (a phone): how many — the
          // names are on Principal, one tap away.
          child: LayoutBuilder(builder: (context, c) {
            final title = Text(
              names.length == 1
                  ? 'ALARME — 1 dispositivo'
                  : 'ALARME — ${names.length} dispositivos',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink,
                fontSize: 13.5,
                fontWeight: FontWeight.w900,
              ),
            );
            final wide = c.maxWidth >= 560;
            return Row(
              children: [
                Icon(Icons.local_fire_department_rounded, color: ink, size: 20),
                const SizedBox(width: 10),
                if (wide) ...[
                  title,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      names.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: context.textPrimary, fontSize: 13),
                    ),
                  ),
                ] else
                  Expanded(child: title),
                const SizedBox(width: 8),
                Text(
                  'Ver',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: context.textPrimary, size: 20),
              ],
            );
          }),
        ),
      ),
    );
  }
}
