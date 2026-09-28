import 'package:flutter/material.dart';

/// The 5 access tiers a central can grant a user.
///
/// Levels 1-4 are each gated by a per-central PIN stored (hashed) in the
/// central's local database (`credentials.level_pins`, provisioned via
/// FACTORY and managed under PINs de Acesso). Granting MASTER requires the
/// root + senha device-ownership credentials instead, and there is only
/// ever one MASTER user per central. None of these secrets leave the
/// device — grants happen locally, at the central.
enum AccessLevel {
  level1,
  level2,
  level3,
  level4,
  master;

  String get wireValue => switch (this) {
        AccessLevel.level1 => 'LEVEL_1',
        AccessLevel.level2 => 'LEVEL_2',
        AccessLevel.level3 => 'LEVEL_3',
        AccessLevel.level4 => 'LEVEL_4',
        AccessLevel.master => 'MASTER',
      };

  static AccessLevel? fromWire(String? value) => switch (value) {
        'LEVEL_1' => AccessLevel.level1,
        'LEVEL_2' => AccessLevel.level2,
        'LEVEL_3' => AccessLevel.level3,
        'LEVEL_4' => AccessLevel.level4,
        'MASTER' => AccessLevel.master,
        _ => null,
      };

  String get label => switch (this) {
        AccessLevel.level1 => 'Visualizador',
        AccessLevel.level2 => 'Operador',
        AccessLevel.level3 => 'Técnico',
        AccessLevel.level4 => 'Administrador',
        AccessLevel.master => 'Master',
      };

  /// Short badge text, e.g. for compact chips.
  String get shortLabel => switch (this) {
        AccessLevel.level1 => 'NÍVEL 1',
        AccessLevel.level2 => 'NÍVEL 2',
        AccessLevel.level3 => 'NÍVEL 3',
        AccessLevel.level4 => 'NÍVEL 4',
        AccessLevel.master => 'MASTER',
      };

  Color get color => switch (this) {
        AccessLevel.level1 => const Color(0xFF6B7280),
        AccessLevel.level2 => const Color(0xFF10B981),
        AccessLevel.level3 => const Color(0xFF3B82F6),
        AccessLevel.level4 => const Color(0xFFF59E0B),
        AccessLevel.master => const Color(0xFFEF4444),
      };

  IconData get icon => switch (this) {
        AccessLevel.level1 => Icons.visibility_outlined,
        AccessLevel.level2 => Icons.touch_app_outlined,
        AccessLevel.level3 => Icons.build_outlined,
        AccessLevel.level4 => Icons.admin_panel_settings_outlined,
        AccessLevel.master => Icons.shield_rounded,
      };
}
