import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_flutter/amplify_flutter.dart' hide InvalidCredentialsException;
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../../domain/entities/auth_user_entity.dart';
import '../../domain/entities/sign_up_result.dart' show AuthSignUpResult;
import '../../domain/exceptions/auth_exceptions.dart';
import '../../domain/repositories/i_auth_repository.dart';

final class AuthRepositoryImpl implements IAuthRepository {
  @override
  Future<AuthUserEntity?> getCurrentUser() async {
    try {
      final user = await Amplify.Auth.getCurrentUser();
      return AuthUserEntity(userId: user.userId);
    } on SignedOutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    try {
      await Amplify.Auth.signInWithWebUI(
        provider: AuthProvider.google,
        options: const SignInWithWebUIOptions(
          pluginOptions: CognitoSignInWithWebUIPluginOptions(
            prompt: [CognitoSignInWithWebUIPrompt.selectAccount],
          ),
        ),
      );
    } on UserCancelledException {
      throw const AuthCancelledException();
    } catch (_) {
      throw const UnknownAuthException();
    }
  }

  @override
  Future<void> signInWithApple() async {
    try {
      await Amplify.Auth.signInWithWebUI(
        provider: AuthProvider.apple,
        options: const SignInWithWebUIOptions(
          pluginOptions: CognitoSignInWithWebUIPluginOptions(
            prompt: [CognitoSignInWithWebUIPrompt.selectAccount],
          ),
        ),
      );
    } on UserCancelledException {
      throw const AuthCancelledException();
    } catch (_) {
      throw const UnknownAuthException();
    }
  }

  @override
  Future<void> signOut() async {
    await Amplify.Auth.signOut();
  }

  @override
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) =>
      _performSignIn(email, password);

  @override
  Future<void> signInWithIdentifier({
    required String identifier,
    required String password,
    required bool isPhone,
  }) {
    final String username;
    if (isPhone) {
      final digits = identifier.replaceAll(RegExp(r'[^\d]'), '');
      username = '$digits@phone.sempreiot';
    } else {
      username = identifier;
    }
    return _performSignIn(username, password);
  }

  Future<void> _performSignIn(String username, String password) async {
    try {
      final result = await Amplify.Auth.signIn(username: username, password: password);
      // Amplify v2 catches UserNotConfirmedException internally and returns a
      // successful SignInResult with isSignedIn=false instead of rethrowing.
      // We must check the result to detect this case.
      if (!result.isSignedIn) {
        switch (result.nextStep.signInStep) {
          case AuthSignInStep.confirmSignUp:
            throw const AccountNotConfirmedException();
          case AuthSignInStep.resetPassword:
          default:
            throw const UnknownAuthException();
        }
      }
    } on AuthDomainException {
      rethrow;
    } on AuthNotAuthorizedException {
      throw const InvalidCredentialsException();
    } on UserNotFoundException {
      throw const InvalidCredentialsException();
    } on UserNotConfirmedException {
      // Defensive catch — Amplify v2 rarely surfaces this but kept for safety.
      throw const AccountNotConfirmedException();
    } on InvalidParameterException {
      throw const InvalidIdentifierException();
    } on LimitExceededException {
      throw const AuthRateLimitException();
    } on TooManyRequestsException {
      throw const AuthRateLimitException();
    } catch (_) {
      throw const UnknownAuthException();
    }
  }

  @override
  Future<AuthSignUpResult> signUp({
    required String name,
    required String identifier,
    required String password,
    required bool isPhone,
  }) async {
    final attrs = <AuthUserAttributeKey, String>{
      AuthUserAttributeKey.name: name,
    };
    // Cognito requires the username to be an email. For phone users we derive
    // a synthetic email from the digits so it's reproducible across sign-in.
    final String username;
    if (isPhone) {
      attrs[AuthUserAttributeKey.phoneNumber] = identifier;
      final digits = identifier.replaceAll(RegExp(r'[^\d]'), '');
      username = '$digits@phone.sempreiot';
    } else {
      attrs[AuthUserAttributeKey.email] = identifier;
      username = identifier;
    }
    try {
      final result = await Amplify.Auth.signUp(
        username: username,
        password: password,
        options: SignUpOptions(userAttributes: attrs),
      );
      return AuthSignUpResult(
        username: username,
        isComplete: result.isSignUpComplete,
      );
    } on UsernameExistsException {
      // The app's check-email Lambda queries the user DB, which is only
      // populated by handleRegisterUser after confirmation. An unconfirmed
      // user won't be in that DB, so the Lambda returns exists=false and
      // register_provider falls through to signUp(). Try resending the OTP —
      // if it works the user is unconfirmed and can resume the flow. If it
      // fails (rate-limited, already confirmed) surface the appropriate error.
      try {
        await Amplify.Auth.resendSignUpCode(username: username);
        return AuthSignUpResult(username: username, isComplete: false);
      } on LimitExceededException {
        throw const AuthRateLimitException();
      } on TooManyRequestsException {
        throw const AuthRateLimitException();
      } catch (_) {
        throw const IdentifierAlreadyConfirmedException();
      }
    } on AliasExistsException {
      throw const IdentifierAlreadyConfirmedException();
    } on InvalidPasswordException {
      throw const WeakPasswordException();
    } on InvalidParameterException {
      throw const InvalidIdentifierException();
    } on LimitExceededException {
      throw const AuthRateLimitException();
    } on TooManyRequestsException {
      throw const AuthRateLimitException();
    } on CodeDeliveryFailureException {
      throw const SmsUnavailableException();
    } catch (_) {
      throw const UnknownAuthException();
    }
  }

  @override
  Future<void> confirmSignUp({
    required String username,
    required String code,
  }) async {
    try {
      await Amplify.Auth.confirmSignUp(
        username: username,
        confirmationCode: code,
      );
    } on CodeMismatchException {
      throw const InvalidOtpCodeException();
    } on ExpiredCodeException {
      throw const OtpCodeExpiredException();
    } on AuthNotAuthorizedException {
      // Cognito returns NotAuthorizedException when the account is already
      // confirmed — the code is no longer usable.
      throw const OtpAlreadyUsedException();
    } on LimitExceededException {
      throw const AuthRateLimitException();
    } on TooManyRequestsException {
      throw const AuthRateLimitException();
    } catch (_) {
      throw const UnknownAuthException();
    }
  }

  @override
  Future<void> resendSignUpCode({required String username}) async {
    try {
      await Amplify.Auth.resendSignUpCode(username: username);
    } on LimitExceededException {
      throw const AuthRateLimitException();
    } on TooManyRequestsException {
      throw const AuthRateLimitException();
    } on CodeDeliveryFailureException {
      throw const SmsUnavailableException();
    } on AuthNotAuthorizedException {
      throw const OtpAlreadyUsedException();
    } catch (e, st) {
      safePrint('resendSignUpCode unknown error: $e\n$st');
      throw const UnknownAuthException();
    }
  }

  @override
  Future<({String destination, bool isSms})> sendPasswordResetCode(
    String identifier, {
    required bool isPhone,
  }) async {
    final username = isPhone
        ? '${identifier.replaceAll(RegExp(r'[^\d]'), '')}@phone.sempreiot'
        : identifier;
    try {
      final result = await Amplify.Auth.resetPassword(username: username);
      final details = result.nextStep.codeDeliveryDetails;
      final destination = details?.destination ?? identifier;
      final isSms = details?.deliveryMedium != DeliveryMedium.email;
      return (destination: destination, isSms: isSms);
    } on UserNotFoundException {
      throw const PasswordResetUserNotFoundException();
    } on CodeDeliveryFailureException {
      throw const SmsUnavailableException();
    } on InvalidParameterException {
      throw const InvalidIdentifierException();
    } on LimitExceededException {
      throw const AuthRateLimitException();
    } on TooManyRequestsException {
      throw const AuthRateLimitException();
    } catch (_) {
      throw const UnknownAuthException();
    }
  }

  @override
  Future<void> confirmPasswordReset({
    required String username,
    required String code,
    required String newPassword,
  }) async {
    try {
      await Amplify.Auth.confirmResetPassword(
        username: username,
        newPassword: newPassword,
        confirmationCode: code,
      );
    } on CodeMismatchException {
      throw const InvalidOtpCodeException();
    } on ExpiredCodeException {
      throw const OtpCodeExpiredException();
    } on InvalidPasswordException {
      throw const WeakPasswordException();
    } on AuthNotAuthorizedException {
      throw const InvalidOtpCodeException();
    } on LimitExceededException {
      throw const AuthRateLimitException();
    } on TooManyRequestsException {
      throw const AuthRateLimitException();
    } catch (_) {
      throw const UnknownAuthException();
    }
  }

  @override
  Future<void> refreshToken() async {
    try {
      await Amplify.Auth.fetchAuthSession(
        options: const FetchAuthSessionOptions(forceRefresh: true),
      );
    } on SessionExpiredException {
      throw const AuthSessionExpiredException();
    }
    // Other errors (network, etc.) are transient — the caller's timer will
    // retry. Surfacing them as UnknownAuthException would sign out the user
    // on a temporary connectivity blip.
  }

  @override
  Future<({bool exists, bool confirmed, bool hasLocalUser})> checkIdentifierExists(
    String identifier, {
    required bool isPhone,
  }) async {
    final String queryParam;
    if (isPhone) {
      final digits = identifier.replaceAll(RegExp(r'[^\d+]'), '');
      final phone = digits.startsWith('+') ? digits : '+$digits';
      queryParam = 'phone=${Uri.encodeComponent(phone)}';
    } else {
      queryParam = 'email=${Uri.encodeComponent(identifier)}';
    }

    final uri = Uri.parse('https://api.sempreiot.com/user/check-email?$queryParam');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      return (exists: false, confirmed: false, hasLocalUser: false);
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (
      exists: data['exists'] == true,
      confirmed: data['confirmed'] == true,
      hasLocalUser: data['hasLocalUser'] == true,
    );
  }

  @override
  Future<String?> getSignedInEmail() async {
    try {
      final session = await Amplify.Auth.fetchAuthSession() as CognitoAuthSession;
      final idToken = session.userPoolTokensResult.value.idToken;
      return idToken.claims.customClaims['email'] as String?;
    } catch (_) {
      return null;
    }
  }
}
