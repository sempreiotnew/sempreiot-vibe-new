import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'credentials_admin_provider.dart';

sealed class CentralAuthState {
  const CentralAuthState();
}

final class CentralUnauthenticated extends CentralAuthState {
  const CentralUnauthenticated();
}

final class CentralAuthenticated extends CentralAuthState {
  const CentralAuthenticated();
}

final class CentralPinError extends CentralAuthState {
  const CentralPinError(this.message);
  final String message;
}

final centralAuthProvider =
    NotifierProvider<CentralAuthNotifier, CentralAuthState>(
  CentralAuthNotifier.new,
);

class CentralAuthNotifier extends Notifier<CentralAuthState> {
  @override
  CentralAuthState build() => const CentralUnauthenticated();

  /// Validates [pin] against the central's (hashed) unlock PIN — a secret
  /// dedicated to unlocking the screen, separate from the master role PIN —
  /// through the shared rate limiter that locks every PIN gate at once.
  Future<void> verify(String pin) async {
    final creds = ref.read(credentialsAdminProvider);
    final outcome = await creds.verifyUnlockPin(pin);

    state = switch (outcome) {
      VerifyOk() => const CentralAuthenticated(),
      VerifyUnset() => const CentralPinError('PIN não configurado.'),
      VerifyLocked(:final remaining) =>
        CentralPinError('Muitas tentativas. Aguarde ${remaining.inSeconds}s.'),
      VerifyWrong() =>
        const CentralPinError('Código incorreto. Tente novamente.'),
    };
  }

  void reset() => state = const CentralUnauthenticated();
}
