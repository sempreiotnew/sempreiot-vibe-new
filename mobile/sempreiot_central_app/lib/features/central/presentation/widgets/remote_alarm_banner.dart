import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/central_mirror_codec.dart';
import '../../application/central_mirror_viewer.dart';
import 'device_state_tile.dart';

/// The alarms a viewed central holds, on the user's phone: the tablet's
/// alarm-hold banner (latched_alarm_banner.dart) without the reset — an
/// alarm is reset at the tablet, never from a phone.
///
/// Fed by the central's retained alarm list, so it is there when the app is
/// opened after the alarm started, and stays while the central is offline.
/// Renders nothing while no alarm is held.
class RemoteAlarmBanner extends ConsumerWidget {
  const RemoteAlarmBanner({super.key, required this.identityId});

  final String identityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alarms =
        ref.watch(centralAlarmsProvider(identityId))?.alarms ?? const [];
    if (alarms.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: context.isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.error.withValues(alpha: 0.55),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_fire_department_rounded,
                  color: AppColors.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  alarms.length == 1
                      ? 'ALARME RETIDO — 1 dispositivo'
                      : 'ALARME RETIDO — ${alarms.length} dispositivos',
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'O alarme fica retido até o rearme do operador, na central.',
            style: TextStyle(color: context.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final a in alarms) RemoteAlarmTile(alarm: a)],
          ),
        ],
      ),
    );
  }
}

/// One held alarm: the unit as Rede draws it, in alarm, and since when.
class RemoteAlarmTile extends StatelessWidget {
  const RemoteAlarmTile({super.key, required this.alarm});
  final MirrorAlarm alarm;

  @override
  Widget build(BuildContext context) {
    final since = alarm.since;
    return DeviceStateTile(
      mac: alarm.mac,
      described: DeviceStateTile.describe(
        mac: alarm.mac,
        name: alarm.name,
        address: alarm.address,
        productCode: alarm.productCode,
        leaf: alarm.leaf,
        alarm: true,
        alarmSince: since,
      ),
      accent: AppColors.error,
      status: Text(
        since == null ? 'em alarme' : 'em alarme · ${relativeTime(since)}',
        maxLines: 1,
        style: const TextStyle(
          color: AppColors.error,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "ALARME" on a central's card of the Centrais list while it holds one.
class CentralAlarmBadge extends ConsumerWidget {
  const CentralAlarmBadge({super.key, required this.identityId});

  final String identityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count =
        ref.watch(centralAlarmsProvider(identityId))?.alarms.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.error,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department_rounded,
              color: Colors.white, size: 13),
          const SizedBox(width: 4),
          Text(
            count == 1 ? 'ALARME' : 'ALARME · $count',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
