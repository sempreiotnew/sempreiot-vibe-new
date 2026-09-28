import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../features/auth/application/forgot_password_provider.dart';
import '../../widgets/auth_form_widgets.dart';
import '../../widgets/iot_network_animation.dart';
import '../../widgets/otp_input_row.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  // Step 1
  final _step1FormKey = GlobalKey<FormState>();
  final _identifierCtrl = TextEditingController();
  bool _usePhone = false;

  // Step 2
  final _step2FormKey = GlobalKey<FormState>();
  final _otpCtrl = TextEditingController();
  final _otpFocusNode = FocusNode();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  // Resend countdown
  late Timer _resendTimer;
  int _secondsRemaining = 60;
  bool _canResend = false;
  bool _timerStarted = false;

  String? _displayIdentifier;

  @override
  void initState() {
    super.initState();
    // Riverpod disallows state mutation during build. Defer to post-frame so
    // the screen always opens fresh regardless of previous navigation state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(forgotPasswordNotifierProvider.notifier).reset();
    });
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _otpCtrl.dispose();
    _otpFocusNode.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    if (_timerStarted) _resendTimer.cancel();
    super.dispose();
  }

  void _startCountdown() {
    if (_timerStarted) _resendTimer.cancel();
    setState(() {
      _secondsRemaining = 60;
      _canResend = false;
      _timerStarted = true;
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

  void _submitStep1() {
    FocusScope.of(context).unfocus();
    if (!_step1FormKey.currentState!.validate()) return;
    final identifier = _usePhone
        ? _identifierCtrl.text.replaceAll(RegExp(r'[^\+\d]'), '')
        : _identifierCtrl.text.trim();
    _displayIdentifier = identifier;
    ref
        .read(forgotPasswordNotifierProvider.notifier)
        .sendCode(identifier, isPhone: _usePhone);
  }

  void _submitStep2(ForgotPasswordCodeSent data) {
    FocusScope.of(context).unfocus();
    if (!_step2FormKey.currentState!.validate()) return;
    if (_otpCtrl.text.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe o código de 6 dígitos.')),
      );
      return;
    }
    ref.read(forgotPasswordNotifierProvider.notifier).confirmReset(
          username: data.username,
          code: _otpCtrl.text,
          newPassword: _passwordCtrl.text,
          codeSentData: data,
        );
  }

  void _resend(ForgotPasswordCodeSent data) {
    if (!_canResend) return;
    _resendTimer.cancel();
    _startCountdown();
    ref.read(forgotPasswordNotifierProvider.notifier).resendCode(
          username: data.username,
          isPhone: data.isPhone,
          displayIdentifier: _displayIdentifier ?? _identifierCtrl.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(forgotPasswordNotifierProvider);

    ref.listen(forgotPasswordNotifierProvider, (_, next) {
      if (next is ForgotPasswordCodeSent && !_timerStarted) {
        _startCountdown();
      }
      if (next is ForgotPasswordError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.message),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 6),
          ),
        );
        ref
            .read(forgotPasswordNotifierProvider.notifier)
            .restoreAfterError(next.codeSentData);
      }
    });

    final isOnStep2 = state is ForgotPasswordCodeSent ||
        state is ForgotPasswordResending ||
        state is ForgotPasswordConfirming;

    final codeSentData = switch (state) {
      ForgotPasswordCodeSent() => state,
      ForgotPasswordResending() => ForgotPasswordCodeSent(
          username: state.username,
          isPhone: state.isPhone,
          destination: state.destination,
          isSms: state.isSms,
        ),
      ForgotPasswordConfirming() => ForgotPasswordCodeSent(
          username: state.username,
          isPhone: state.isPhone,
          destination: state.destination,
          isSms: state.isSms,
        ),
      _ => null,
    };

    final isLoading = state is ForgotPasswordSendingCode ||
        state is ForgotPasswordConfirming;
    final isResending = state is ForgotPasswordResending;

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 900) {
            return _DesktopLayout(
              isOnStep2: isOnStep2,
              codeSentData: codeSentData,
              step1FormKey: _step1FormKey,
              step2FormKey: _step2FormKey,
              identifierCtrl: _identifierCtrl,
              otpCtrl: _otpCtrl,
              otpFocusNode: _otpFocusNode,
              passwordCtrl: _passwordCtrl,
              confirmCtrl: _confirmCtrl,
              usePhone: _usePhone,
              obscurePassword: _obscurePassword,
              obscureConfirm: _obscureConfirm,
              isLoading: isLoading,
              isResending: isResending,
              secondsRemaining: _secondsRemaining,
              canResend: _canResend,
              isSuccess: state is ForgotPasswordSuccess,
              onToggleIdentifier: () => setState(() {
                _usePhone = !_usePhone;
                _identifierCtrl.clear();
              }),
              onTogglePassword: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              onToggleConfirm: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
              onSubmitStep1: _submitStep1,
              onSubmitStep2: codeSentData != null
                  ? () => _submitStep2(codeSentData)
                  : null,
              onResend:
                  codeSentData != null ? () => _resend(codeSentData) : null,
              onBack: () {
                if (isOnStep2) {
                  ref
                      .read(forgotPasswordNotifierProvider.notifier)
                      .reset();
                  _otpCtrl.clear();
                  _timerStarted = false;
                  setState(() {});
                } else {
                  Navigator.of(context).pop();
                }
              },
            );
          }
          return _MobileLayout(
            isOnStep2: isOnStep2,
            codeSentData: codeSentData,
            step1FormKey: _step1FormKey,
            step2FormKey: _step2FormKey,
            identifierCtrl: _identifierCtrl,
            otpCtrl: _otpCtrl,
            otpFocusNode: _otpFocusNode,
            passwordCtrl: _passwordCtrl,
            confirmCtrl: _confirmCtrl,
            usePhone: _usePhone,
            obscurePassword: _obscurePassword,
            obscureConfirm: _obscureConfirm,
            isLoading: isLoading,
            isResending: isResending,
            secondsRemaining: _secondsRemaining,
            canResend: _canResend,
            isSuccess: state is ForgotPasswordSuccess,
            onToggleIdentifier: () => setState(() {
              _usePhone = !_usePhone;
              _identifierCtrl.clear();
            }),
            onTogglePassword: () =>
                setState(() => _obscurePassword = !_obscurePassword),
            onToggleConfirm: () =>
                setState(() => _obscureConfirm = !_obscureConfirm),
            onSubmitStep1: _submitStep1,
            onSubmitStep2:
                codeSentData != null ? () => _submitStep2(codeSentData) : null,
            onResend:
                codeSentData != null ? () => _resend(codeSentData) : null,
            onBack: () {
              if (isOnStep2) {
                ref.read(forgotPasswordNotifierProvider.notifier).reset();
                _otpCtrl.clear();
                _timerStarted = false;
                setState(() {});
              } else {
                Navigator.of(context).pop();
              }
            },
          );
        },
      ),
    );
  }
}

// ── Mobile layout ──────────────────────────────────────────────────────────

class _MobileLayout extends StatelessWidget {
  const _MobileLayout({
    required this.isOnStep2,
    required this.codeSentData,
    required this.step1FormKey,
    required this.step2FormKey,
    required this.identifierCtrl,
    required this.otpCtrl,
    required this.otpFocusNode,
    required this.passwordCtrl,
    required this.confirmCtrl,
    required this.usePhone,
    required this.obscurePassword,
    required this.obscureConfirm,
    required this.isLoading,
    required this.isResending,
    required this.secondsRemaining,
    required this.canResend,
    required this.isSuccess,
    required this.onToggleIdentifier,
    required this.onTogglePassword,
    required this.onToggleConfirm,
    required this.onSubmitStep1,
    required this.onSubmitStep2,
    required this.onResend,
    required this.onBack,
  });

  final bool isOnStep2;
  final ForgotPasswordCodeSent? codeSentData;
  final GlobalKey<FormState> step1FormKey;
  final GlobalKey<FormState> step2FormKey;
  final TextEditingController identifierCtrl;
  final TextEditingController otpCtrl;
  final FocusNode otpFocusNode;
  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool usePhone;
  final bool obscurePassword;
  final bool obscureConfirm;
  final bool isLoading;
  final bool isResending;
  final int secondsRemaining;
  final bool canResend;
  final bool isSuccess;
  final VoidCallback onToggleIdentifier;
  final VoidCallback onTogglePassword;
  final VoidCallback onToggleConfirm;
  final VoidCallback onSubmitStep1;
  final VoidCallback? onSubmitStep2;
  final VoidCallback? onResend;
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
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: isSuccess
                        ? const _SuccessContent(key: ValueKey('success'))
                        : isOnStep2 && codeSentData != null
                            ? _Step2Content(
                                key: const ValueKey('step2'),
                                codeSentData: codeSentData!,
                                formKey: step2FormKey,
                                otpCtrl: otpCtrl,
                                otpFocusNode: otpFocusNode,
                                passwordCtrl: passwordCtrl,
                                confirmCtrl: confirmCtrl,
                                obscurePassword: obscurePassword,
                                obscureConfirm: obscureConfirm,
                                isLoading: isLoading,
                                isResending: isResending,
                                secondsRemaining: secondsRemaining,
                                canResend: canResend,
                                onTogglePassword: onTogglePassword,
                                onToggleConfirm: onToggleConfirm,
                                onSubmit: onSubmitStep2,
                                onResend: onResend,
                              )
                            : _Step1Content(
                                key: const ValueKey('step1'),
                                formKey: step1FormKey,
                                identifierCtrl: identifierCtrl,
                                usePhone: usePhone,
                                isLoading: isLoading,
                                onToggleIdentifier: onToggleIdentifier,
                                onSubmit: onSubmitStep1,
                              ),
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
    required this.isOnStep2,
    required this.codeSentData,
    required this.step1FormKey,
    required this.step2FormKey,
    required this.identifierCtrl,
    required this.otpCtrl,
    required this.otpFocusNode,
    required this.passwordCtrl,
    required this.confirmCtrl,
    required this.usePhone,
    required this.obscurePassword,
    required this.obscureConfirm,
    required this.isLoading,
    required this.isResending,
    required this.secondsRemaining,
    required this.canResend,
    required this.isSuccess,
    required this.onToggleIdentifier,
    required this.onTogglePassword,
    required this.onToggleConfirm,
    required this.onSubmitStep1,
    required this.onSubmitStep2,
    required this.onResend,
    required this.onBack,
  });

  final bool isOnStep2;
  final ForgotPasswordCodeSent? codeSentData;
  final GlobalKey<FormState> step1FormKey;
  final GlobalKey<FormState> step2FormKey;
  final TextEditingController identifierCtrl;
  final TextEditingController otpCtrl;
  final FocusNode otpFocusNode;
  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool usePhone;
  final bool obscurePassword;
  final bool obscureConfirm;
  final bool isLoading;
  final bool isResending;
  final int secondsRemaining;
  final bool canResend;
  final bool isSuccess;
  final VoidCallback onToggleIdentifier;
  final VoidCallback onTogglePassword;
  final VoidCallback onToggleConfirm;
  final VoidCallback onSubmitStep1;
  final VoidCallback? onSubmitStep2;
  final VoidCallback? onResend;
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
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: isSuccess
                            ? const _SuccessContent(key: ValueKey('success'))
                            : isOnStep2 && codeSentData != null
                                ? _Step2Content(
                                    key: const ValueKey('step2'),
                                    codeSentData: codeSentData!,
                                    formKey: step2FormKey,
                                    otpCtrl: otpCtrl,
                                    otpFocusNode: otpFocusNode,
                                    passwordCtrl: passwordCtrl,
                                    confirmCtrl: confirmCtrl,
                                    obscurePassword: obscurePassword,
                                    obscureConfirm: obscureConfirm,
                                    isLoading: isLoading,
                                    isResending: isResending,
                                    secondsRemaining: secondsRemaining,
                                    canResend: canResend,
                                    onTogglePassword: onTogglePassword,
                                    onToggleConfirm: onToggleConfirm,
                                    onSubmit: onSubmitStep2,
                                    onResend: onResend,
                                  )
                                : _Step1Content(
                                    key: const ValueKey('step1'),
                                    formKey: step1FormKey,
                                    identifierCtrl: identifierCtrl,
                                    usePhone: usePhone,
                                    isLoading: isLoading,
                                    onToggleIdentifier: onToggleIdentifier,
                                    onSubmit: onSubmitStep1,
                                  ),
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

// ── Step 1: enter identifier ───────────────────────────────────────────────

class _Step1Content extends StatelessWidget {
  const _Step1Content({
    super.key,
    required this.formKey,
    required this.identifierCtrl,
    required this.usePhone,
    required this.isLoading,
    required this.onToggleIdentifier,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController identifierCtrl;
  final bool usePhone;
  final bool isLoading;
  final VoidCallback onToggleIdentifier;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
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
            child: const Icon(
              Icons.lock_reset_outlined,
              color: AppColors.secondary,
              size: 28,
            ),
          ),
          const SizedBox(height: 20),
          const Text('Esqueceu sua senha?', style: AppTextStyles.displayLarge),
          const SizedBox(height: 8),
          Text(
            'Informe seu ${usePhone ? 'telefone' : 'e-mail'} e enviaremos um código de verificação.',
            style: AppTextStyles.bodyMedium,
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              AuthToggleChip(
                label: 'E-mail',
                selected: !usePhone,
                onTap: usePhone ? onToggleIdentifier : null,
              ),
              const SizedBox(width: 8),
              AuthToggleChip(
                label: 'Telefone',
                selected: usePhone,
                onTap: !usePhone ? onToggleIdentifier : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: AuthField(
              key: ValueKey(usePhone),
              controller: identifierCtrl,
              label: usePhone ? 'Telefone (ex: +5511999998888)' : 'E-mail',
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: usePhone
                  ? [FilteringTextInputFormatter.allow(RegExp(r'[+\d]'))]
                  : null,
              onFieldSubmitted: (_) => onSubmit(),
              validator: usePhone
                  ? (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Informe seu telefone';
                      }
                      final n = v.trim().replaceAll(RegExp(r'[^\+\d]'), '');
                      if (!RegExp(r'^\+\d{8,15}$').hasMatch(n)) {
                        return 'Use o formato: +5511999998888';
                      }
                      return null;
                    }
                  : (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Informe seu e-mail';
                      }
                      if (!RegExp(
                        r'^[\w.+\-]+@[a-zA-Z\d\-]+\.[a-zA-Z\d\-.]+$',
                      ).hasMatch(v.trim())) {
                        return 'E-mail inválido';
                      }
                      return null;
                    },
            ),
          ),
          const SizedBox(height: 28),
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
              child: isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.backgroundDark,
                      ),
                    )
                  : const Text(
                      'Enviar código',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ── Step 2: verify code + new password ─────────────────────────────────────

class _Step2Content extends StatelessWidget {
  const _Step2Content({
    super.key,
    required this.codeSentData,
    required this.formKey,
    required this.otpCtrl,
    required this.otpFocusNode,
    required this.passwordCtrl,
    required this.confirmCtrl,
    required this.obscurePassword,
    required this.obscureConfirm,
    required this.isLoading,
    required this.isResending,
    required this.secondsRemaining,
    required this.canResend,
    required this.onTogglePassword,
    required this.onToggleConfirm,
    required this.onSubmit,
    required this.onResend,
  });

  final ForgotPasswordCodeSent codeSentData;
  final GlobalKey<FormState> formKey;
  final TextEditingController otpCtrl;
  final FocusNode otpFocusNode;
  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool obscurePassword;
  final bool obscureConfirm;
  final bool isLoading;
  final bool isResending;
  final int secondsRemaining;
  final bool canResend;
  final VoidCallback onTogglePassword;
  final VoidCallback onToggleConfirm;
  final VoidCallback? onSubmit;
  final VoidCallback? onResend;

  String _maskEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2) return email;
    final name = parts[0];
    final masked = name.length <= 2
        ? '*' * name.length
        : '${name[0]}${'*' * (name.length - 2)}${name[name.length - 1]}';
    return '$masked@${parts[1]}';
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
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
              codeSentData.isSms ? Icons.sms_outlined : Icons.email_outlined,
              color: AppColors.secondary,
              size: 28,
            ),
          ),
          const SizedBox(height: 20),
          const Text('Verifique seu código', style: AppTextStyles.displayLarge),
          const SizedBox(height: 8),
          Text(
            'Enviamos um código por ${codeSentData.isSms ? 'SMS' : 'e-mail'} para',
            style: AppTextStyles.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            codeSentData.isSms
                ? codeSentData.destination
                : _maskEmail(codeSentData.destination),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimaryDark,
            ),
          ),
          const SizedBox(height: 28),
          OtpInputRow(
            controller: otpCtrl,
            focusNode: otpFocusNode,
            enabled: !isLoading,
            onChanged: (_) {},
          ),
          const SizedBox(height: 20),
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
                        : const Text('Reenviar código', style: AppTextStyles.link),
                  )
                : Text(
                    'Reenviar em ${secondsRemaining}s',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondaryDark,
                    ),
                  ),
          ),
          const SizedBox(height: 20),
          const Divider(color: AppColors.divider),
          const SizedBox(height: 20),
          AuthField(
            controller: passwordCtrl,
            label: 'Nova senha',
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.next,
            suffix: AuthVisibilityToggle(
              obscure: obscurePassword,
              onToggle: onTogglePassword,
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Informe a nova senha';
              if (v.length < 8) return 'Mínimo de 8 caracteres';
              if (!RegExp(r'[A-Z]').hasMatch(v)) {
                return 'Inclua ao menos uma letra maiúscula';
              }
              if (!RegExp(r'[0-9]').hasMatch(v)) {
                return 'Inclua ao menos um número';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          AuthField(
            controller: confirmCtrl,
            label: 'Confirmar nova senha',
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: obscureConfirm,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => onSubmit?.call(),
            suffix: AuthVisibilityToggle(
              obscure: obscureConfirm,
              onToggle: onToggleConfirm,
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Confirme a nova senha';
              if (v != passwordCtrl.text) return 'As senhas não coincidem';
              return null;
            },
          ),
          const SizedBox(height: 28),
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
                      'Redefinir senha',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ── Success state ──────────────────────────────────────────────────────────

class _SuccessContent extends StatelessWidget {
  const _SuccessContent({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: const Color(0xFF0D2318),
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF2D6A4F).withValues(alpha: 0.7),
              width: 1.5,
            ),
          ),
          child: const Icon(
            Icons.check_rounded,
            color: Color(0xFF52B788),
            size: 32,
          ),
        ),
        const SizedBox(height: 20),
        const Text('Senha redefinida!', style: AppTextStyles.displayLarge),
        const SizedBox(height: 8),
        const Text(
          'Sua senha foi atualizada com sucesso. Faça login com sua nova senha.',
          style: AppTextStyles.bodyMedium,
        ),
        const SizedBox(height: 32),
        SizedBox(
          height: 56,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.secondary,
              foregroundColor: AppColors.backgroundDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Ir para o login',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
            ],
          ),
        ),
      ],
    );
  }
}
