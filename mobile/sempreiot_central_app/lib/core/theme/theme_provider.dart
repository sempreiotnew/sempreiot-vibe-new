import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../../features/auth/application/auth_provider.dart';

// Pre-loaded in main() before runApp and injected via ProviderScope overrides.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(),
);

final themeProvider = NotifierProvider<_ThemeNotifier, ThemeMode>(
  _ThemeNotifier.new,
);

class _ThemeNotifier extends Notifier<ThemeMode> {
  // Central has one global key. User mode keys by userId so switching
  // accounts loads that account's own preference.
  String _prefsKey() {
    if (AppConfig.isCentral) return 'theme_dark';
    final userId = ref.read(authNotifierProvider).valueOrNull?.userId;
    return userId != null ? 'theme_dark_$userId' : 'theme_dark';
  }

  @override
  ThemeMode build() {
    if (!AppConfig.isCentral) {
      // Re-run build when the signed-in user changes so the correct
      // per-user preference is picked up automatically.
      ref.watch(authNotifierProvider);
    }
    final prefs = ref.read(sharedPreferencesProvider);
    return (prefs.getBool(_prefsKey()) ?? true)
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  void toggle() {
    state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    ref.read(sharedPreferencesProvider).setBool(_prefsKey(), state == ThemeMode.dark);
  }
}
