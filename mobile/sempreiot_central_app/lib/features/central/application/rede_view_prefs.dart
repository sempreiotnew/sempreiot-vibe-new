import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/theme_provider.dart' show sharedPreferencesProvider;

/// Rede's own switches (2026-10-15): what the operator chose to see on the
/// map, kept on this device across restarts.
///
/// - the firmware pill on every unit, on by default — off for a cleaner
///   map when the versions are not the question. "Atualizar dispositivos"
///   ignores it: there the version is the point;
/// - the radial picture instead of the tree, off by default — the mesh as
///   clusters of dots around the hub, for a network too big to read as
///   rows (`_MeshLayout.radial`).
final redeShowVersionsProvider =
    NotifierProvider<RedeShowVersions, bool>(RedeShowVersions.new);

final redeRadialProvider = NotifierProvider<RedeRadial, bool>(RedeRadial.new);

class RedeShowVersions extends RedeSwitch {
  RedeShowVersions() : super('rede_show_versions', fallback: true);
}

class RedeRadial extends RedeSwitch {
  RedeRadial() : super('rede_radial', fallback: false);
}

/// One remembered on/off of Rede.
abstract class RedeSwitch extends Notifier<bool> {
  RedeSwitch(this.prefsKey, {required this.fallback});

  final String prefsKey;
  final bool fallback;

  @override
  bool build() => _prefs()?.getBool(prefsKey) ?? fallback;

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
