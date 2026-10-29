import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../installation/application/installation_provider.dart';
import '../../application/provisioning_wizard_provider.dart';
import 'wizard_buttons.dart';

/// Step 2 — the installer names the device (mandatory) and may say where
/// it is (endereçamento, optional: picked from the installation's list or
/// typed; ≤ 16 bytes, the unit's slot — protocol §7.11 ADDRESS). The unit
/// announces both once; the board keeps the name and turns the endereçamento
/// into its label (§14.8). The zone is set later on the tablet, with the
/// rules.
class NameAddressStep extends ConsumerStatefulWidget {
  const NameAddressStep({super.key, required this.installationId});
  final String installationId;

  @override
  ConsumerState<NameAddressStep> createState() => _NameAddressStepState();
}

class _NameAddressStepState extends ConsumerState<NameAddressStep> {
  final _nameCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  /// The unit's slot holds 16 bytes of UTF-8 (protocol §7.11).
  static const addressMaxBytes = 16;

  bool get _addressFits =>
      utf8.encode(_addressCtrl.text.trim()).length <= addressMaxBytes;

  bool get _canContinue => _nameCtrl.text.trim().isNotEmpty && _addressFits;

  void _continue() {
    if (!_canContinue) return;
    ref
        .read(provisioningWizardProvider(widget.installationId).notifier)
        .submitNameAddress(
          name: _nameCtrl.text.trim(),
          address: _addressCtrl.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final addresses = ref
            .watch(installationListProvider)
            .valueOrNull
            ?.where((i) => i.localId == widget.installationId)
            .map((i) => i.addresses)
            .firstOrNull ??
        const <String>[];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            'Nome e endereçamento',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Dê um nome ao dispositivo. Se souber, diga onde ele fica; a zona '
            'é definida depois, na central.',
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 24),
          const _FieldLabel('NOME'),
          const SizedBox(height: 8),
          _TextField(
            controller: _nameCtrl,
            hint: 'ex: Sirene 1',
            onChanged: _onChanged,
            onSubmitted: (_) => _continue(),
          ),
          const SizedBox(height: 16),
          const _FieldLabel('ENDEREÇAMENTO (OPCIONAL)'),
          const SizedBox(height: 8),
          _TextField(
            controller: _addressCtrl,
            hint: 'ex: 1º andar',
            onChanged: _onChanged,
            onSubmitted: (_) => _continue(),
          ),
          if (!_addressFits) ...[
            const SizedBox(height: 6),
            const Text(
              'Até $addressMaxBytes caracteres (acentos contam dois).',
              style: TextStyle(color: AppColors.error, fontSize: 12),
            ),
          ],
          if (addresses.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in addresses)
                  ActionChip(
                    label: Text(a),
                    onPressed: () => setState(() => _addressCtrl.text = a),
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
          hintStyle: TextStyle(
              color: context.textSecondary.withValues(alpha: 0.4),
              fontSize: 13),
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
