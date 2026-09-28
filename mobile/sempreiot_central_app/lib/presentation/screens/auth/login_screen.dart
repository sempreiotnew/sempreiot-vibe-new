import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sempreiot_central_app/presentation/widgets/iot_network_animation.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../features/app/application/app_init_provider.dart';
import '../../../features/auth/application/auth_provider.dart';
import '../main/main_screen.dart';
import '../splash/splash_screen.dart';
import 'forgot_password_screen.dart';
import 'login_modal.dart';
import 'register_screen.dart';

void _showSempreIoTLoginModal(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SempreIoTLoginModal(
      onCreateAccount: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const RegisterScreen()),
      ),
      onForgotPassword: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
      ),
    ),
  );
}

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    final isLoading = authState.isLoading;
    final appInitState = ref.watch(appInitProvider);

    // Show the loading overlay during both phases:
    //   1. Auth in progress (authState.isLoading)
    //   2. Post-auth app initialisation (UserApiService + MQTT) while the user
    //      is authenticated but appInitProvider hasn't returned true yet.
    final isAnyLoading =
        isLoading || (appInitState.isLoading && authState.valueOrNull != null);

    ref.listen(authNotifierProvider, (prev, next) {
      if (next.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.error.toString()),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 6),
          ),
        );
      }
      // When auth just succeeded (OAuth / WebUI flow): push SplashScreen so
      // the user sees the animated splash while UserApiService + MQTT initialise.
      // Only do this when no other route is on top (e.g. the login modal is not
      // open), otherwise the modal handles its own dismissal.
      if (prev?.isLoading == true &&
          !next.isLoading &&
          next.hasValue &&
          next.value != null &&
          !Navigator.of(context).canPop()) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SplashScreen()),
        );
      }
    });

    // Navigate to MainScreen as soon as appInitProvider finishes.
    // This works regardless of whether the Navigator currently holds the live
    // '/' route (fresh install) or a fixed route created by pushAndRemoveUntil
    // (e.g. after a sign-out from MainScreen).
    ref.listen(appInitProvider, (_, next) {
      if (next.valueOrNull == true) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainScreen()),
          (_) => false,
        );
      }
    });

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      body: Stack(
        children: [
          const Positioned.fill(child: IoTNetworkAnimation()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(flex: 2),
                  const _Logo(),
                  const SizedBox(height: 16),
                  const SizedBox(height: 8),
                  const Spacer(flex: 2),
                  const Text(
                    'Escolha como deseja entrar',
                    style: AppTextStyles.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  _SempreIoTButton(
                    onTap: isLoading
                        ? null
                        : () => _showSempreIoTLoginModal(context),
                  ),
                  const SizedBox(height: 16),
                  _SocialButton(
                    onTap: isLoading
                        ? null
                        : () => ref
                            .read(authNotifierProvider.notifier)
                            .signInWithGoogle(),
                    icon: const _GoogleIcon(),
                    label: 'Continuar com Google',
                    backgroundColor: AppColors.white,
                    foregroundColor: AppColors.textPrimaryLight,
                  ),
                  if (kIsWeb ||
                      defaultTargetPlatform != TargetPlatform.android) ...[
                    const SizedBox(height: 16),
                    _SocialButton(
                      onTap: isLoading
                          ? null
                          : () => ref
                              .read(authNotifierProvider.notifier)
                              .signInWithApple(),
                      icon: const Icon(
                        Icons.apple,
                        color: AppColors.white,
                        size: 28,
                      ),
                      label: 'Continuar com Apple',
                      backgroundColor: AppColors.black,
                      foregroundColor: AppColors.white,
                      border: Border.all(color: AppColors.divider),
                    ),
                  ],
                  const Spacer(flex: 1),
                  const _Divider(),
                  const SizedBox(height: 24),
                  _RegisterButton(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const RegisterScreen(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
          if (isAnyLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black45,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

class _GoogleIcon extends StatelessWidget {
  const _GoogleIcon();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/google_icon.png',
      width: 22,
      height: 22,
      fit: BoxFit.contain,
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/logo_no_shadow.png',
      width: 160,
      height: 160,
      fit: BoxFit.contain,
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.onTap,
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    this.border,
  });

  final VoidCallback? onTap;
  final Widget icon;
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.6 : 1.0,
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                const SizedBox(width: 12),
                Text(
                  label,
                  style:
                      AppTextStyles.labelLarge.copyWith(color: foregroundColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: AppColors.divider)),
        SizedBox(width: 16),
        Text('ou', style: AppTextStyles.bodyMedium),
        SizedBox(width: 16),
        Expanded(child: Divider(color: AppColors.divider)),
      ],
    );
  }
}

class _RegisterButton extends StatelessWidget {
  const _RegisterButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.secondary),
          ),
          child: const Center(
            child: Text('Criar uma conta', style: AppTextStyles.labelLarge),
          ),
        ),
      ),
    );
  }
}

class _SempreIoTButton extends StatelessWidget {
  const _SempreIoTButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.6 : 1.0,
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, Color(0xFF1A4A8A)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.secondary.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/logo_no_shadow.png',
                  width: 26,
                  height: 26,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                Text(
                  'Continuar com Sempre IoT',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.white,
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

