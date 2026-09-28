import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../features/auth/application/auth_provider.dart';

/// Whether the "Status da Central" card renders as a retro digital panel
/// (like the segment displays on old fire alarm centrals) instead of the
/// default card. Persisted exactly like the theme preference: one global
/// key on the Central device, per-user in USER mode.
final statusPanelArcadeProvider =
    NotifierProvider<_StatusPanelArcadeNotifier, bool>(
  _StatusPanelArcadeNotifier.new,
);

class _StatusPanelArcadeNotifier extends Notifier<bool> {
  String _prefsKey() {
    if (AppConfig.isCentral) return 'status_panel_arcade';
    final userId = ref.read(authNotifierProvider).valueOrNull?.userId;
    return userId != null
        ? 'status_panel_arcade_$userId'
        : 'status_panel_arcade';
  }

  @override
  bool build() {
    if (!AppConfig.isCentral) {
      // Re-run build when the signed-in user changes so the correct
      // per-user preference is picked up automatically.
      ref.watch(authNotifierProvider);
    }
    return ref.read(sharedPreferencesProvider).getBool(_prefsKey()) ?? false;
  }

  void toggle() {
    state = !state;
    ref.read(sharedPreferencesProvider).setBool(_prefsKey(), state);
  }
}
