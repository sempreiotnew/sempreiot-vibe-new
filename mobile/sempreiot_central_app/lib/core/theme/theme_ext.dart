import 'package:flutter/material.dart';

import 'app_colors.dart';

extension ThemeContext on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get bgColor =>
      isDark ? AppColors.backgroundDark : AppColors.backgroundLight;

  Color get surfaceColor =>
      isDark ? AppColors.surfaceDark : AppColors.surfaceLight;

  Color get barColor =>
      isDark ? const Color(0xFF0F1520) : const Color(0xFFFFFFFF);

  Color get borderColor =>
      isDark ? AppColors.divider : const Color(0xFFE5E7EB);

  Color get textPrimary =>
      isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;

  Color get textSecondary =>
      isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
}
