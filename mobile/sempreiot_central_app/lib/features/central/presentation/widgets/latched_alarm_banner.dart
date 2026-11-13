import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/alarm_latch_provider.dart';
import '../../application/device_command_provider.dart';
import '../../application/topology_provider.dart';
import 'device_command_widgets.dart';

/// Alarm hold (SAFR v3 §7.1.4 — UL 864 / NFPA 72): every device whose alarm
/// is latched stays listed here, whatever the sensor reports afterwards,
/// until the operator rearms it. Renders nothing while no alarm is held.
///
/// Each device has its own **Rearmar**; **Rearmar tudo** does the same for
/// every device listed — one RESET to each, never a command to the units
/// that are not in alarm. A device leaves the list when it confirms the
/// RESET itself (a unit out of communication: when the board takes it).
/// The answer shows as ticks beside the device — and under it on the Rede
/// map (device_command_provider.dart) — never as a snackbar.
class LatchedAlarmBanner extends ConsumerWidget {
  const LatchedAlarmBanner({super.key});

  static const keyRearmAll = ValueKey('alarm-rearm-all');

  /// The RESET of [status] is still on its way to the unit.
  static bool _rearming(DeviceCommandStatus? status) =>
      status != null &&
      status.kind == DeviceCommandKind.reset &&
      (status.step == DeviceCommandStep.sending ||
          status.step == DeviceCommandStep.boardAck);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latched = ref.watch(latchedAlarmsProvider).valueOrNull ?? const [];
    if (latched.isEmpty) return const SizedBox.shrink();
    final commands = ref.watch(deviceCommandProvider);

    // A unit busy with any command takes no other meanwhile.
    bool busy(String mac) =>
        _rearming(commands[mac]) || commands[mac]?.inFlight == true;

    void rearm(String mac) {
      final node =
          ref.read(topologyProvider).where((n) => n.mac == mac).firstOrNull;
      ref.read(deviceCommandProvider.notifier).run(
            mac,
            DeviceCommandKind.reset,
            waitsForWake: node?.sleeping ?? false,
          );
    }

    final free = [
      for (final d in latched)
        if (!busy(d.mac)) d.mac
    ];

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
                  latched.length == 1
                      ? 'ALARME RETIDO — 1 dispositivo'
                      : 'ALARME RETIDO — ${latched.length} dispositivos',
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              FilledButton.icon(
                key: keyRearmAll,
                onPressed: free.isEmpty ? null : () => free.forEach(rearm),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Rearmar tudo'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'O alarme fica retido até o rearme do operador, mesmo que o '
            'sensor já tenha voltado ao normal. Cada dispositivo sai da '
            'lista quando confirma o rearme.',
            style: TextStyle(color: context.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in latched)
                _LatchedDeviceChip(
                  device: d,
                  status: commands[d.mac]?.kind == DeviceCommandKind.reset
                      ? commands[d.mac]
                      : null,
                  onRearm: busy(d.mac) ? null : () => rearm(d.mac),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One held alarm: the device, since when, the ticks of its RESET while
/// one is on its way (or just ended), and its own Rearmar.
class _LatchedDeviceChip extends StatelessWidget {
  const _LatchedDeviceChip({
    required this.device,
    required this.status,
    required this.onRearm,
  });
  final MeshDevice device;

  /// This device's RESET, as the command tracker has it.
  final DeviceCommandStatus? status;

  /// Null while a command to it is on its way.
  final VoidCallback? onRearm;

  @override
  Widget build(BuildContext context) {
    final hasName = device.name?.isNotEmpty == true;
    final since = device.alarmLatchedAt;
    final s = status;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.error.withValues(alpha: 0.4),
          width: 0.7,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              hasName ? device.name! : device.mac,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                fontFamily: hasName ? null : 'monospace',
              ),
            ),
          ),
          if (since != null) ...[
            const SizedBox(width: 6),
            Text(
              relativeTime(since),
              style: TextStyle(color: context.textSecondary, fontSize: 10.5),
            ),
          ],
          if (s != null) ...[
            const SizedBox(width: 8),
            CommandTicks(status: s, size: 16),
          ],
          const SizedBox(width: 4),
          TextButton.icon(
            key: ValueKey('alarm-rearm-${device.mac}'),
            onPressed: onRearm,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.error,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.restart_alt_rounded, size: 16),
            label: const Text(
              'Rearmar',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
