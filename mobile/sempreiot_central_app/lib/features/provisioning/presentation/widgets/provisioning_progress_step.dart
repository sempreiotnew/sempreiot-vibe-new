import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../central/domain/led/led_language.dart';
import '../../application/provisioning_wizard_provider.dart';
import 'setup_device_preview.dart';

/// Step 6 (in flight) — POST /provision sent, polling /status for the
/// outcome (POC-BRIEF.md §5/§6.2). The unit still blinks white: its LED
/// changes only when it reboots with the code stored.
class ProvisioningProgressStep extends ConsumerWidget {
  const ProvisioningProgressStep({super.key, required this.installationId});
  final String installationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wizard = ref.watch(provisioningWizardProvider(installationId)
        .select((s) => (product: s.product, family: s.productFamily)));
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SetupDevicePreview(
              product: wizard.product,
              family: wizard.family,
              pattern: LedSetupPattern.whiteBlink,
              size: 112,
              labels: false,
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Enviando configuração...',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Isso pode levar até um minuto. Se o seu aparelho '
                'desconectar da rede do dispositivo, é normal.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
