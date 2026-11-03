import 'package:flutter/widgets.dart';

/// Calls [onResume] every time the app comes back to the foreground (the
/// screen unlocked, the task brought back). Returns null where there is no
/// widgets binding — plain Dart tests that build providers without one — so
/// a provider can hook the lifecycle without caring where it runs.
AppLifecycleListener? onAppResumed(VoidCallback onResume) {
  try {
    return AppLifecycleListener(onResume: onResume);
  } catch (_) {
    return null;
  }
}
