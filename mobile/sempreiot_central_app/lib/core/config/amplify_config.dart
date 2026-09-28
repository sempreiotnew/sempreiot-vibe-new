import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

String buildAmplifyConfig() {
  final region = dotenv.env['AWS_REGION']!;
  final poolId = dotenv.env['AWS_COGNITO_POOL_ID']!;
  final clientId = dotenv.env['AWS_COGNITO_CLIENT_ID']!;
  final identityPoolId = dotenv.env['AWS_COGNITO_IDENTITY_POOL_ID']!;
  final webDomain = dotenv.env['AWS_COGNITO_DOMAIN']!
      .replaceAll('https://', '')
      .replaceAll('http://', '');

  // Cognito requires an exact match for redirect_uri — sending a comma-joined
  // list as a single value causes invalid_request. Use only the URI for the
  // current platform so Amplify sends exactly one value to Cognito.
  //
  // Amplify's callback matcher checks: registeredUri.startsWith(callbackBase).
  // Browsers normalise root URLs to include a trailing slash, so the registered
  // URI must end with '/' for the startsWith check to pass on web.
  final webRedirectRaw = dotenv.env['AWS_COGNITO_WEB_REDIRECT_URI']!;
  final webRedirect =
      webRedirectRaw.endsWith('/') ? webRedirectRaw : '$webRedirectRaw/';

  final redirectUri =
      kIsWeb ? webRedirect : dotenv.env['AWS_COGNITO_REDIRECT_URI']!;

  
  return '''
{
  "UserAgent": "aws-amplify-cli/2.0",
  "Version": "1.0",
  "auth": {
    "plugins": {
      "awsCognitoAuthPlugin": {
        "UserAgent": "aws-amplify-cli/2.0",
        "Version": "1.0",
        "CredentialsProvider": {
          "CognitoIdentity": {
            "Default": {
              "PoolId": "$identityPoolId",
              "Region": "$region"
            }
          }
        },
        "CognitoUserPool": {
          "Default": {
            "PoolId": "$poolId",
            "AppClientId": "$clientId",
            "Region": "$region"
          }
        },
        "Auth": {
          "Default": {
            "authenticationFlowType": "USER_SRP_AUTH",
            "OAuth": {
              "WebDomain": "$webDomain",
              "AppClientId": "$clientId",
              "SignInRedirectURI": "$redirectUri",
              "SignOutRedirectURI": "$redirectUri",
              "Scopes": ["openid", "email"]
            }
          }
        }
      }
    }
  }
}
''';
}
