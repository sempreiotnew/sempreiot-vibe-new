import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../auth/application/auth_provider.dart';
import '../../../central/application/central_iot_provider.dart';
import '../../../iot/application/iot_provider.dart';

class MyQrScreen extends ConsumerWidget {
  const MyQrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCentral = AppConfig.isCentral;

    final subId = isCentral
        ? ref.watch(centralMqttRepositoryProvider).userId ?? ''
        : ref.watch(authNotifierProvider).valueOrNull?.userId ?? '';

    final identityId = isCentral
        ? ref.watch(centralMqttRepositoryProvider).identityId ?? ''
        : ref.watch(iotMqttRepositoryProvider).identityId ?? '';

    final type = isCentral ? 'central' : 'user';
    final label = isCentral ? 'QR da Central' : 'Meu QR Code';

    // The QR encodes just the subId — the lookup Lambda resolves the rest.
    final qrData = subId.isEmpty ? 'unavailable' : subId;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          label,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: context.borderColor.withValues(alpha: 0.5),
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          final qrSize = (isWide
                  ? constraints.maxWidth * 0.3
                  : constraints.maxWidth * 0.6)
              .clamp(180.0, 280.0);

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── QR Code ───────────────────────────────────────────────
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: subId.isEmpty
                          ? _PlaceholderQr(size: qrSize)
                          : Container(
                              key: const ValueKey('qr'),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 24,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.all(20),
                              child: QrImageView(
                                data: qrData,
                                version: QrVersions.auto,
                                size: qrSize,
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
                    const SizedBox(height: 32),

                    // ── Type badge ────────────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.secondary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.secondary.withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        type.toUpperCase(),
                        style: const TextStyle(
                          color: AppColors.secondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Sub ID ────────────────────────────────────────────────
                    _IdRow(
                      label: 'Sub ID',
                      value: subId,
                    ),
                    const SizedBox(height: 8),

                    if (identityId.isNotEmpty) ...[
                      _IdRow(
                        label: 'Identity ID',
                        value: identityId,
                      ),
                      const SizedBox(height: 8),
                    ],

                    if (subId.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          isCentral
                              ? 'Aguardando conexão MQTT...'
                              : 'Faça login para ver seu QR.',
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),

                    if (subId.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _CopyButton(value: subId),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PlaceholderQr extends StatelessWidget {
  const _PlaceholderQr({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('placeholder'),
      width: size + 40,
      height: size + 40,
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.qr_code_rounded,
            size: size * 0.4,
            color: context.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            'Gerando...',
            style: TextStyle(
              color: context.textSecondary.withValues(alpha: 0.4),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _IdRow extends StatelessWidget {
  const _IdRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.value});
  final String value;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: OutlinedButton.icon(
        key: ValueKey(_copied),
        onPressed: _copy,
        icon: Icon(
          _copied ? Icons.check_rounded : Icons.copy_rounded,
          size: 16,
          color: _copied ? AppColors.success : AppColors.secondary,
        ),
        label: Text(
          _copied ? 'Copiado!' : 'Copiar Sub ID',
          style: TextStyle(
            color: _copied ? AppColors.success : AppColors.secondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: _copied
                ? AppColors.success.withValues(alpha: 0.5)
                : AppColors.secondary.withValues(alpha: 0.4),
            width: 1,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
