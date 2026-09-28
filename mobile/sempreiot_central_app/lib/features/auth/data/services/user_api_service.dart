import 'dart:convert';

import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class UserApiService {
  static const _endpoint = 'https://api.sempreiot.com/user';

  Future<void> registerUser() async {
    debugPrint('[UserAPI] ── registerUser ────────────────────────');

    final session = await Amplify.Auth.fetchAuthSession() as CognitoAuthSession;
    final idToken = session.userPoolTokensResult.value.idToken;
    final rawToken = idToken.raw;

    // Extract email and phone directly from the ID token claims — avoids
    // a fetchUserAttributes() call that requires the cognito:user.admin scope.
    // Non-standard claims (email, phone_number) are in customClaims.
    final name = idToken.claims.customClaims['name'] as String? ?? '';
    final email = idToken.claims.customClaims['email'] as String? ?? '';
    final phone = idToken.claims.customClaims['phone_number'] as String? ?? '';
    final identityId = session.identityIdResult.value;

    debugPrint('[UserAPI] claims — email: $email, phone: $phone');
    debugPrint('[UserAPI] identityId: $identityId');

    final body = jsonEncode({
      'subId': session.userPoolTokensResult.value.userId,
      'identityId': identityId,
      'email': email,
      'name': name,
    });
    debugPrint('[UserAPI] POST $_endpoint');
    debugPrint('[UserAPI] body: $body');

    final response = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Authorization': 'Bearer $rawToken',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    debugPrint('[UserAPI] ← ${response.statusCode}');
    debugPrint('[UserAPI] response body: ${response.body}');
    debugPrint('[UserAPI] ─────────────────────────────────────────');

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw UserApiException(response.statusCode, response.body);
    }
  }
}

class UserApiException implements Exception {
  const UserApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'UserApiException($statusCode): $body';
}
