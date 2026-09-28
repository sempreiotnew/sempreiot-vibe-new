import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/provisioning_wizard_provider.dart';
import '../../data/services/wifi_join_service.dart';
import 'wizard_buttons.dart';

/// Step 3 — programmatic join of the device's setup SoftAP (POC-BRIEF.md
/// §6.2). The wizard notifier already attempted `WifiJoinService.connect`
/// and started polling /info on entering this step; this widget just
/// reflects progress and offers the manual-settings fallback.
class ConnectingStep extends ConsumerWidget {
  const ConnectingStep({super.key, required this.installationId});
  final String installationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = provisioningWizardProvider(installationId);
    final notifier = ref.read(provider.notifier);
    final error = ref.watch(provider.select((s) => s.error));
    final ssid = notifier.ssidHint;
    final automatic =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          const Center(child: _RadarPulse()),
          const SizedBox(height: 24),
          Text(
            'Conectando ao dispositivo',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              text: automatic ? 'Entrando na rede ' : 'Entre na rede ',
              style: TextStyle(color: context.textSecondary, fontSize: 13),
              children: [
                TextSpan(
                  text: ssid,
                  style: const TextStyle(
                    color: AppColors.secondary,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
                TextSpan(
                  text: automatic
                      ? ' automaticamente...'
                      : ' pelos Ajustes de Wi-Fi e volte para o app.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (error == null)
            const _SearchingBanner()
          else ...[
            _ErrorBanner(message: error),
            const SizedBox(height: 16),
            if (!kIsWeb)
              const WizardPrimaryButton(
                label: 'Abrir Ajustes de Wi-Fi',
                icon: Icons.wifi_rounded,
                onTap: WifiJoinService.openWifiSettingsManually,
              ),
            const SizedBox(height: 12),
            WizardSecondaryButton(
              label: 'Tentar novamente',
              icon: Icons.refresh_rounded,
              onTap: notifier.retryConnecting,
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: notifier.backToScan,
              child: Text(
                'Voltar',
                style: TextStyle(color: context.textSecondary, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: AppColors.error, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Pulsing radar rings around a device icon — "we're listening for it".
class _RadarPulse extends StatefulWidget {
  const _RadarPulse();

  @override
  State<_RadarPulse> createState() => _RadarPulseState();
}

class _RadarPulseState extends State<_RadarPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      height: 160,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _RadarPainter(progress: _controller.value),
          child: const Center(
            child: Icon(
              Icons.router_rounded,
              size: 40,
              color: AppColors.secondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progress});

  final double progress;

  static const _ringCount = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide / 2;
    const minRadius = 32.0;

    for (var i = 0; i < _ringCount; i++) {
      final t = (progress + i / _ringCount) % 1.0;
      final radius = minRadius + (maxRadius - minRadius) * t;
      final opacity = (1 - t) * 0.45;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = AppColors.secondary.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // Static inner disc behind the icon.
    canvas.drawCircle(
      center,
      minRadius,
      Paint()..color = AppColors.secondary.withValues(alpha: 0.10),
    );

    // Subtle rotating sweep dot on the middle ring.
    final sweepAngle = progress * 2 * math.pi;
    final dotRadius = minRadius + (maxRadius - minRadius) * 0.5;
    canvas.drawCircle(
      center +
          Offset(math.cos(sweepAngle), math.sin(sweepAngle)) * dotRadius,
      3,
      Paint()..color = AppColors.secondary.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _SearchingBanner extends StatelessWidget {
  const _SearchingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.secondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Procurando dispositivo... avançaremos automaticamente.',
              style: TextStyle(color: context.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
