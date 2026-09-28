import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../../auth/data/services/user_api_service.dart';
import '../../iot/application/iot_provider.dart';

export '../../auth/domain/exceptions/auth_exceptions.dart' show FederatedEmailConflictException;

/// Runs the full startup sequence once and returns true when the app is ready:
///   1. Wait for Cognito auth check
///   2. Sync user to the backend API
///   3. Open MQTT connection
///
/// Returns false when unauthenticated. Re-runs on sign-in / sign-out because
/// it watches [authNotifierProvider].
final appInitProvider = FutureProvider<bool>((ref) async {
  final user = await ref.watch(authNotifierProvider.future);
  if (user == null) return false;

  try {
    await UserApiService().registerUser();
  } on UserApiException catch (e) {
    await ref.read(authNotifierProvider.notifier).signOut();
    if (e.statusCode == 409) {
      throw const FederatedEmailConflictException();
    }
    return false;
  } catch (e) {
    await ref.read(authNotifierProvider.notifier).signOut();
    return false;
  }

  await ref.read(iotConnectionProvider.notifier).connect();
  return true;
});
