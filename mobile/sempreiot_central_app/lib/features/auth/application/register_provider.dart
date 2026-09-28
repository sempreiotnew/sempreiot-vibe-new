import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import '../domain/exceptions/auth_exceptions.dart';
import '../domain/repositories/i_auth_repository.dart';

sealed class RegisterState {
  const RegisterState();
}

final class RegisterIdle extends RegisterState {
  const RegisterIdle();
}

final class RegisterLoading extends RegisterState {
  const RegisterLoading();
}

final class RegisterSuccess extends RegisterState {
  const RegisterSuccess({
    required this.username,
    required this.password,
    required this.isPhone,
    required this.requiresConfirmation,
    required this.displayIdentifier,
  });
  final String username;
  final String password;
  final bool isPhone;
  final bool requiresConfirmation;
  /// Original email or phone (e.g. +5511999998888) — for display only.
  final String displayIdentifier;
}

final class RegisterError extends RegisterState {
  const RegisterError(this.message);
  final String message;
}

final registerNotifierProvider =
    NotifierProvider<RegisterNotifier, RegisterState>(RegisterNotifier.new);

class RegisterNotifier extends Notifier<RegisterState> {
  @override
  RegisterState build() => const RegisterIdle();

  IAuthRepository get _repo => ref.read(authRepositoryProvider);

  Future<void> signUp({
    required String name,
    required String identifier,
    required String password,
    required bool isPhone,
  }) async {
    state = const RegisterLoading();
    try {
      final check = await _repo.checkIdentifierExists(identifier, isPhone: isPhone);

      if (check.exists && check.confirmed) {
        // Distinguish between a confirmed local account and a federated-only
        // account so the user knows how to proceed.
        final String message;
        if (isPhone) {
          message = 'field:identifier:Este número já está cadastrado.';
        } else if (check.hasLocalUser) {
          message = 'field:identifier:E-mail já cadastrado.';
        } else {
          message = 'field:identifier:Este e-mail está vinculado a uma conta Google ou Apple. Faça login pela opção social.';
        }
        state = RegisterError(message);
        return;
      }

      if (check.exists && !check.confirmed) {
        // User registered but never confirmed. Skip signUp() — calling it again
        // throws UsernameExistsException whose resendSignUpCode fallback inside
        // the repository can silently fail (throttling, pool config, etc.) and
        // re-surface as a misleading "already registered" error.
        // Instead, resend the OTP directly and go straight to the OTP screen.
        final username = _cognitoUsername(identifier, isPhone: isPhone);
        await _repo.resendSignUpCode(username: username);
        state = RegisterSuccess(
          username: username,
          password: password,
          isPhone: isPhone,
          requiresConfirmation: true,
          displayIdentifier: identifier,
        );
        return;
      }

      // New user — proceed with normal sign-up.
      final result = await _repo.signUp(
        name: name,
        identifier: identifier,
        password: password,
        isPhone: isPhone,
      );
      state = RegisterSuccess(
        username: result.username,
        password: password,
        isPhone: isPhone,
        requiresConfirmation: !result.isComplete,
        displayIdentifier: identifier,
      );
    } on AuthDomainException catch (e) {
      state = RegisterError(_errorMessage(e, isPhone: isPhone));
    } catch (_) {
      print(_.toString());
      state = const RegisterError('Erro ao criar conta. Tente novamente.');
    }
  }

  /// Mirrors the username derivation in AuthRepositoryImpl.signUp().
  String _cognitoUsername(String identifier, {required bool isPhone}) {
    if (!isPhone) return identifier;
    final digits = identifier.replaceAll(RegExp(r'[^\d]'), '');
    return '$digits@phone.sempreiot';
  }

  void reset() => state = const RegisterIdle();

  String _errorMessage(AuthDomainException e, {required bool isPhone}) =>
      switch (e) {
        IdentifierAlreadyConfirmedException() => isPhone
            ? 'field:identifier:Este número já está cadastrado.'
            : 'field:identifier:Este e-mail já está cadastrado.',
        AuthRateLimitException() =>
          'Muitas tentativas. Aguarde alguns minutos e tente novamente.',
        WeakPasswordException() =>
          'field:password:Senha inválida. Use ao menos 8 caracteres com letras e números.',
        InvalidIdentifierException() => isPhone
            ? 'field:identifier:Telefone inválido. Use o formato: +5511999998888'
            : 'field:identifier:Verifique o e-mail informado.',
        SmsUnavailableException() =>
          'field:identifier:Envio de SMS indisponível. Tente usar e-mail.',
        _ => 'Erro ao criar conta. Tente novamente.',
      };
}
