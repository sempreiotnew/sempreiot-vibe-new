import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/auth_repository_impl.dart';
import '../domain/entities/auth_user_entity.dart';
import '../domain/exceptions/auth_exceptions.dart';
import '../domain/repositories/i_auth_repository.dart';

export '../domain/exceptions/auth_exceptions.dart' show FederatedEmailConflictException;

final authRepositoryProvider = Provider<IAuthRepository>(
  (_) => AuthRepositoryImpl(),
);

final authNotifierProvider =
    AsyncNotifierProvider<AuthNotifier, AuthUserEntity?>(AuthNotifier.new);

class AuthNotifier extends AsyncNotifier<AuthUserEntity?> {
  @override
  Future<AuthUserEntity?> build() async {
    final user = await ref.read(authRepositoryProvider).getCurrentUser();
    if (user != null) _startRefreshTimer();
    return user;
  }

  // Keeps the access token alive in the background.
  // Fires every 20 min — well before even the minimum Cognito access token
  // expiry (which can be as low as 5 min, and is commonly set to 30 min).
  // If the refresh token itself has expired (30-day default), signs out.
  void _startRefreshTimer() {
    final timer = Timer.periodic(const Duration(minutes: 20), (_) async {
      try {
        await ref.read(authRepositoryProvider).refreshToken();
        debugPrint('[Auth] token refreshed silently');
      } on AuthSessionExpiredException {
        debugPrint('[Auth] refresh token expired — signing out');
        signOut();
      } catch (e) {
        debugPrint('[Auth] token refresh failed (will retry): $e');
      }
    });
    ref.onDispose(timer.cancel);
  }

  Future<void> signInWithGoogle() => _signInFederated(
        () => ref.read(authRepositoryProvider).signInWithGoogle(),
      );

  Future<void> signInWithApple() => _signInFederated(
        () => ref.read(authRepositoryProvider).signInWithApple(),
      );

  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) =>
      _signIn(
        () => ref.read(authRepositoryProvider).signInWithEmailPassword(
              email: email,
              password: password,
            ),
      );

  // Unlike _signIn this rethrows so callers (e.g. LoginNotifier) can map
  // errors to field-level messages before updating their own state.
  Future<void> signInWithIdentifier({
    required String identifier,
    required String password,
    required bool isPhone,
  }) async {
    try {
      await ref.read(authRepositoryProvider).signInWithIdentifier(
            identifier: identifier,
            password: password,
            isPhone: isPhone,
          );
      final user = await ref.read(authRepositoryProvider).getCurrentUser();
      state = AsyncData(user);
      if (user != null) _startRefreshTimer();
    } on AuthDomainException {
      // Expected login failures (wrong password, unconfirmed, rate limit, etc.)
      // are handled by the calling provider (LoginNotifier). Don't surface them
      // as AsyncError on the auth state — that would trigger the global error
      // snackbar on the login screen with a raw type name.
      rethrow;
    } catch (e, st) {
      // Truly unexpected infrastructure error — surface it globally.
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    await ref.read(authRepositoryProvider).signOut();
    // Always update state. OAuth (Hosted UI) sign-out causes a page reload
    // anyway so the double-render is harmless; email/password sign-out on web
    // has no redirect and requires this update to propagate to dependents
    // (IoT disconnect, appInitProvider, etc.).
    state = const AsyncData(null);
  }

  Future<void> _signInFederated(Future<void> Function() signInFn) async {
    state = const AsyncLoading();
    try {
      await signInFn();
      final repo = ref.read(authRepositoryProvider);
      final email = await repo.getSignedInEmail();
      if (email != null) {
        final check = await repo.checkIdentifierExists(email, isPhone: false);
        if (check.hasLocalUser) {
          await repo.signOut();
          throw const FederatedEmailConflictException();
        }
      }
      final user = await repo.getCurrentUser();
      state = AsyncData(user);
      if (user != null) _startRefreshTimer();
    } on AuthCancelledException {
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> _signIn(Future<void> Function() signInFn) async {
    state = const AsyncLoading();
    try {
      await signInFn();
      final user = await ref.read(authRepositoryProvider).getCurrentUser();
      state = AsyncData(user);
      if (user != null) _startRefreshTimer();
    } on AuthCancelledException {
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}
