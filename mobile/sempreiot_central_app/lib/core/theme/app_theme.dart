import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  // Dark: the navy brand primary disappears on the near-black background, so
  // anything Material paints with `primary` (focus rings, progress, switches,
  // unstyled buttons) uses the light-blue secondary instead.
  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.backgroundDark,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.secondary,
          onPrimary: AppColors.white,
          secondary: AppColors.secondary,
          surface: AppColors.surfaceDark,
        ),
        filledButtonTheme: _filled,
        outlinedButtonTheme: _outlined(AppColors.textPrimaryDark),
        textButtonTheme: _text(AppColors.secondary),
        useMaterial3: true,
      );

  static ThemeData get light => ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.backgroundLight,
        colorScheme: const ColorScheme.light(
          primary: AppColors.primary,
          secondary: AppColors.secondary,
          surface: AppColors.surfaceLight,
        ),
        filledButtonTheme: _filled,
        outlinedButtonTheme: _outlined(AppColors.textPrimaryLight),
        textButtonTheme: _text(AppColors.primary),
        useMaterial3: true,
      );

  // The buttons every screen gets without a style of its own — the same look
  // as the wizard's (WizardPrimaryButton / WizardSecondaryButton), so a
  // screen never has to pick colours to be readable in both themes. A
  // `styleFrom` on the button (e.g. error red) still wins.
  static final _filled = FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: AppColors.secondary,
      foregroundColor: AppColors.white,
      disabledBackgroundColor: AppColors.secondary.withValues(alpha: 0.3),
      disabledForegroundColor: AppColors.white.withValues(alpha: 0.6),
    ),
  );

  static OutlinedButtonThemeData _outlined(Color fg) => OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          side: BorderSide(
            color: AppColors.secondary.withValues(alpha: 0.5),
            width: 1.2,
          ),
        ),
      );

  static TextButtonThemeData _text(Color fg) =>
      TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: fg));
}
