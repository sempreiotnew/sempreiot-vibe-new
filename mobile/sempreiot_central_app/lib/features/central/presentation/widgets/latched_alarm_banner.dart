import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/alarm_latch_provider.dart';
import '../../application/device_command_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart' show SafrNodeRole;
import 'device_command_widgets.dart';
import 'device_state_tile.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              const RearmAllButton(),
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
            spacing: 8,
            runSpacing: 8,
            children: [for (final d in latched) LatchedDeviceTile(device: d)],
          ),
        ],
      ),
    );
  }
}

/// The RESET of [status] is still on its way to the unit.
bool _rearming(DeviceCommandStatus? status) =>
    status != null &&
    status.kind == DeviceCommandKind.reset &&
    (status.step == DeviceCommandStep.sending ||
        status.step == DeviceCommandStep.boardAck);

/// A unit busy with any command takes no other meanwhile.
bool _busy(Map<String, DeviceCommandStatus> commands, String mac) =>
    _rearming(commands[mac]) || commands[mac]?.inFlight == true;

void _rearm(WidgetRef ref, String mac) {
  final node =
      ref.read(topologyProvider).where((n) => n.mac == mac).firstOrNull;
  ref.read(deviceCommandProvider.notifier).run(
        mac,
        DeviceCommandKind.reset,
        waitsForWake: node?.sleeping ?? false,
      );
}

const _rearmText = TextStyle(fontSize: 13, fontWeight: FontWeight.w800);

/// What Rearmar looks like, on a device and for all of them: the app's
/// action colour, filled — never the alarm's red, so the button is not
/// taken for one more "em alarme" (2026-11-23).
ButtonStyle rearmButtonStyle(BuildContext context) => FilledButton.styleFrom(
      backgroundColor: AppColors.secondary,
      foregroundColor: Colors.white,
      disabledBackgroundColor: AppColors.secondary.withValues(alpha: 0.25),
      disabledForegroundColor: Colors.white.withValues(alpha: 0.6),
      minimumSize: const Size(44, 44),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );

/// **Rearmar tudo**: one RESET to each device in alarm that is not already
/// taking a command — never a command to the units that are not in alarm.
/// [tall]: a narrow button as tall as the device tiles, for the end of
/// their row.
class RearmAllButton extends ConsumerWidget {
  const RearmAllButton({super.key, this.tall = false});

  final bool tall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latched = ref.watch(latchedAlarmsProvider).valueOrNull ?? const [];
    final commands = ref.watch(deviceCommandProvider);
    final free = [
      for (final d in latched)
        if (!_busy(commands, d.mac)) d.mac
    ];
    void all() {
      for (final mac in free) {
        _rearm(ref, mac);
      }
    }

    final onPressed = free.isEmpty ? null : all;
    if (!tall) {
      return FilledButton.icon(
        key: LatchedAlarmBanner.keyRearmAll,
        onPressed: onPressed,
        style: rearmButtonStyle(context),
        icon: const Icon(Icons.restart_alt_rounded, size: 18),
        label: const Text('Rearmar tudo', style: _rearmText),
      );
    }
    return FilledButton(
      key: LatchedAlarmBanner.keyRearmAll,
      onPressed: onPressed,
      style: rearmButtonStyle(context).copyWith(
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.restart_alt_rounded, size: 26),
          SizedBox(height: 6),
          Text('Rearmar\ntudo', textAlign: TextAlign.center, style: _rearmText),
        ],
      ),
    );
  }
}

/// One held alarm: the unit as Rede draws it, in alarm, since when, the
/// ticks of its RESET while one is on its way (or just ended), and its own
/// **Rearmar** — filled, in the app's action colour.
class LatchedDeviceTile extends ConsumerWidget {
  const LatchedDeviceTile({super.key, required this.device});

  final MeshDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commands = ref.watch(deviceCommandProvider);
    final s = commands[device.mac]?.kind == DeviceCommandKind.reset
        ? commands[device.mac]
        : null;
    final busy = _busy(commands, device.mac);
    final since = device.alarmLatchedAt;
    return DeviceStateTile(
      mac: device.mac,
      described: DeviceStateTile.describe(
        mac: device.mac,
        name: device.name,
        productCode: device.productCode,
        leaf: device.role == SafrNodeRole.leaf.wire,
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
      action: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            if (s != null) ...[
              CommandTicks(status: s, size: 16),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: FilledButton.icon(
                key: ValueKey('alarm-rearm-${device.mac}'),
                onPressed: busy ? null : () => _rearm(ref, device.mac),
                style: rearmButtonStyle(context),
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Rearmar', style: _rearmText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
