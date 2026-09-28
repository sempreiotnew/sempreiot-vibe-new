import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/alarm_latch_provider.dart';
import '../../application/safr_downlink_provider.dart';

/// Alarm hold (SAFR v3 §7.1.4 — UL 864 / NFPA 72): every device whose alarm
/// is latched stays listed here, whatever the sensor reports afterwards,
/// until the operator presses REARMAR. Renders nothing while no alarm is
/// held. The reset is a broadcast; the central only clears its latches once
/// the root ACKs it.
class LatchedAlarmBanner extends ConsumerStatefulWidget {
  const LatchedAlarmBanner({super.key});

  @override
  ConsumerState<LatchedAlarmBanner> createState() => _LatchedAlarmBannerState();
}

class _LatchedAlarmBannerState extends ConsumerState<LatchedAlarmBanner> {
  bool _resetting = false;

  Future<void> _rearm() async {
    setState(() => _resetting = true);
    final ok = await ref.read(safrDownlinkProvider).sendReset(safrBroadcastMac);
    if (!mounted) return;
    setState(() => _resetting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Sistema rearmado — alarmes retidos liberados'
          : 'Rearme SEM confirmação do root — alarmes continuam retidos'),
      backgroundColor: ok ? null : AppColors.error,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final latched = ref.watch(latchedAlarmsProvider).valueOrNull ?? const [];
    if (latched.isEmpty) return const SizedBox.shrink();

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
                onPressed: _resetting ? null : _rearm,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                icon: _resetting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Rearmar'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'O alarme fica retido até o rearme do operador, mesmo que o '
            'sensor já tenha voltado ao normal.',
            style: TextStyle(color: context.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in latched) _LatchedDeviceChip(device: d),
            ],
          ),
        ],
      ),
    );
  }
}

class _LatchedDeviceChip extends StatelessWidget {
  const _LatchedDeviceChip({required this.device});
  final MeshDevice device;

  @override
  Widget build(BuildContext context) {
    final hasName = device.name?.isNotEmpty == true;
    final since = device.alarmLatchedAt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
          Text(
            hasName ? device.name! : device.mac,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              fontFamily: hasName ? null : 'monospace',
            ),
          ),
          if (since != null) ...[
            const SizedBox(width: 6),
            Text(
              relativeTime(since),
              style: TextStyle(color: context.textSecondary, fontSize: 10.5),
            ),
          ],
        ],
      ),
    );
  }
}
