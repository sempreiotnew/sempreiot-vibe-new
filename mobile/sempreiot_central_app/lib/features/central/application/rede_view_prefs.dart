import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/theme_provider.dart' show sharedPreferencesProvider;

/// Rede's own switches (2026-10-15): what the operator chose to see on the
/// map, kept on this device across restarts.
///
/// - the type icon on every unit — the moon of a sleeping battery unit,
///   the plug of an AC one —, on by default; off for a cleaner map
///   (2026-11-19; until then this switch was the firmware pills, which
///   Rede no longer draws: the version is on "Atualizar dispositivos");
/// - which picture the map is ([RedeLayout]): the tree, top to bottom, by
///   default; the same tree left to right (2026-11-19); or the radial
///   picture — the mesh as clusters of dots around the hub, for a network
///   too big to read as rows (`_MeshLayout.balloon`).
final redeShowTypeIconsProvider =
    NotifierProvider<RedeShowTypeIcons, bool>(RedeShowTypeIcons.new);

final redeLayoutProvider =
    NotifierProvider<RedeLayoutChoice, RedeLayout>(RedeLayoutChoice.new);

/// The picture Rede's map is drawn as.
enum RedeLayout {
  /// The tree, the CENTRAL on top and each layer a row under it.
  tree,

  /// The same tree turned on its side: the CENTRAL on the left and each
  /// layer a column to its right.
  treeHorizontal,

  /// Clusters of dots around the hub.
  radial;

  bool get isRadial => this == RedeLayout.radial;
  bool get isHorizontal => this == RedeLayout.treeHorizontal;
}

class RedeShowTypeIcons extends RedeSwitch {
  RedeShowTypeIcons() : super('rede_show_type_icons', fallback: true);
}

/// The remembered picture, kept by name under `rede_layout`. Nothing
/// chosen yet: the vertical tree — the older tree / radial switch
/// (`rede_radial`) is no longer read.
class RedeLayoutChoice extends Notifier<RedeLayout> {
  static const prefsKey = 'rede_layout';

  @override
  RedeLayout build() {
    final prefs = _prefsOf(ref);
    final saved = prefs?.getString(prefsKey);
    for (final l in RedeLayout.values) {
      if (l.name == saved) return l;
    }
    return RedeLayout.tree;
  }

  void set(RedeLayout layout) {
    state = layout;
    _prefsOf(ref)?.setString(prefsKey, layout.name);
  }
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

  SharedPreferences? _prefs() => _prefsOf(ref);
}

/// Null where the app did not load them (a widget test): the choice then
/// works for the session and is not remembered.
SharedPreferences? _prefsOf(Ref ref) {
  try {
    return ref.read(sharedPreferencesProvider);
  } on UnimplementedError {
    return null;
  }
}
