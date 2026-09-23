import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/device_ap_info.dart';
import '../../domain/services/provisioning_crypto.dart';

/// HTTP client for the device's provisioning SoftAP (POC-BRIEF.md §5).
/// A real device answers at http://192.168.4.1 (port 80). During
/// development the `pocs/autoconnect` firmware or the
/// `mocked-device-autoconnect` Node server stand in — point the app at
/// either with --dart-define=DEVICE_AP_URL=http://<host>[:port].
class DeviceApService {
  static const _base = String.fromEnvironment(
    'DEVICE_AP_URL',
    defaultValue: 'http://192.168.4.1',
  );

  /// Short timeout: the SoftAP either answers fast or isn't there.
  static const _timeout = Duration(seconds: 3);

  static Future<DeviceApInfo> fetchInfo() async {
    final res = await http.get(Uri.parse('$_base/info')).timeout(_timeout);
    if (res.statusCode != 200) {
      throw DeviceApException(res.statusCode, res.body);
    }
    return DeviceApInfo.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// POST /identify: `proof = hex(HMAC-SHA256(key = pop, msg = nonce))`.
  /// [nonceHex] comes from the most recent GET /info response.
  static Future<void> identify({
    required String id,
    required String pop,
    required String nonceHex,
  }) async {
    final nonce = _hexDecode(nonceHex);
    final proof = ProvisioningCrypto.proof(pop: pop, nonce: nonce);

    final res = await http
        .post(
          Uri.parse('$_base/identify'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'id': id, 'proof': proof}),
        )
        .timeout(_timeout);
    debugPrint('[DeviceAp] identify ← ${res.statusCode}: ${res.body}');

    if (res.statusCode == 403) throw const ProofMismatchException();
    if (res.statusCode != 200) {
      throw DeviceApException(res.statusCode, res.body);
    }
  }

  /// POST /provision: builds the HKDF/CCM envelope from [nonceHex] (the same
  /// nonce used in /identify — the device keys both off its last /info
  /// nonce) and the installation's `code_json`.
  static Future<void> provision({
    required String id,
    required String pop,
    required String nonceHex,
    required Map<String, dynamic> codeJson,
    required String name,
    required String zone,
  }) async {
    final nonce = _hexDecode(nonceHex);
    final key = ProvisioningCrypto.deriveKey(pop: pop, nonce: nonce);
    final envelope = ProvisioningCrypto.buildEnvelope(
      key: key,
      id: id,
      codeJson: codeJson,
    );

    final res = await http
        .post(
          Uri.parse('$_base/provision'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'envelope': envelope,
            'name': name,
            'zone': zone,
            'epoch': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
          }),
        )
        .timeout(_timeout);
    debugPrint('[DeviceAp] provision ← ${res.statusCode}: ${res.body}');

    if (res.statusCode != 202 && res.statusCode != 200) {
      throw DeviceApException(res.statusCode, res.body);
    }
  }

  /// POST /enroll — board sticker only. Sends the previously-provisioned
  /// nodes of this installation so the board can answer INSTALLATION
  /// (spec §7.10) with the enrolled list.
  static Future<int> enroll(
    List<({String mac, String id, String name, String zone})> devices,
  ) async {
    final res = await http
        .post(
          Uri.parse('$_base/enroll'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode([
            for (final d in devices)
              {'mac': d.mac, 'id': d.id, 'name': d.name, 'zone': d.zone},
          ]),
        )
        .timeout(_timeout);
    debugPrint('[DeviceAp] enroll ← ${res.statusCode}: ${res.body}');
    if (res.statusCode != 200) {
      throw DeviceApException(res.statusCode, res.body);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['count'] as int? ?? 0;
  }

  static Future<DeviceApStatus> fetchStatus() async {
    final res = await http.get(Uri.parse('$_base/status')).timeout(_timeout);
    if (res.statusCode != 200) {
      throw DeviceApException(res.statusCode, res.body);
    }
    return DeviceApStatus.fromMap(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  static Uint8List _hexDecode(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

class ProofMismatchException implements Exception {
  const ProofMismatchException();

  @override
  String toString() => 'ProofMismatchException';
}

class DeviceApException implements Exception {
  const DeviceApException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'DeviceApException($statusCode): $body';
}
