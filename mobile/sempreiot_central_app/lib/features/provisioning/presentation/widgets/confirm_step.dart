import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../central/domain/led/led_language.dart';
import '../../../central/domain/safr/safr_product.dart';
import '../../../installation/application/installation_provider.dart';
import '../../application/provisioning_wizard_provider.dart';
import 'setup_device_preview.dart';
import 'wizard_buttons.dart';

/// Step 5 — summary before POST /provision (POC-BRIEF.md §5/§6.2).
class ConfirmStep extends ConsumerWidget {
  const ConfirmStep({super.key, required this.installationId});
  final String installationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = provisioningWizardProvider(installationId);
    final state = ref.watch(provider);
    final notifier = ref.read(provider.notifier);
    final installation = ref
        .watch(installationListProvider)
        .valueOrNull
        ?.where((i) => i.localId == installationId);
    final installationName = installation != null && installation.isNotEmpty
        ? installation.first.displayName
        : '—';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Center(
            child: SetupDevicePreview(
              product: state.product,
              family: state.productFamily,
              pattern: LedSetupPattern.whiteBlink,
              size: 96,
              labels: false,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Confirme a configuração',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),
          _SummaryCard(
            rows: [
              (Icons.memory_rounded, 'Dispositivo', state.sticker?.id ?? '—'),
              (
                Icons.category_rounded,
                'Produto',
                state.deviceInfo?.productDisplay ??
                    state.product?.display ??
                    '—'
              ),
              if (state.productFamily != SafrProductFamily.unknown)
                (Icons.account_tree_rounded, 'Tipo', state.productFamily.title),
              if (state.deviceInfo != null)
                (
                  Icons.system_update_alt_rounded,
                  'Firmware',
                  state.deviceInfo!.fw.isEmpty ? '—' : state.deviceInfo!.fw
                ),
              (Icons.badge_rounded, 'Nome', state.deviceName ?? '—'),
              (
                Icons.place_rounded,
                'Endereçamento',
                state.deviceAddress?.isNotEmpty == true
                    ? state.deviceAddress!
                    : '— (defina na central)'
              ),
              (Icons.hub_rounded, 'Instalação', installationName),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.error.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                state.error!,
                style: const TextStyle(color: AppColors.error, fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 24),
          WizardPrimaryButton(
            label: 'Configurar Dispositivo',
            icon: Icons.settings_input_antenna_rounded,
            onTap: notifier.submitProvision,
          ),
          const SizedBox(height: 12),
          WizardSecondaryButton(
            label: 'Voltar',
            onTap: notifier.backToNameAddress,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.rows});

  final List<(IconData, String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Divider(color: context.borderColor, height: 1),
              ),
            // Label over value, the value free to wrap (2026-10-29: a
            // product name or an endereçamento was cut to "…" on a phone).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(rows[i].$1, size: 18, color: AppColors.secondary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rows[i].$2,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        rows[i].$3,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontFamily: i == 0 ? 'monospace' : null,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
