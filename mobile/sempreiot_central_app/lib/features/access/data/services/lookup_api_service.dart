import 'dart:convert';

import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/lookup_result.dart';

class LookupApiService {
  static const _base = 'https://api.sempreiot.com';

  /// Look up a subId in Device (type=central) or User (type=user) table.
  /// Uses the current Amplify session JWT for authentication.
  static Future<LookupResult> lookup(String subId, {String? type}) =>
      _get({'subId': subId, if (type != null) 'type': type});

  /// Reverse lookup by the central's identityId — used to rebuild the
  /// saved-centrals list from backend relation rows, which only carry the
  /// identityId.
  static Future<LookupResult> lookupByIdentityId(String identityId) =>
      _get({'identityId': identityId});

  static Future<LookupResult> _get(Map<String, String> params) async {
    final session =
        await Amplify.Auth.fetchAuthSession() as CognitoAuthSession;
    final token =
        session.userPoolTokensResult.value.idToken.raw;

    final uri = Uri.parse('$_base/lookup').replace(queryParameters: params);

    debugPrint('[Lookup] GET $uri');
    final res = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
    debugPrint('[Lookup] ← ${res.statusCode}: ${res.body}');

    if (res.statusCode == 404) throw const LookupNotFoundException();
    if (res.statusCode != 200) {
      throw LookupApiException(res.statusCode, res.body);
    }

    return LookupResult.fromMap(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }
}

class LookupNotFoundException implements Exception {
  const LookupNotFoundException();

  @override
  String toString() => 'LookupNotFoundException: ID not found';
}

class LookupApiException implements Exception {
  const LookupApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'LookupApiException($statusCode): $body';
}
