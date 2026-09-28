import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/provisioning_wizard_provider.dart';
import '../../domain/entities/provisioning_step.dart';
import 'wizard_buttons.dart';

/// Final step — one of the three provisioning outcomes (POC-BRIEF.md §5:
/// `stored` / `online` / `failed`). There is deliberately no "assumed
/// success" variant: every outcome shown here came from a `/status` reply
/// the device itself sent (see `provisioning_wizard_provider.dart`).
///
/// The outcome is passed in (not watched) so the widget keeps its variant
/// while animating out after restart() resets the wizard to the scan step.
class ResultStep extends ConsumerWidget {
  const ResultStep({super.key, required this.installationId, required this.step});

  final String installationId;
  final ProvisioningStep step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier =
        ref.read(provisioningWizardProvider(installationId).notifier);
    final warning = ref.watch(
        provisioningWizardProvider(installationId).select((s) => s.warning));
    final visual = _VisualFor(step);

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: visual.color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(visual.icon, size: 46, color: visual.color),
            ),
            const SizedBox(height: 24),
            Text(
              visual.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                visual.message,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textSecondary, fontSize: 13),
              ),
            ),
            if (warning != null && step != ProvisioningStep.resultFailed) ...[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        color: AppColors.warning, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(warning,
                          style: TextStyle(
                              color: context.textPrimary, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 36),
            if (step == ProvisioningStep.resultFailed) ...[
              WizardPrimaryButton(
                label: 'Tentar novamente',
                icon: Icons.refresh_rounded,
                onTap: notifier.retryProvision,
              ),
              const SizedBox(height: 12),
            ],
            WizardSecondaryButton(
              label: 'Configurar outro dispositivo',
              icon: Icons.add_rounded,
              onTap: notifier.restart,
            ),
            const SizedBox(height: 12),
            WizardPrimaryButton(
              label: 'Concluir',
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _VisualFor {
  factory _VisualFor(ProvisioningStep step) => switch (step) {
        ProvisioningStep.resultOnline => const _VisualFor._(
            icon: Icons.check_circle_rounded,
            color: AppColors.success,
            title: 'Dispositivo conectado!',
            message: 'O dispositivo entrou na rede mesh da instalação '
                'e já está operando.',
          ),
        ProvisioningStep.resultStored => const _VisualFor._(
            icon: Icons.save_rounded,
            color: AppColors.secondary,
            title: 'Configuração salva',
            message: 'O dispositivo guardou a configuração e se conectará '
                'automaticamente quando a rede da instalação estiver ativa.',
          ),
        _ => const _VisualFor._(
            icon: Icons.error_rounded,
            color: AppColors.error,
            title: 'Falha na conexão',
            message: 'Não foi possível confirmar que o dispositivo salvou '
                'a configuração. Verifique se ele ainda está na rede de '
                'configuração e tente novamente.',
          ),
      };

  const _VisualFor._({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
}
