import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../central/domain/led/led_language.dart';
import '../../application/provisioning_wizard_provider.dart';
import '../../domain/entities/provisioning_step.dart';
import 'setup_device_preview.dart';
import 'wizard_buttons.dart';

/// Step 4a — device reached, verifying the sticker's pop via HMAC proof
/// (POC-BRIEF.md §5). The unit keeps blinking white: `/identify` changes
/// nothing on its LED.
class IdentifyingStep extends ConsumerWidget {
  const IdentifyingStep({super.key, required this.installationId});
  final String installationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = provisioningWizardProvider(installationId);
    final info = ref.watch(provider.select((s) => s.deviceInfo));
    final wizard = ref.watch(
        provider.select((s) => (product: s.product, family: s.productFamily)));

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
            ),
            const SizedBox(height: 24),
            Text(
              'Dispositivo encontrado!',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Verificando identidade...',
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
              ],
            ),
            if (info != null) ...[
              const SizedBox(height: 16),
              Text(
                info.fw.isEmpty ? info.id : '${info.id} · fw ${info.fw}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Step 4b — device rejected the sticker's pop (proof mismatch), or
/// (`stickerMismatch`) said it is another product than its sticker prints:
/// a wrong label, nothing is sent, the installer checks the label.
class IdentifyFailedStep extends ConsumerWidget {
  const IdentifyFailedStep({super.key, required this.installationId});
  final String installationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = provisioningWizardProvider(installationId);
    final error = ref.watch(provider.select((s) => s.error));
    final mismatch = ref.watch(
        provider.select((s) => s.step == ProvisioningStep.stickerMismatch));
    final notifier = ref.read(provider.notifier);

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                mismatch ? Icons.label_off_rounded : Icons.gpp_bad_rounded,
                size: 42,
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              mismatch ? 'Etiqueta não confere' : 'Credenciais rejeitadas',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error ?? 'O dispositivo não reconheceu o POP informado.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 32),
            WizardPrimaryButton(
              label: 'Escanear novamente',
              icon: Icons.qr_code_scanner_rounded,
              onTap: notifier.backToScan,
            ),
            if (!mismatch) ...[
              const SizedBox(height: 12),
              WizardSecondaryButton(
                label: 'Tentar com os mesmos dados',
                onTap: notifier.retryIdentify,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
