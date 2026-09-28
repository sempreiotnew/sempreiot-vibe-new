import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../installation/application/installation_provider.dart';
import '../../application/provisioning_wizard_provider.dart';
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
    final installationName =
        installation != null && installation.isNotEmpty
            ? installation.first.displayName
            : '—';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
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
              if (state.deviceInfo != null)
                (Icons.tag_rounded, 'Modelo', state.deviceInfo!.model),
              (Icons.badge_rounded, 'Nome', state.deviceName ?? '—'),
              (Icons.place_rounded, 'Zona', state.deviceZone ?? '—'),
              (Icons.hub_rounded, 'Instalação', installationName),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            onTap: notifier.backToNameZone,
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
            Row(
              children: [
                Icon(rows[i].$1, size: 18, color: AppColors.secondary),
                const SizedBox(width: 12),
                Text(
                  rows[i].$2,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    rows[i].$3,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
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
