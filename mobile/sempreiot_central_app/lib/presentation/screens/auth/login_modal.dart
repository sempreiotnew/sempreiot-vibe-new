import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../features/auth/application/login_provider.dart';
import '../../widgets/auth_form_widgets.dart';
import '../splash/splash_screen.dart';

class SempreIoTLoginModal extends ConsumerStatefulWidget {
  const SempreIoTLoginModal({
    super.key,
    this.onCreateAccount,
    this.onForgotPassword,
  });

  final VoidCallback? onCreateAccount;
  final VoidCallback? onForgotPassword;

  @override
  ConsumerState<SempreIoTLoginModal> createState() =>
      _SempreIoTLoginModalState();
}

class _SempreIoTLoginModalState extends ConsumerState<SempreIoTLoginModal> {
  final _formKey = GlobalKey<FormState>();
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _usePhone = false;
  bool _obscurePassword = true;
  String? _identifierServerError;
  String? _passwordServerError;

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    setState(() {
      _identifierServerError = null;
      _passwordServerError = null;
    });
    if (!_formKey.currentState!.validate()) return;
    final identifier = _usePhone
        ? _identifierCtrl.text.replaceAll(RegExp(r'[^\+\d]'), '')
        : _identifierCtrl.text.trim();
    ref.read(loginNotifierProvider.notifier).signIn(
          identifier: identifier,
          password: _passwordCtrl.text,
          isPhone: _usePhone,
        );
  }

  void _handleError(String raw) {
    if (raw.startsWith('field:identifier:')) {
      setState(() => _identifierServerError = raw.substring(17));
    } else if (raw.startsWith('field:password:')) {
      setState(() => _passwordServerError = raw.substring(15));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(raw),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loginState = ref.watch(loginNotifierProvider);
    final isLoading = loginState is LoginLoading;
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;

    ref.listen(loginNotifierProvider, (_, next) {
      if (next is LoginSuccess) {
        ref.read(loginNotifierProvider.notifier).reset();
        if (!mounted) return;
        // Remove every route (modal + LoginScreen) and push SplashScreen.
        // SplashScreen itself watches appInitProvider and navigates to
        // MainScreen when initialisation finishes.
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SplashScreen()),
          (_) => false,
        );
      } else if (next is LoginError) {
        _handleError(next.message);
        ref.read(loginNotifierProvider.notifier).reset();
      }
    });

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundDark,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(
            color: AppColors.secondary.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ModalHeader(),
                    const SizedBox(height: 24),
                    _LoginForm(
                      formKey: _formKey,
                      identifierCtrl: _identifierCtrl,
                      passwordCtrl: _passwordCtrl,
                      usePhone: _usePhone,
                      obscurePassword: _obscurePassword,
                      isLoading: isLoading,
                      identifierServerError: _identifierServerError,
                      passwordServerError: _passwordServerError,
                      onToggleIdentifierMode: () => setState(() {
                        _usePhone = !_usePhone;
                        _identifierCtrl.clear();
                        _identifierServerError = null;
                      }),
                      onIdentifierChanged: (_) {
                        if (_identifierServerError != null) {
                          setState(() => _identifierServerError = null);
                        }
                      },
                      onPasswordChanged: (_) {
                        if (_passwordServerError != null) {
                          setState(() => _passwordServerError = null);
                        }
                      },
                      onTogglePassword: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      onSubmit: _submit,
                      onCreateAccount: () {
                        Navigator.of(context).pop();
                        widget.onCreateAccount?.call();
                      },
                      onForgotPassword: () {
                        Navigator.of(context).pop();
                        widget.onForgotPassword?.call();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Header ─────────────────────────────────────────────────────────────────

class _ModalHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.25),
            ),
          ),
          child: Center(
            child: Image.asset(
              'assets/images/logo_no_shadow.png',
              width: 26,
              height: 26,
              fit: BoxFit.contain,
            ),
          ),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Entrar',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimaryDark,
                  letterSpacing: -0.3,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Acesse sua conta SempreIoT',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryDark,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _SecureBadge(),
      ],
    );
  }
}

class _SecureBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0D2318),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF2D6A4F).withValues(alpha: 0.7),
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_outlined, size: 12, color: Color(0xFF52B788)),
          SizedBox(width: 4),
          Text(
            'Seguro',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF52B788),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Form ───────────────────────────────────────────────────────────────────

class _LoginForm extends StatelessWidget {
  const _LoginForm({
    required this.formKey,
    required this.identifierCtrl,
    required this.passwordCtrl,
    required this.usePhone,
    required this.obscurePassword,
    required this.isLoading,
    required this.onToggleIdentifierMode,
    required this.onIdentifierChanged,
    required this.onPasswordChanged,
    required this.onTogglePassword,
    required this.onSubmit,
    required this.onCreateAccount,
    required this.onForgotPassword,
    this.identifierServerError,
    this.passwordServerError,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController identifierCtrl;
  final TextEditingController passwordCtrl;
  final bool usePhone;
  final bool obscurePassword;
  final bool isLoading;
  final String? identifierServerError;
  final String? passwordServerError;
  final VoidCallback onToggleIdentifierMode;
  final void Function(String) onIdentifierChanged;
  final void Function(String) onPasswordChanged;
  final VoidCallback onTogglePassword;
  final VoidCallback onSubmit;
  final VoidCallback onCreateAccount;
  final VoidCallback onForgotPassword;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Email / Phone toggle
          Row(
            children: [
              AuthToggleChip(
                label: 'E-mail',
                selected: !usePhone,
                onTap: usePhone ? onToggleIdentifierMode : null,
              ),
              const SizedBox(width: 8),
              AuthToggleChip(
                label: 'Telefone',
                selected: usePhone,
                onTap: !usePhone ? onToggleIdentifierMode : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Identifier field — fades between email and phone variants
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: AuthField(
              key: ValueKey(usePhone),
              controller: identifierCtrl,
              label: usePhone ? 'Telefone (ex: +5511999998888)' : 'E-mail',
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: usePhone
                  ? [FilteringTextInputFormatter.allow(RegExp(r'[+\d]'))]
                  : null,
              serverError: identifierServerError,
              onChanged: onIdentifierChanged,
              validator: usePhone
                  ? (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Informe seu telefone';
                      }
                      final n =
                          v.trim().replaceAll(RegExp(r'[^\+\d]'), '');
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
          const SizedBox(height: 12),
          AuthField(
            controller: passwordCtrl,
            label: 'Senha',
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => onSubmit(),
            serverError: passwordServerError,
            onChanged: onPasswordChanged,
            suffix: AuthVisibilityToggle(
              obscure: obscurePassword,
              onToggle: onTogglePassword,
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Informe a senha';
              if (v.length < 6) return 'Mínimo 6 caracteres';
              return null;
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onForgotPassword,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondaryDark,
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              ),
              child: const Text(
                'Esqueci minha senha',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ),
          const SizedBox(height: 8),
          AuthSubmitButton(
            label: 'Entrar',
            isLoading: isLoading,
            onPressed: onSubmit,
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: onCreateAccount,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.secondary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              child: const Text(
                'Não tem conta? Criar conta',
                style: AppTextStyles.link,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
