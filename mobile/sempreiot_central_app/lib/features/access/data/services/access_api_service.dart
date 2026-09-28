import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class AccessApiService {
  static const _base = 'https://api.sempreiot.com';

  /// Every relationship row (pending/accepted/rejected/blocked) for [userSubId].
  static Future<List<Map<String, dynamic>>> getRequestsForUser({
    required String userSubId,
    required Future<String> Function() getToken,
  }) =>
      _get(queryParameters: {'userSubId': userSubId}, getToken: getToken);

  /// Every relationship row (pending/accepted/rejected/blocked) for
  /// [centralIdentityId] — used by the central to sync its local list on
  /// connect/reconnect instead of relying purely on live MQTT.
  static Future<List<Map<String, dynamic>>> getAllForCentral({
    required String centralIdentityId,
    required Future<String> Function() getToken,
  }) =>
      _get(queryParameters: {'centralIdentityId': centralIdentityId}, getToken: getToken);

  // Note: the GET route in API Gateway is `/access/requests`, not
  // `/access/resolve` (that path is POST-only, wired to _post below). Hitting
  // `/access/resolve` with GET 404s at the API Gateway level before it ever
  // reaches the Lambda — silently, since the caller's try/catch just saw an
  // empty list back. That's what made every backend resync a no-op.
  static Future<List<Map<String, dynamic>>> _get({
    required Map<String, String> queryParameters,
    required Future<String> Function() getToken,
  }) async {
    final token = await getToken();
    final uri = Uri.parse('$_base/access/requests').replace(queryParameters: queryParameters);

    debugPrint('[Access] GET $uri');
    final res = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
    debugPrint('[Access] ← ${res.statusCode}: ${res.body}');

    if (res.statusCode != 200) {
      throw AccessApiException(res.statusCode, res.body);
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Called by the central to accept or reject a pending access request.
  /// Accepting always grants LEVEL_1 — no PIN required.
  static Future<void> resolve({
    required String centralIdentityId,
    required String userSubId,
    required String decision, // 'ACCEPTED' | 'REJECTED'
    required String centralId,
    required Future<String> Function() getToken,
  }) =>
      _post(
        action: 'RESOLVE',
        body: {
          'centralIdentityId': centralIdentityId,
          'userSubId': userSubId,
          'decision': decision,
          'centralId': centralId,
        },
        getToken: getToken,
      );

  /// Changes an already-accepted user's level. The PIN for [level] (or the
  /// root credentials for MASTER operations) is verified locally on the
  /// central device before this is called. [masterRemoval] must be set when
  /// demoting the MASTER user — the backend refuses to touch a MASTER
  /// relation without it.
  static Future<void> changeLevel({
    required String centralIdentityId,
    required String userSubId,
    required String level, // AccessLevel.wireValue
    required String centralId,
    required Future<String> Function() getToken,
    bool masterRemoval = false,
  }) =>
      _post(
        action: 'LEVEL_CHANGE',
        body: {
          'centralIdentityId': centralIdentityId,
          'userSubId': userSubId,
          'level': level,
          'centralId': centralId,
          if (masterRemoval) 'masterRemoval': true,
        },
        getToken: getToken,
      );

  /// Blocks a user — future requests from them are silently dropped, and any
  /// live MQTT access they had is revoked immediately.
  static Future<void> block({
    required String centralIdentityId,
    required String userSubId,
    required String centralId,
    required Future<String> Function() getToken,
  }) =>
      _post(
        action: 'BLOCK',
        body: {
          'centralIdentityId': centralIdentityId,
          'userSubId': userSubId,
          'centralId': centralId,
        },
        getToken: getToken,
      );

  /// Unblocks a user — they can request access again, but aren't
  /// automatically reconnected.
  static Future<void> unblock({
    required String centralIdentityId,
    required String userSubId,
    required Future<String> Function() getToken,
  }) =>
      _post(
        action: 'UNBLOCK',
        body: {
          'centralIdentityId': centralIdentityId,
          'userSubId': userSubId,
        },
        getToken: getToken,
      );

  static Future<void> _post({
    required String action,
    required Map<String, dynamic> body,
    required Future<String> Function() getToken,
  }) async {
    final token = await getToken();
    final uri = Uri.parse('$_base/access/resolve');
    final encoded = jsonEncode({'action': action, ...body});

    debugPrint('[Access] POST $uri — action: $action, body: $encoded');
    final res = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: encoded,
    );
    debugPrint('[Access] ← ${res.statusCode}: ${res.body}');

    if (res.statusCode != 200) {
      throw AccessApiException(res.statusCode, res.body);
    }
  }
}

class AccessApiException implements Exception {
  const AccessApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'AccessApiException($statusCode): $body';
}
