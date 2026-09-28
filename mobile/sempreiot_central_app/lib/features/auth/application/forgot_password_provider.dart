import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import '../domain/exceptions/auth_exceptions.dart';
import '../domain/repositories/i_auth_repository.dart';

// ── State ──────────────────────────────────────────────────────────────────

sealed class ForgotPasswordState {
  const ForgotPasswordState();
}

final class ForgotPasswordIdle extends ForgotPasswordState {
  const ForgotPasswordIdle();
}

final class ForgotPasswordSendingCode extends ForgotPasswordState {
  const ForgotPasswordSendingCode();
}

/// Code was sent — the user is now on step 2 (OTP + new password entry).
final class ForgotPasswordCodeSent extends ForgotPasswordState {
  const ForgotPasswordCodeSent({
    required this.username,
    required this.isPhone,
    required this.destination,
    required this.isSms,
  });

  final String username;
  final bool isPhone;
  final String destination;
  final bool isSms;
}

final class ForgotPasswordResending extends ForgotPasswordState {
  const ForgotPasswordResending({
    required this.username,
    required this.isPhone,
    required this.destination,
    required this.isSms,
  });

  final String username;
  final bool isPhone;
  final String destination;
  final bool isSms;
}

final class ForgotPasswordConfirming extends ForgotPasswordState {
  const ForgotPasswordConfirming({
    required this.username,
    required this.isPhone,
    required this.destination,
    required this.isSms,
  });

  final String username;
  final bool isPhone;
  final String destination;
  final bool isSms;
}

final class ForgotPasswordSuccess extends ForgotPasswordState {
  const ForgotPasswordSuccess();
}

final class ForgotPasswordError extends ForgotPasswordState {
  const ForgotPasswordError({
    required this.message,
    this.codeSentData,
  });

  final String message;

  /// If non-null, the error happened on step 2 — restore this state after dismissal.
  final ForgotPasswordCodeSent? codeSentData;
}

// ── Provider ───────────────────────────────────────────────────────────────

final forgotPasswordNotifierProvider =
    NotifierProvider<ForgotPasswordNotifier, ForgotPasswordState>(
        ForgotPasswordNotifier.new);

class ForgotPasswordNotifier extends Notifier<ForgotPasswordState> {
  @override
  ForgotPasswordState build() => const ForgotPasswordIdle();

  IAuthRepository get _repo => ref.read(authRepositoryProvider);

  Future<void> sendCode(String identifier, {required bool isPhone}) async {
    state = const ForgotPasswordSendingCode();
    try {
      final result =
          await _repo.sendPasswordResetCode(identifier, isPhone: isPhone);
      final username = isPhone
          ? '${identifier.replaceAll(RegExp(r'[^\d]'), '')}@phone.sempreiot'
          : identifier;
      state = ForgotPasswordCodeSent(
        username: username,
        isPhone: isPhone,
        destination: result.destination,
        isSms: result.isSms,
      );
    } on AuthDomainException catch (e) {
      state = ForgotPasswordError(message: _sendErrorMessage(e));
    } catch (_) {
      state = const ForgotPasswordError(
          message: 'Não foi possível enviar o código. Tente novamente.');
    }
  }

  Future<void> resendCode({
    required String username,
    required bool isPhone,
    required String displayIdentifier,
  }) async {
    final current = state;
    if (current is! ForgotPasswordCodeSent) return;
    state = ForgotPasswordResending(
      username: current.username,
      isPhone: current.isPhone,
      destination: current.destination,
      isSms: current.isSms,
    );
    try {
      final result = await _repo.sendPasswordResetCode(
        displayIdentifier,
        isPhone: isPhone,
      );
      state = ForgotPasswordCodeSent(
        username: current.username,
        isPhone: current.isPhone,
        destination: result.destination,
        isSms: result.isSms,
      );
    } on AuthDomainException catch (e) {
      state = ForgotPasswordError(
        message: _sendErrorMessage(e),
        codeSentData: ForgotPasswordCodeSent(
          username: current.username,
          isPhone: current.isPhone,
          destination: current.destination,
          isSms: current.isSms,
        ),
      );
    } catch (_) {
      state = ForgotPasswordError(
        message: 'Não foi possível reenviar o código. Tente novamente.',
        codeSentData: ForgotPasswordCodeSent(
          username: current.username,
          isPhone: current.isPhone,
          destination: current.destination,
          isSms: current.isSms,
        ),
      );
    }
  }

  Future<void> confirmReset({
    required String username,
    required String code,
    required String newPassword,
    required ForgotPasswordCodeSent codeSentData,
  }) async {
    state = ForgotPasswordConfirming(
      username: codeSentData.username,
      isPhone: codeSentData.isPhone,
      destination: codeSentData.destination,
      isSms: codeSentData.isSms,
    );
    try {
      await _repo.confirmPasswordReset(
        username: username,
        code: code,
        newPassword: newPassword,
      );
      state = const ForgotPasswordSuccess();
    } on AuthDomainException catch (e) {
      state = ForgotPasswordError(
        message: _confirmErrorMessage(e),
        codeSentData: codeSentData,
      );
    } catch (_) {
      state = ForgotPasswordError(
        message: 'Erro ao redefinir a senha. Tente novamente.',
        codeSentData: codeSentData,
      );
    }
  }

  void restoreAfterError(ForgotPasswordCodeSent? codeSentData) {
    state = codeSentData ?? const ForgotPasswordIdle();
  }

  void reset() => state = const ForgotPasswordIdle();

  String _sendErrorMessage(AuthDomainException e) => switch (e) {
        PasswordResetUserNotFoundException() =>
          'Não encontramos uma conta com esse identificador.',
        SmsUnavailableException() =>
          'Não foi possível enviar o SMS. O número pode não estar habilitado para receber mensagens.',
        InvalidIdentifierException() =>
          'R e-mail ou telefone informado.',
        AuthRateLimitException() =>
          'Muitas tentativas. Aguarde alguns minutos.',
        _ => 'Não foi possível enviar o código. Tente novamente.',
      };

  String _confirmErrorMessage(AuthDomainException e) => switch (e) {
        InvalidOtpCodeException() =>
          'Código incorreto. Verifique e tente novamente.',
        OtpCodeExpiredException() => 'Código expirado. Solicite um novo.',
        WeakPasswordException() =>
          'A senha deve ter ao menos 8 caracteres, uma letra maiúscula e um número.',
        AuthRateLimitException() =>
          'Muitas tentativas. Aguarde alguns minutos.',
        _ => 'Erro ao redefinir a senha. Tente novamente.',
      };
}
