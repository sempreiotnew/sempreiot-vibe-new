import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import '../domain/exceptions/auth_exceptions.dart';
import '../domain/repositories/i_auth_repository.dart';

// ── State ──────────────────────────────────────────────────────────────────

sealed class OtpState {
  const OtpState();
}

final class OtpIdle extends OtpState {
  const OtpIdle();
}

final class OtpLoading extends OtpState {
  const OtpLoading();
}

final class OtpConfirmed extends OtpState {
  const OtpConfirmed();
}

final class OtpResending extends OtpState {
  const OtpResending();
}

final class OtpResendSuccess extends OtpState {
  const OtpResendSuccess();
}

final class OtpError extends OtpState {
  const OtpError(this.message);
  final String message;
}

// ── Provider ───────────────────────────────────────────────────────────────

final otpNotifierProvider =
    NotifierProvider<OtpNotifier, OtpState>(OtpNotifier.new);

class OtpNotifier extends Notifier<OtpState> {
  @override
  OtpState build() => const OtpIdle();

  IAuthRepository get _repo => ref.read(authRepositoryProvider);

  Future<void> confirm({
    required String username,
    required String code,
    required String password,
  }) async {
    state = const OtpLoading();
    try {
      await _repo.confirmSignUp(username: username, code: code);
      // Reuse existing AuthNotifier — it sets auth state which triggers
      // appInitProvider and the registerUser() lambda automatically.
      await ref
          .read(authNotifierProvider.notifier)
          .signInWithEmailPassword(email: username, password: password);
      state = const OtpConfirmed();
    } on AuthDomainException catch (e) {
      state = OtpError(_errorMessage(e));
    } catch (_) {
      state = const OtpError('Erro ao verificar código. Tente novamente.');
    }
  }

  Future<void> resend({required String username}) async {
    state = const OtpResending();
    try {
      await _repo.resendSignUpCode(username: username);
      state = const OtpResendSuccess();
    } on AuthDomainException catch (e) {
      state = OtpError(_errorMessage(e, isResend: true));
    } catch (_) {
      state = const OtpError('Não foi possível reenviar o código. Tente novamente.');
    }
  }

  void reset() => state = const OtpIdle();

  String _errorMessage(AuthDomainException e, {bool isResend = false}) =>
      switch (e) {
        InvalidOtpCodeException() =>
          'Código incorreto. Verifique e tente novamente.',
        OtpCodeExpiredException() => 'Código expirado. Solicite um novo.',
        OtpAlreadyUsedException() =>
          'Este código não pode ser usado. A conta pode já estar confirmada.',
        AuthRateLimitException() =>
          'Muitas tentativas. Aguarde alguns minutos.',
        _ => isResend
            ? 'Não foi possível reenviar o código. Tente novamente.'
            : 'Erro ao verificar código. Tente novamente.',
      };
}
