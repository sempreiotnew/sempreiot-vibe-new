import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class SigV4Signer {
  /// Builds a presigned WSS URL for AWS IoT MQTT over WebSocket.
  /// Implements SigV4 manually to avoid library quirks with IoT's endpoint.
  static String buildSignedWebSocketUrl({
    required String host,
    required String region,
    required String accessKeyId,
    required String secretAccessKey,
    required String sessionToken,
  }) {
    const service = 'iotdevicegateway';
    const path = '/mqtt';

    final now = DateTime.now().toUtc();
    final date = _yyyymmdd(now);
    final datetime = '${date}T${_hhmmss(now)}Z';

    final credentialScope = '$date/$region/$service/aws4_request';

    // AWS IoT MQTT-over-WebSocket signing:
    // The session token is NOT included in the canonical (signed) query string.
    // It is appended AFTER the signature. This is the pattern used by all
    // official AWS IoT SDKs and differs from generic SigV4.
    final canonicalQueryString = [
      'X-Amz-Algorithm=AWS4-HMAC-SHA256',
      'X-Amz-Credential=${_enc('$accessKeyId/$credentialScope')}',
      'X-Amz-Date=$datetime',
      'X-Amz-Expires=86400',
      'X-Amz-SignedHeaders=host',
    ].join('&');

    final canonicalRequest = [
      'GET',
      path,
      canonicalQueryString,
      'host:$host\n', // canonical headers block (trailing \n required)
      'host', // signed headers
      // SHA-256 of empty body
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    ].join('\n');

    final stringToSign = [
      'AWS4-HMAC-SHA256',
      datetime,
      credentialScope,
      _sha256hex(canonicalRequest),
    ].join('\n');

    final signingKey = _deriveKey(secretAccessKey, date, region, service);
    final signature = _hmacHex(signingKey, stringToSign);

    // Append signature, then session token (token is unsigned — IoT requirement)
    final suffix = sessionToken.isNotEmpty
        ? '&X-Amz-Signature=$signature&X-Amz-Security-Token=${_enc(sessionToken)}'
        : '&X-Amz-Signature=$signature';

    final wsUrl = 'wss://$host$path?$canonicalQueryString$suffix';
    debugPrint('[IoT] Signed URL (first 120): ${wsUrl.substring(0, wsUrl.length.clamp(0, 120))}...');
    return wsUrl;
  }

  // ── SigV4 helpers ─────────────────────────────────────────────────────────

  static List<int> _deriveKey(
      String secret, String date, String region, String service) {
    final kDate = _hmacBytes(utf8.encode('AWS4$secret'), date);
    final kRegion = _hmacBytes(kDate, region);
    final kService = _hmacBytes(kRegion, service);
    return _hmacBytes(kService, 'aws4_request');
  }

  static String _hmacHex(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).toString();

  static List<int> _hmacBytes(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _sha256hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  /// SigV4 URI encoding: percent-encode everything except A-Z a-z 0-9 - _ . ~
  static String _enc(String input) {
    final buf = StringBuffer();
    for (final byte in utf8.encode(input)) {
      final ch = String.fromCharCode(byte);
      if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(ch)) {
        buf.write(ch);
      } else {
        buf.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return buf.toString();
  }

  static String _yyyymmdd(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}'
      '${dt.month.toString().padLeft(2, '0')}'
      '${dt.day.toString().padLeft(2, '0')}';

  static String _hhmmss(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}'
      '${dt.minute.toString().padLeft(2, '0')}'
      '${dt.second.toString().padLeft(2, '0')}';
}
