import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../features/auth/application/otp_provider.dart';
import '../../widgets/iot_network_animation.dart';
import '../../widgets/otp_input_row.dart';
import '../splash/splash_screen.dart';

class OtpVerificationScreen extends ConsumerStatefulWidget {
  const OtpVerificationScreen({
    super.key,
    required this.username,
    required this.password,
    required this.isPhone,
    required this.displayIdentifier,
  });

  final String username;
  final String password;
  final bool isPhone;
  /// Original email or phone number — used only for masked display.
  final String displayIdentifier;

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState
    extends ConsumerState<OtpVerificationScreen> {
  // Single controller + focus node: avoids rapid focus-shifting that triggers
  // iOS UIKit keyboard constraint conflicts and blocks typing/paste.
  final TextEditingController _otpController = TextEditingController();
  final FocusNode _otpFocusNode = FocusNode();

  late Timer _resendTimer;
  int _secondsRemaining = 60;
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    _startCountdown();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _otpFocusNode.requestFocus();
    });
  }

  void _startCountdown() {
    setState(() {
      _secondsRemaining = 60;
      _canResend = false;
    });
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsRemaining <= 1) {
        t.cancel();
        if (mounted) setState(() => _canResend = true);
      } else {
        if (mounted) setState(() => _secondsRemaining--);
      }
    });
  }

  @override
  void dispose() {
    _resendTimer.cancel();
    _otpController.dispose();
    _otpFocusNode.dispose();
    super.dispose();
  }

  void _onOtpChanged(String value) {
    if (value.length == 6) _submit();
  }

  void _submit() {
    final code = _otpController.text;
    if (code.length < 6) return;
    ref.read(otpNotifierProvider.notifier).confirm(
          username: widget.username,
          code: code,
          password: widget.password,
        );
  }

  void _resend() {
    if (!_canResend) return;
    ref.read(otpNotifierProvider.notifier).resend(username: widget.username);
    _resendTimer.cancel();
    _startCountdown();
  }

  String _maskEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2) return email;
    final name = parts[0];
    final masked = name.length <= 2
        ? '*' * name.length
        : '${name[0]}${'*' * (name.length - 2)}${name[name.length - 1]}';
    return '$masked@${parts[1]}';
  }

  String _maskPhone(String phone) {
    if (phone.length < 6) return phone;
    return '${phone.substring(0, 4)}****${phone.substring(phone.length - 3)}';
  }

  String get _maskedDestination => widget.isPhone
      ? _maskPhone(widget.displayIdentifier)
      : _maskEmail(widget.displayIdentifier);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(otpNotifierProvider);
    final isLoading = state is OtpLoading || state is OtpResending;

    ref.listen(otpNotifierProvider, (_, next) {
      if (next is OtpConfirmed) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SplashScreen()),
          (_) => false,
        );
        return;
      }
      if (next is OtpError) {
        _otpController.clear();
        _otpFocusNode.requestFocus();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.message),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 6),
          ),
        );
        ref.read(otpNotifierProvider.notifier).reset();
      }
      if (next is OtpResendSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Código reenviado com sucesso.'),
            duration: Duration(seconds: 3),
          ),
        );
        ref.read(otpNotifierProvider.notifier).reset();
      }
    });

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      // Prevent the scaffold from resizing when the keyboard appears.
      // The scroll views handle keyboard insets manually to avoid the
      // layout-jump shaking that occurs with the default resize behaviour on iOS.
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 900) {
            return _DesktopLayout(
              maskedDestination: _maskedDestination,
              isPhone: widget.isPhone,
              otpController: _otpController,
              otpFocusNode: _otpFocusNode,
              secondsRemaining: _secondsRemaining,
              canResend: _canResend,
              isLoading: isLoading,
              onOtpChanged: _onOtpChanged,
              onSubmit: _submit,
              onResend: _resend,
              onBack: () => Navigator.of(context).pop(),
              isResending: state is OtpResending,
            );
          }
          return _MobileLayout(
            maskedDestination: _maskedDestination,
            isPhone: widget.isPhone,
            otpController: _otpController,
            otpFocusNode: _otpFocusNode,
            secondsRemaining: _secondsRemaining,
            canResend: _canResend,
            isLoading: isLoading,
            onOtpChanged: _onOtpChanged,
            onSubmit: _submit,
            onResend: _resend,
            onBack: () => Navigator.of(context).pop(),
            isResending: state is OtpResending,
          );
        },
      ),
    );
  }
}

// ── Mobile layout ──────────────────────────────────────────────────────────

class _MobileLayout extends StatelessWidget {
  const _MobileLayout({
    required this.maskedDestination,
    required this.isPhone,
    required this.otpController,
    required this.otpFocusNode,
    required this.secondsRemaining,
    required this.canResend,
    required this.isLoading,
    required this.isResending,
    required this.onOtpChanged,
    required this.onSubmit,
    required this.onResend,
    required this.onBack,
  });

  final String maskedDestination;
  final bool isPhone;
  final TextEditingController otpController;
  final FocusNode otpFocusNode;
  final int secondsRemaining;
  final bool canResend;
  final bool isLoading;
  final bool isResending;
  final void Function(String) onOtpChanged;
  final VoidCallback onSubmit;
  final VoidCallback onResend;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: RepaintBoundary(child: IoTNetworkAnimation()),
        ),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _BackButton(onTap: onBack),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    0,
                    24,
                    MediaQuery.viewInsetsOf(context).bottom + 24,
                  ),
                  child: _OtpContent(
                    maskedDestination: maskedDestination,
                    isPhone: isPhone,
                    otpController: otpController,
                    otpFocusNode: otpFocusNode,
                    secondsRemaining: secondsRemaining,
                    canResend: canResend,
                    isLoading: isLoading,
                    isResending: isResending,
                    onOtpChanged: onOtpChanged,
                    onSubmit: onSubmit,
                    onResend: onResend,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (isLoading)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black45,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

// ── Desktop layout ─────────────────────────────────────────────────────────

class _DesktopLayout extends StatelessWidget {
  const _DesktopLayout({
    required this.maskedDestination,
    required this.isPhone,
    required this.otpController,
    required this.otpFocusNode,
    required this.secondsRemaining,
    required this.canResend,
    required this.isLoading,
    required this.isResending,
    required this.onOtpChanged,
    required this.onSubmit,
    required this.onResend,
    required this.onBack,
  });

  final String maskedDestination;
  final bool isPhone;
  final TextEditingController otpController;
  final FocusNode otpFocusNode;
  final int secondsRemaining;
  final bool canResend;
  final bool isLoading;
  final bool isResending;
  final void Function(String) onOtpChanged;
  final VoidCallback onSubmit;
  final VoidCallback onResend;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 460,
          color: AppColors.backgroundDark,
          child: Stack(
            children: [
              SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _BackButton(onTap: onBack),
                      ),
                      const SizedBox(height: 40),
                      _OtpContent(
                        maskedDestination: maskedDestination,
                        isPhone: isPhone,
                        otpController: otpController,
                        otpFocusNode: otpFocusNode,
                        secondsRemaining: secondsRemaining,
                        canResend: canResend,
                        isLoading: isLoading,
                        isResending: isResending,
                        onOtpChanged: onOtpChanged,
                        onSubmit: onSubmit,
                        onResend: onResend,
                      ),
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ),
              if (isLoading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black45,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
        const Expanded(child: _BrandingPane()),
      ],
    );
  }
}

// ── Shared OTP content ─────────────────────────────────────────────────────

class _OtpContent extends StatelessWidget {
  const _OtpContent({
    required this.maskedDestination,
    required this.isPhone,
    required this.otpController,
    required this.otpFocusNode,
    required this.secondsRemaining,
    required this.canResend,
    required this.isLoading,
    required this.isResending,
    required this.onOtpChanged,
    required this.onSubmit,
    required this.onResend,
  });

  final String maskedDestination;
  final bool isPhone;
  final TextEditingController otpController;
  final FocusNode otpFocusNode;
  final int secondsRemaining;
  final bool canResend;
  final bool isLoading;
  final bool isResending;
  final void Function(String) onOtpChanged;
  final VoidCallback onSubmit;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        // Icon
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.4),
              width: 1.5,
            ),
          ),
          child: Icon(
            isPhone ? Icons.sms_outlined : Icons.email_outlined,
            color: AppColors.secondary,
            size: 28,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Verificação de código',
          style: AppTextStyles.displayLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Enviamos um código de 6 dígitos por ${isPhone ? 'SMS' : 'e-mail'} para',
          style: AppTextStyles.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          maskedDestination,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimaryDark,
          ),
        ),
        const SizedBox(height: 32),
        // 6-digit input — single hidden field + 6 visual boxes
        OtpInputRow(
          controller: otpController,
          focusNode: otpFocusNode,
          enabled: !isLoading,
          onChanged: onOtpChanged,
        ),
        const SizedBox(height: 28),
        // Confirm button
        SizedBox(
          height: 56,
          child: FilledButton(
            onPressed: isLoading ? null : onSubmit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.secondary,
              disabledBackgroundColor:
                  AppColors.secondary.withValues(alpha: 0.5),
              foregroundColor: AppColors.backgroundDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: isLoading && !isResending
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppColors.backgroundDark,
                    ),
                  )
                : const Text(
                    'Confirmar',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 20),
        // Resend / countdown
        Center(
          child: canResend
              ? TextButton(
                  onPressed: isResending ? null : onResend,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.secondary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                  child: isResending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.secondary,
                          ),
                        )
                      : const Text(
                          'Reenviar código',
                          style: AppTextStyles.link,
                        ),
                )
              : Text(
                  'Reenviar em ${secondsRemaining}s',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondaryDark,
                  ),
                ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

// ── Shared chrome ──────────────────────────────────────────────────────────

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: 'Voltar',
      icon: const Icon(
        Icons.chevron_left_rounded,
        color: AppColors.textPrimaryDark,
        size: 22,
      ),
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.divider),
        ),
      ),
    );
  }
}

class _BrandingPane extends StatelessWidget {
  const _BrandingPane();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const RepaintBoundary(child: IoTNetworkAnimation()),
        Container(color: AppColors.backgroundDark.withValues(alpha: 0.45)),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/logo_no_shadow.png',
                width: 120,
                height: 120,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 24),
              const Text(
                'SempreIoT',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimaryDark,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Conectando alertas.\nProtegendo vidas.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  color: AppColors.textSecondaryDark,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 40),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: AppColors.secondary.withValues(alpha: 0.3),
                  ),
                ),
                child: const Text(
                  'Sistema de Alarme de Incêndio',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
