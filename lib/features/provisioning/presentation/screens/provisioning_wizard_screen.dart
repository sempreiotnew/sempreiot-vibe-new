import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/provisioning_wizard_provider.dart';
import '../../domain/entities/provisioning_step.dart';
import '../widgets/confirm_step.dart';
import '../widgets/connect_wifi_step.dart';
import '../widgets/identify_steps.dart';
import '../widgets/name_zone_step.dart';
import '../widgets/provisioning_progress_step.dart';
import '../widgets/result_step.dart';
import '../widgets/scan_step.dart';

/// Step-by-step wizard that provisions a new device into [installationId]
/// (POC-BRIEF.md §6.2). USER mode only; pushed from an installation screen.
class ProvisioningWizardScreen extends ConsumerWidget {
  const ProvisioningWizardScreen({super.key, required this.installationId});

  final String installationId;

  static const _phases = [
    'Identificação',
    'Dados',
    'Conexão',
    'Configuração',
    'Conclusão',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = provisioningWizardProvider(installationId);
    final step = ref.watch(provider.select((s) => s.step));

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.barColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: const Text(
          'Configurar Dispositivo',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                _PhaseIndicator(
                  phases: _phases,
                  current: step.phaseIndex,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.05, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(step),
                        child: _stepWidget(step),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepWidget(ProvisioningStep step) => switch (step) {
        ProvisioningStep.scan => ScanStep(installationId: installationId),
        ProvisioningStep.nameZone =>
          NameZoneStep(installationId: installationId),
        ProvisioningStep.connecting =>
          ConnectingStep(installationId: installationId),
        ProvisioningStep.identifying =>
          IdentifyingStep(installationId: installationId),
        ProvisioningStep.identifyFailed =>
          IdentifyFailedStep(installationId: installationId),
        ProvisioningStep.confirm => ConfirmStep(installationId: installationId),
        ProvisioningStep.provisioning =>
          ProvisioningProgressStep(installationId: installationId),
        _ => ResultStep(installationId: installationId, step: step),
      };
}

/// Slim segmented progress header: one segment per wizard phase.
class _PhaseIndicator extends StatelessWidget {
  const _PhaseIndicator({required this.phases, required this.current});

  final List<String> phases;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < phases.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    height: 4,
                    decoration: BoxDecoration(
                      color: i <= current
                          ? AppColors.secondary
                          : context.borderColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Etapa ${current + 1} de ${phases.length} — ${phases[current]}',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}
