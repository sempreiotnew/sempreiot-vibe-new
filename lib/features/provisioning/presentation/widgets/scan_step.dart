import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../access/presentation/screens/qr_scanner_screen.dart';
import '../../application/provisioning_wizard_provider.dart';
import '../../domain/entities/device_qr_payload.dart';
import 'wizard_buttons.dart';

/// Step 1 — scan the device's factory sticker QR ({id, mac, pop}) or type
/// it manually (POC-BRIEF.md §6.2).
class ScanStep extends ConsumerStatefulWidget {
  const ScanStep({super.key, required this.installationId});
  final String installationId;

  @override
  ConsumerState<ScanStep> createState() => _ScanStepState();
}

class _ScanStepState extends ConsumerState<ScanStep> {
  final _idCtrl = TextEditingController();
  final _macCtrl = TextEditingController();
  final _popCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _idCtrl.dispose();
    _macCtrl.dispose();
    _popCtrl.dispose();
    super.dispose();
  }

  bool get _canContinue =>
      _idCtrl.text.trim().isNotEmpty &&
      _macCtrl.text.trim().isNotEmpty &&
      _popCtrl.text.trim().isNotEmpty;

  Future<void> _scanQr() async {
    if (kIsWeb) return;
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrScannerScreen(
          hint: 'Aponte para o QR Code do dispositivo',
        ),
      ),
    );
    if (!mounted || scanned == null || scanned.trim().isEmpty) return;

    final payload = DeviceQrPayload.tryParse(scanned);
    if (payload == null) {
      setState(() => _error =
          'QR Code inválido. Use a etiqueta impressa no dispositivo.');
      return;
    }
    _idCtrl.text = payload.id;
    _macCtrl.text = payload.mac;
    _popCtrl.text = payload.pop;
    setState(() => _error = null);
    _continue();
  }

  void _continue() {
    if (!_canContinue) return;
    ref
        .read(provisioningWizardProvider(widget.installationId).notifier)
        .setSticker(DeviceQrPayload(
          id: _idCtrl.text.trim(),
          mac: _macCtrl.text.trim(),
          pop: _popCtrl.text.trim(),
        ));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          _QrIllustration(onTap: kIsWeb ? null : _scanQr),
          const SizedBox(height: 24),
          Text(
            'Identifique o dispositivo',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            kIsWeb
                ? 'Digite o ID, MAC e POP impressos na etiqueta do dispositivo.'
                : 'Escaneie o QR Code impresso no dispositivo ou digite os dados da etiqueta.',
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 24),
          if (!kIsWeb) ...[
            WizardPrimaryButton(
              label: 'Escanear QR Code',
              icon: Icons.qr_code_scanner_rounded,
              onTap: _scanQr,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: Divider(color: context.borderColor)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'ou digite manualmente',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(child: Divider(color: context.borderColor)),
              ],
            ),
            const SizedBox(height: 20),
          ],
          const _FieldLabel('ID DO DISPOSITIVO'),
          const SizedBox(height: 8),
          _MonoField(
            controller: _idCtrl,
            hint: 'ex: dev-001',
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 16),
          const _FieldLabel('MAC'),
          const SizedBox(height: 8),
          _MonoField(
            controller: _macCtrl,
            hint: 'AA:BB:CC:DD:EE:FF',
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 16),
          const _FieldLabel('POP'),
          const SizedBox(height: 8),
          _MonoField(
            controller: _popCtrl,
            hint: 'senha de fábrica do dispositivo',
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _continue(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: AppColors.error, fontSize: 12),
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
}

class _QrIllustration extends StatelessWidget {
  const _QrIllustration({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.25),
            ),
          ),
          // No camera on web — show a device chip instead of a QR code so
          // the illustration doesn't promise a scan that isn't offered.
          child: const Icon(
            kIsWeb ? Icons.memory_rounded : Icons.qr_code_2_rounded,
            size: 56,
            color: AppColors.secondary,
          ),
        ),
      ),
    );
  }
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

class _MonoField extends StatelessWidget {
  const _MonoField({
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
        style: TextStyle(
          color: context.textPrimary,
          fontSize: 14,
          fontFamily: 'monospace',
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: context.textSecondary.withValues(alpha: 0.4),
            fontSize: 13,
            fontFamily: 'monospace',
          ),
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
