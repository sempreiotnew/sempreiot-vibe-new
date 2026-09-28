import '../entities/auth_user_entity.dart';
import '../entities/sign_up_result.dart';

abstract interface class IAuthRepository {
  Future<AuthUserEntity?> getCurrentUser();
  Future<void> signInWithGoogle();
  Future<void> signInWithApple();
  Future<void> signOut();
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  });

  Future<void> signInWithIdentifier({
    required String identifier,
    required String password,
    required bool isPhone,
  });

  Future<AuthSignUpResult> signUp({
    required String name,
    required String identifier,
    required String password,
    required bool isPhone,
  });

  Future<void> confirmSignUp({
    required String username,
    required String code,
  });

  Future<void> resendSignUpCode({
    required String username,
  });

  Future<({bool exists, bool confirmed, bool hasLocalUser})> checkIdentifierExists(
    String identifier, {
    required bool isPhone,
  });

  Future<String?> getSignedInEmail();

  /// Silently refreshes the Cognito access token.
  /// Throws [AuthSessionExpiredException] if the refresh token has expired.
  Future<void> refreshToken();

  /// Sends a password reset code to the user's verified contact.
  /// Returns the masked destination and whether delivery was via SMS.
  Future<({String destination, bool isSms})> sendPasswordResetCode(
    String identifier, {
    required bool isPhone,
  });

  /// Confirms a password reset using the code the user received.
  Future<void> confirmPasswordReset({
    required String username,
    required String code,
    required String newPassword,
  });
}
