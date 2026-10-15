import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/theme_provider.dart' show sharedPreferencesProvider;

/// Rede's own switches (2026-10-15): what the operator chose to see on the
/// map, kept on this device across restarts. Today: the firmware pill on
/// every unit, on by default — off for a cleaner map when the versions
/// are not the question. "Atualizar dispositivos" ignores it: there the
/// version is the point.
final redeShowVersionsProvider =
    NotifierProvider<RedeShowVersions, bool>(RedeShowVersions.new);

class RedeShowVersions extends Notifier<bool> {
  static const prefsKey = 'rede_show_versions';

  @override
  bool build() => _prefs()?.getBool(prefsKey) ?? true;

  void toggle() => set(!state);

  void set(bool on) {
    state = on;
    _prefs()?.setBool(prefsKey, on);
  }

  /// Null where the app did not load them (a widget test): the switch
  /// then works for the session and is not remembered.
  SharedPreferences? _prefs() {
    try {
      return ref.read(sharedPreferencesProvider);
    } on UnimplementedError {
      return null;
    }
  }
}
