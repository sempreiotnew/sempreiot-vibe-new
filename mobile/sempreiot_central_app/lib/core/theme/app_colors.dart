import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF152F55);
  static const Color secondary = Color(0xFF5DADE2);

  static const Color backgroundDark = Color(0xFF0B0F1A);
  static const Color surfaceDark = Color(0xFF111827);
  static const Color textPrimaryDark = Color(0xFFFFFFFF);
  static const Color textSecondaryDark = Color(0xFFA1A1AA);

  static const Color backgroundLight = Color(0xFFFFFFFF);
  static const Color surfaceLight = Color(0xFFF5F7FA);
  static const Color textPrimaryLight = Color(0xFF111827);
  static const Color textSecondaryLight = Color(0xFF6B7280);

  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color divider = Color(0xFF1F2937);

  static const Color success = Color(0xFF52B788);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);

  /// Fire-alarm severity scale (SAFR): TROUBLE sits between OK (success)
  /// and ALERT (warning) — a distinct orange so faults never read as alarms.
  static const Color trouble = Color(0xFFE8763A);

  /// The units' LED language (system reference §3.7 row 7.7), reused for the
  /// packets travelling the Rede map so a tap on a unit and its dot on the
  /// tablet tell the same story: blue = a frame was sent, cyan = the tablet's
  /// ACK reached the unit, red = alarm, orange = trouble.
  static const Color ledBlue = Color(0xFF3B82F6);
  static const Color ledCyan = Color(0xFF22D3EE);
}
