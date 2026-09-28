import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_ext.dart';

/// Shows the passphrase-encrypted installation share (lifecycle §2) as a QR
/// plus a copy-as-text button.
///
/// Deliberately a plain [Dialog] with fixed sizes, not an [AlertDialog]:
/// AlertDialog wraps its content in IntrinsicWidth, and [QrImageView] lays
/// out through a LayoutBuilder, which cannot answer intrinsic queries
/// ("LayoutBuilder does not support returning intrinsic dimensions" — the
/// first bench bug, 2026-09-24).
Future<void> showEncryptedShareDialog(
  BuildContext context, {
  required String title,
  required String envelope,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => EncryptedShareDialog(title: title, envelope: envelope),
  );
}

class EncryptedShareDialog extends StatelessWidget {
  const EncryptedShareDialog({
    super.key,
    required this.title,
    required this.envelope,
  });

  final String title;
  final String envelope;

  static const qrSize = 230.0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Fits a phone in portrait and a tablet in landscape (~600 px tall).
    final width = size.width < 400 ? size.width - 32 : 360.0;
    final maxHeight = size.height * 0.85;
    return Dialog(
      backgroundColor: context.surfaceColor,
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(14),
                    // Fixed box: intrinsic queries never reach the QR's LayoutBuilder.
                    child: SizedBox(
                      width: qrSize,
                      height: qrSize,
                      child: QrImageView(
                        data: envelope,
                        version: QrVersions.auto,
                        size: qrSize,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: AppColors.primary,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Cifrado com a senha que você definiu. Uma foto do QR sem a '
                  'senha não serve para nada.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: envelope));
                    if (!context.mounted) return;
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('Código cifrado copiado.')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copiar como texto'),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Fechar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
