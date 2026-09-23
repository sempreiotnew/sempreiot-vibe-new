import 'dart:typed_data';

import 'safr_crypto.dart';
import 'safr_v2_frame.dart';

/// The (SYSTEM_ID, SAFR_PSK) pair the central authenticates frames with
/// (docs/safr/protocol-safr-v3.md §3.1/§4). One per installation: the phone
/// generates both when it creates the installation and hands them to every
/// unit via /provision; the central must be given the same pair (it never
/// arrives over USB — POC-BRIEF §4.2).
class SafrIdentity {
  const SafrIdentity({required this.systemId, required this.key});

  /// Bench default: the development SYSTEM_ID/PSK compiled into the firmware
  /// before provisioning existed. Used until an installation is imported.
  static final dev = SafrIdentity(systemId: safrDevSystemId, key: safrDevPsk);

  final int systemId;
  final Uint8List key;

  bool get isDev => identical(this, dev);

  /// Parses the installation's `safr_psk_hex` (32 hex chars). Returns null
  /// when the string is not exactly 16 bytes of hex.
  static Uint8List? keyFromHex(String hex) {
    final clean = hex.trim();
    if (clean.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final b = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }
}
