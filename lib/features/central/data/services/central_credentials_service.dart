import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../../../../core/database/app_database.dart';
import '../../../iot/data/services/iot_credentials_service.dart';

/// Authenticates the Central device as its own machine user via direct Cognito
/// HTTP calls — completely independent of the human user's Amplify session.
/// Credentials are read from the [AppDatabase] `iot` metadata row, provisioned
/// via the FACTORY dart-define on first boot.
class CentralCredentialsService extends IotCredentialsService {
  CentralCredentialsService({required AppDatabase db}) : _db = db;

  final AppDatabase _db;
  String? _idToken;
  String? _cognitoSub;
  DateTime? _idTokenExpiry;
  AwsCredentials? _cachedCreds;
  DateTime? _credsExpiry;

  @override
  Future<AwsCredentials> fetch() async {
    final now = DateTime.now();
    if (_cachedCreds != null &&
        _credsExpiry != null &&
        now.isBefore(_credsExpiry!.subtract(const Duration(minutes: 5)))) {
      return _cachedCreds!;
    }
    final idToken = await _getIdToken();
    return _exchangeForAwsCredentials(idToken);
  }

  /// Returns the cached Cognito ID token, refreshing if needed.
  /// Used by REST API calls that need a JWT bearer token.
  Future<String> getIdToken() => _getIdToken();

  @override
  void reset() {
    _idToken = null;
    _cognitoSub = null;
    _idTokenExpiry = null;
    _cachedCreds = null;
    _credsExpiry = null;
  }

  Future<String> _getIdToken() async {
    final now = DateTime.now();
    if (_idToken != null &&
        _idTokenExpiry != null &&
        now.isBefore(_idTokenExpiry!.subtract(const Duration(minutes: 5)))) {
      return _idToken!;
    }

    final iotRaw = await _db.getMeta('iot');
    final iotMap = iotRaw != null
        ? jsonDecode(iotRaw) as Map<String, dynamic>
        : <String, dynamic>{};
    final username = iotMap['iot_client_id'] as String? ?? '';
    final password = iotMap['iot_password'] as String? ?? '';

    if (username.isEmpty || password.isEmpty) {
      throw Exception(
        '[Central] IoT credentials not provisioned — '
        'run with FACTORY dart-define containing an "iot" key',
      );
    }

    final region = dotenv.env['AWS_REGION']!;
    final clientId = dotenv.env['AWS_COGNITO_CLIENT_ID']!;

    final res = await http.post(
      Uri.parse('https://cognito-idp.$region.amazonaws.com/'),
      headers: {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth',
      },
      body: utf8.encode(jsonEncode({
        'AuthFlow': 'USER_PASSWORD_AUTH',
        'ClientId': clientId,
        'AuthParameters': {
          'USERNAME': username,
          'PASSWORD': password,
        },
      })),
    );

    if (res.statusCode != 200) {
      throw Exception(
          '[Central] Cognito auth failed (${res.statusCode}): ${res.body}');
    }

    final parsed = jsonDecode(res.body) as Map<String, dynamic>;
    if (parsed.containsKey('ChallengeName')) {
      throw Exception(
        '[Central] Cognito returned challenge: ${parsed['ChallengeName']} — '
        'set a permanent password for the machine user in the Cognito console',
      );
    }
    final result = parsed['AuthenticationResult'] as Map<String, dynamic>;

    _idToken = result['IdToken'] as String;
    _cognitoSub = _extractSub(_idToken!);
    final expiresIn = (result['ExpiresIn'] as int?) ?? 3600;
    _idTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

    debugPrint('[Central] Cognito auth OK — sub: $_cognitoSub');
    return _idToken!;
  }

  Future<AwsCredentials> _exchangeForAwsCredentials(String idToken) async {
    final region = dotenv.env['AWS_REGION']!;
    final identityPoolId = dotenv.env['AWS_COGNITO_IDENTITY_POOL_ID']!;
    final poolId = dotenv.env['AWS_COGNITO_POOL_ID']!;

    final logins = {'cognito-idp.$region.amazonaws.com/$poolId': idToken};

    // GetId — resolves the stable Identity Pool identity for this machine user.
    final getIdRes = await http.post(
      Uri.parse('https://cognito-identity.$region.amazonaws.com/'),
      headers: {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityService.GetId',
      },
      body: utf8.encode(
          jsonEncode({'IdentityPoolId': identityPoolId, 'Logins': logins})),
    );

    if (getIdRes.statusCode != 200) {
      throw Exception(
          '[Central] GetId failed (${getIdRes.statusCode}): ${getIdRes.body}');
    }

    final identityId = (jsonDecode(getIdRes.body)
        as Map<String, dynamic>)['IdentityId'] as String;

    // GetCredentialsForIdentity — temporary AWS credentials.
    final getCredsRes = await http.post(
      Uri.parse('https://cognito-identity.$region.amazonaws.com/'),
      headers: {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityService.GetCredentialsForIdentity',
      },
      body:
          utf8.encode(jsonEncode({'IdentityId': identityId, 'Logins': logins})),
    );

    if (getCredsRes.statusCode != 200) {
      throw Exception(
          '[Central] GetCredentials failed (${getCredsRes.statusCode}): ${getCredsRes.body}');
    }

    final body = jsonDecode(getCredsRes.body) as Map<String, dynamic>;
    final c = body['Credentials'] as Map<String, dynamic>;

    final expirationEpoch = c['Expiration'];
    _credsExpiry = expirationEpoch != null
        ? DateTime.fromMillisecondsSinceEpoch(
            (expirationEpoch as num).toInt() * 1000,
            isUtc: true,
          )
        : DateTime.now().toUtc().add(const Duration(hours: 1));

    _cachedCreds = AwsCredentials(
      accessKeyId: c['AccessKeyId'] as String,
      secretAccessKey: c['SecretKey'] as String,
      sessionToken: c['SessionToken'] as String,
      identityId: identityId,
      userId: _cognitoSub ?? 'central-123456789',
    );

    debugPrint(
        '[Central] AWS credentials OK — identityId: $identityId, expires: $_credsExpiry');
    return _cachedCreds!;
  }

  // Decode JWT payload without signature verification — token came from Cognito directly.
  static String _extractSub(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) throw const FormatException('Invalid JWT');
    var payload = parts[1];
    switch (payload.length % 4) {
      case 2:
        payload += '==';
      case 3:
        payload += '=';
    }
    final map = jsonDecode(utf8.decode(base64Url.decode(payload)))
        as Map<String, dynamic>;
    return map['sub'] as String;
  }
}
