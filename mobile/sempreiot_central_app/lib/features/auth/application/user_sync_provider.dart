import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/user_api_service.dart';

final _userApiServiceProvider = Provider<UserApiService>((_) => UserApiService());

/// Runs once per auth session. autoDispose resets it on sign-out so the next
/// sign-in triggers a fresh call. Throws [UserApiException] on non-200/201.
final userSyncProvider = FutureProvider.autoDispose<void>((ref) async {
  await ref.read(_userApiServiceProvider).registerUser();
});
