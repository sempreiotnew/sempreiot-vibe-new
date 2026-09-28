import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import '../domain/exceptions/auth_exceptions.dart';

sealed class LoginState {
  const LoginState();
}

final class LoginIdle extends LoginState {
  const LoginIdle();
}

final class LoginLoading extends LoginState {
  const LoginLoading();
}

final class LoginSuccess extends LoginState {
  const LoginSuccess();
}

final class LoginError extends LoginState {
  const LoginError(this.message);
  final String message;
}

final loginNotifierProvider =
    NotifierProvider<LoginNotifier, LoginState>(LoginNotifier.new);

class LoginNotifier extends Notifier<LoginState> {
  @override
  LoginState build() => const LoginIdle();

  Future<void> signIn({
    required String identifier,
    required String password,
    required bool isPhone,
  }) async {
    state = const LoginLoading();
    try {
      await ref.read(authNotifierProvider.notifier).signInWithIdentifier(
            identifier: identifier,
            password: password,
            isPhone: isPhone,
          );
      state = const LoginSuccess();
    } on AuthDomainException catch (e) {
      state = LoginError(_errorMessage(e, isPhone: isPhone));
    } catch (_) {
      state = const LoginError('Erro ao entrar. Tente novamente.');
    }
  }

  void reset() => state = const LoginIdle();

  String _errorMessage(AuthDomainException e, {required bool isPhone}) =>
      switch (e) {
        InvalidCredentialsException() => isPhone
            ? 'field:identifier:Número ou senha incorretos.'
            : 'field:identifier:E-mail ou senha incorretos.',
        AccountNotConfirmedException() => isPhone
            ? 'field:identifier:Número não confirmado. Verifique seu SMS.'
            : 'field:identifier:E-mail não confirmado. Verifique sua caixa de entrada.',
        InvalidIdentifierException() => isPhone
            ? 'field:identifier:Telefone inválido. Use o formato: +5511999998888'
            : 'field:identifier:Verifique o e-mail informado.',
        AuthRateLimitException() =>
          'Muitas tentativas. Aguarde alguns minutos e tente novamente.',
        _ => 'Erro ao entrar. Tente novamente.',
      };
}
