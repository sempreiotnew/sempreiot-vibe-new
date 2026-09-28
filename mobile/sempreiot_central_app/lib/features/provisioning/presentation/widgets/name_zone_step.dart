import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../installation/application/installation_provider.dart';
import '../../application/provisioning_wizard_provider.dart';
import 'wizard_buttons.dart';

/// Step 2 — operator names the device and picks (or types) a zone within
/// the installation (POC-BRIEF.md §6.2).
class NameZoneStep extends ConsumerStatefulWidget {
  const NameZoneStep({super.key, required this.installationId});
  final String installationId;

  @override
  ConsumerState<NameZoneStep> createState() => _NameZoneStepState();
}

class _NameZoneStepState extends ConsumerState<NameZoneStep> {
  final _nameCtrl = TextEditingController();
  final _zoneCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _zoneCtrl.dispose();
    super.dispose();
  }

  bool get _canContinue =>
      _nameCtrl.text.trim().isNotEmpty && _zoneCtrl.text.trim().isNotEmpty;

  void _continue() {
    if (!_canContinue) return;
    ref
        .read(provisioningWizardProvider(widget.installationId).notifier)
        .submitNameZone(
          name: _nameCtrl.text.trim(),
          zone: _zoneCtrl.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final zones = ref
            .watch(installationListProvider)
            .valueOrNull
            ?.where((i) => i.localId == widget.installationId)
            .map((i) => i.zones)
            .firstOrNull ??
        const <String>[];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            'Nome e zona',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Dê um nome ao dispositivo e escolha a zona onde ele será instalado.',
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 24),
          const _FieldLabel('NOME'),
          const SizedBox(height: 8),
          _TextField(controller: _nameCtrl, hint: 'ex: Sirene 1', onChanged: _onChanged),
          const SizedBox(height: 16),
          const _FieldLabel('ZONA'),
          const SizedBox(height: 8),
          _TextField(
            controller: _zoneCtrl,
            hint: 'ex: Térreo',
            onChanged: _onChanged,
            onSubmitted: (_) => _continue(),
          ),
          if (zones.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final z in zones)
                  ActionChip(
                    label: Text(z),
                    onPressed: () => setState(() => _zoneCtrl.text = z),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          WizardPrimaryButton(
            label: 'Continuar',
            onTap: _canContinue ? _continue : null,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _onChanged(String _) => setState(() {});
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: context.textSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.secondary.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: TextField(
        controller: controller,
        style: TextStyle(color: context.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              TextStyle(color: context.textSecondary.withValues(alpha: 0.4), fontSize: 13),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: InputBorder.none,
        ),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    );
  }
}
