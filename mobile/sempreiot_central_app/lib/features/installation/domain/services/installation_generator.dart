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

  /// `NET_SSID = "SIOT-<SYSTEM_ID hex4>"` — blueprint §0, closed as lifecycle
  /// §8 (the SSID is derived from SYSTEM_ID, never random).
  static String netSsidFor(int systemId) =>
      'SIOT-${systemId.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  /// A fresh per-phone identifier (never on the wire).
  static String newLocalId() {
    final rng = Random.secure();
    return List.generate(16, (_) => '0123456789abcdef'[rng.nextInt(16)]).join();
  }

  static Installation generate({
    required String displayName,
    List<String> zones = const [],
  }) {
    final rng = Random.secure();

    var systemId = rng.nextInt(0x10000);
    while (systemId == 0) {
      systemId = rng.nextInt(0x10000);
    }

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
      localId: newLocalId(),
      displayName: displayName,
      systemId: systemId,
      netSsid: netSsidFor(systemId),
      netPsk: netPsk,
      safrPskHex: safrPskHex,
      channel: _channels[rng.nextInt(_channels.length)],
      meshId: meshId,
      zones: zones,
      createdAt: DateTime.now().toUtc(),
    );
  }
}
