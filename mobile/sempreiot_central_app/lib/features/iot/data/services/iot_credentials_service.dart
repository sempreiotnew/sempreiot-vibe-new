import 'dart:convert';

import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AwsCredentials {
  final String accessKeyId;
  final String secretAccessKey;
  final String sessionToken;
  final String identityId;
  final String userId; // Cognito User Pool sub — stable, platform-independent primary key

  const AwsCredentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.sessionToken,
    required this.identityId,
    required this.userId,
  });
}

class IotCredentialsService {
  IotCredentialsService({SharedPreferences? prefs}) : _prefs = prefs;

  final SharedPreferences? _prefs;
  static const _forceRefreshAfter = Duration(minutes: 25);
  DateTime? _lastForcedRefresh;

  String? cachedIdentityId(String userId) =>
      _prefs?.getString('iot_identity_id_$userId');

  String? get lastConnectedUserId => _prefs?.getString('iot_last_user_id');

  Future<AwsCredentials> fetch() async {
    final now = DateTime.now();
    final shouldForce = _lastForcedRefresh == null ||
        now.difference(_lastForcedRefresh!) >= _forceRefreshAfter;
    if (shouldForce) _lastForcedRefresh = now;

    final session = await Amplify.Auth.fetchAuthSession(
      options: FetchAuthSessionOptions(forceRefresh: shouldForce),
    ) as CognitoAuthSession;

    final identityId = session.identityIdResult.value;
    final creds = session.credentialsResult.value;
    final userId = session.userPoolTokensResult.value.userId;

    debugPrint('[IoT] ── Credentials AUTH ─────────────────');
    debugPrint('[IoT] User Pool sub : $userId');
    debugPrint('[IoT] Identity ID   : $identityId');
    debugPrint('[IoT] AccessKeyId   : ${creds.accessKeyId}');
    debugPrint('[IoT] isSignedIn: ${session.isSignedIn} ');
    debugPrint('[IoT] ────────────────────────────────────────────');

    _prefs?.setString('iot_identity_id_$userId', identityId);
    _prefs?.setString('iot_last_user_id', userId);

    return AwsCredentials(
      accessKeyId: creds.accessKeyId,
      secretAccessKey: creds.secretAccessKey,
      sessionToken: creds.sessionToken ?? '',
      identityId: identityId,
      userId: userId,
    );
  }

  void reset() => _lastForcedRefresh = null;
}

void debugPrintPreferences(SharedPreferences prefs) {
  final map = {
    for (final key in prefs.getKeys()) key: prefs.get(key),
  };
  debugPrint('[Prefs] ${const JsonEncoder.withIndent('  ').convert(map)}');
}
