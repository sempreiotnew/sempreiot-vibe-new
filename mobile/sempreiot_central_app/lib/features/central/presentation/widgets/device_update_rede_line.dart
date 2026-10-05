import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/device_update_controller.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_rollout_report.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../screens/device_update_screen.dart';

/// The only trace of a firmware update on the Rede screens (map and 3D):
/// one quiet line saying that one runs, and the way to "Atualizar
/// dispositivos" where it is shown. Rede is the alarm view: no ring, no
/// percent, no phase here. A unit that restarts into its new firmware still
/// reads "Atualizando" on the map (supervision, not a drawing of the
/// update). Takes no room when nothing runs.
class DeviceUpdateRedeLine extends ConsumerWidget {
  const DeviceUpdateRedeLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(deviceUpdateRunProvider);
    final pushing = ref.watch(otaPushViewProvider.select((s) => s.running));
    final rolling =
        ref.watch(otaRolloutViewProvider.select((s) => s.running)) != null;

    final String text;
    if (run != null && run.running) {
      final done = run.count(SafrOtaUnitState.done);
      text = 'Atualização de firmware em andamento · $done de '
          '${run.units.length}';
    } else if (pushing) {
      text = 'Enviando firmware à placa';
    } else if (rolling) {
      text = 'A placa está atualizando dispositivos';
    } else {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        key: const ValueKey('device-update-rede-line'),
        color: context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: context.borderColor.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DeviceUpdateScreen()),
          ),
          child: Semantics(
            button: true,
            label: '$text. Abrir Atualizar dispositivos',
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(Icons.system_update_rounded,
                        size: 16, color: context.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: context.textSecondary, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Abrir',
                      style: TextStyle(
                        color: AppColors.secondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
