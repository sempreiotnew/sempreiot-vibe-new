/// Domain-level auth exceptions.
///
/// No Amplify or platform imports here. The data layer (AuthRepositoryImpl)
/// is the only place that knows about Amplify exception types — it translates
/// them into these domain types so the application layer stays infrastructure-free.
library;

sealed class AuthDomainException implements Exception {
  const AuthDomainException();
}

// ── Registration ─────────────────────────────────────────────────────────────

/// The identifier (email or phone) already belongs to a confirmed account.
final class IdentifierAlreadyConfirmedException extends AuthDomainException {
  const IdentifierAlreadyConfirmedException();
}

/// Too many sign-up, sign-in, or resend attempts in a short window.
final class AuthRateLimitException extends AuthDomainException {
  const AuthRateLimitException();
}

/// Password does not meet the pool's complexity requirements.
final class WeakPasswordException extends AuthDomainException {
  const WeakPasswordException();
}

/// The email or phone number format is invalid.
final class InvalidIdentifierException extends AuthDomainException {
  const InvalidIdentifierException();
}

/// SMS sending is unavailable (pool not configured or in sandbox mode).
final class SmsUnavailableException extends AuthDomainException {
  const SmsUnavailableException();
}

// ── Sign-in ───────────────────────────────────────────────────────────────────

/// Credentials are wrong, or the account does not exist.
final class InvalidCredentialsException extends AuthDomainException {
  const InvalidCredentialsException();
}

/// The account exists but the user has not confirmed it yet.
final class AccountNotConfirmedException extends AuthDomainException {
  const AccountNotConfirmedException();
}

/// The user cancelled a federated (Google / Apple) sign-in flow.
final class AuthCancelledException extends AuthDomainException {
  const AuthCancelledException();
}

/// The session has expired and requires re-authentication.
final class AuthSessionExpiredException extends AuthDomainException {
  const AuthSessionExpiredException();
}

/// A federated identity shares an email with an existing local
/// (email + password) account — the user must sign in with a password.
final class FederatedEmailConflictException extends AuthDomainException {
  const FederatedEmailConflictException();
  @override
  String toString() =>
      'Este e-mail já possui uma conta. Faça login com e-mail e senha.';
}

// ── OTP / Confirmation ────────────────────────────────────────────────────────

/// The confirmation code does not match.
final class InvalidOtpCodeException extends AuthDomainException {
  const InvalidOtpCodeException();
}

/// The confirmation code has expired.
final class OtpCodeExpiredException extends AuthDomainException {
  const OtpCodeExpiredException();
}

/// The code is no longer usable — the account may already be confirmed.
final class OtpAlreadyUsedException extends AuthDomainException {
  const OtpAlreadyUsedException();
}

// ── Password reset ────────────────────────────────────────────────────────────

/// The account for the given identifier was not found during password reset.
final class PasswordResetUserNotFoundException extends AuthDomainException {
  const PasswordResetUserNotFoundException();
}

// ── Fallback ──────────────────────────────────────────────────────────────────

/// Any error that does not map to a specific domain case.
final class UnknownAuthException extends AuthDomainException {
  const UnknownAuthException();
}
