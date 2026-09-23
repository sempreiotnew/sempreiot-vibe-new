import 'dart:math';

import '../entities/installation.dart';

/// Generates a new Installation code (POC-BRIEF.md §6.1). All values are
/// random per installation — SYSTEM_ID must be nonzero (0 = unprovisioned
/// sentinel, spec §3.1); NET_SSID/PSK and SAFR_PSK are what
/// `code_json` in POST /provision carries (POC-BRIEF §5).
class InstallationGenerator {
  static const _alnum =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// 2.4 GHz non-overlapping channels — matches board/node Kconfig defaults.
  static const _channels = [1, 6, 11];

  static Installation generate({
    required String displayName,
    List<String> zones = const [],
  }) {
    final rng = Random.secure();

    var systemId = rng.nextInt(0x10000);
    while (systemId == 0) {
      systemId = rng.nextInt(0x10000);
    }

    final ssidSuffix = List.generate(
      4,
      (_) => '0123456789ABCDEF'[rng.nextInt(16)],
    ).join();

    final netPsk = List.generate(16, (_) => _alnum[rng.nextInt(_alnum.length)])
        .join();

    final safrPskBytes = List.generate(16, (_) => rng.nextInt(256));
    final safrPskHex =
        safrPskBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    // Small integer per POC-BRIEF §6.1 "MESH_LITE_ID derived"; low byte of
    // SYSTEM_ID keeps it deterministic from the same generation and inside
    // whatever small range Mesh-Lite's mesh-ID Kconfig expects.
    final meshId = (systemId & 0xFF) == 0 ? 1 : (systemId & 0xFF);

    return Installation(
      localId: List.generate(
        16,
        (_) => '0123456789abcdef'[rng.nextInt(16)],
      ).join(),
      displayName: displayName,
      systemId: systemId,
      netSsid: 'SIOT-$ssidSuffix',
      netPsk: netPsk,
      safrPskHex: safrPskHex,
      channel: _channels[rng.nextInt(_channels.length)],
      meshId: meshId,
      zones: zones,
      createdAt: DateTime.now().toUtc(),
    );
  }
}
