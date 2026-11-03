import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the keep-alive shell around the central is doing.
enum CentralKeepAliveStatus {
  /// Not Android: nothing to do (web, desktop); the links live as long as
  /// the app does.
  unsupported,

  /// Asked Android for the foreground service, no answer yet.
  starting,

  /// The foreground service runs: the process is never cached or frozen
  /// behind a locked screen.
  running,

  /// Android refused the service ([CentralKeepAlive.error] says why). The
  /// central still works while on screen; behind a locked screen it is back
  /// to an ordinary app.
  failed,
}

@immutable
class CentralKeepAlive {
  const CentralKeepAlive({
    required this.status,
    this.batteryExempt,
    this.error,
  });

  final CentralKeepAliveStatus status;

  /// Whether Doze leaves the app alone (set once per tablet by
  /// `tools/prepare_tablet.sh`). Null until Android answered. False means
  /// the network will be cut when the tablet is unplugged with the screen
  /// off, service or not — the fix is the script, never a dialog here.
  final bool? batteryExempt;

  final String? error;

  CentralKeepAlive copyWith({
    CentralKeepAliveStatus? status,
    bool? batteryExempt,
    String? error,
  }) =>
      CentralKeepAlive(
        status: status ?? this.status,
        batteryExempt: batteryExempt ?? this.batteryExempt,
        error: error ?? this.error,
      );
}

/// Keeps the central's process alive behind a locked screen: starts
/// `CentralLinkService` (android/.../CentralLinkService.kt) when the central
/// starts and stops it with the provider. The Flutter engine stays in the
/// same process, so the serial, MQTT and supervision providers run exactly
/// as on screen — this is the shell, not a second pipeline.
///
/// Behind the scenes by design: no permission prompt, no dialog, ever. What
/// it learned is in [state] for the diagnostics and the console log.
class CentralKeepAliveNotifier extends StateNotifier<CentralKeepAlive> {
  CentralKeepAliveNotifier({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName),
        super(const CentralKeepAlive(status: CentralKeepAliveStatus.starting)) {
    _start();
  }

  static const _channelName = 'com.sempreiot.central/keepalive';

  final MethodChannel _channel;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  Future<void> _start() async {
    if (!_supported) {
      state =
          const CentralKeepAlive(status: CentralKeepAliveStatus.unsupported);
      return;
    }
    try {
      await _channel.invokeMethod<bool>('start');
    } on PlatformException catch (e) {
      debugPrint(
          '[KeepAlive] foreground service refused: ${e.code} ${e.message}');
      if (mounted) {
        state = CentralKeepAlive(
          status: CentralKeepAliveStatus.failed,
          error: '${e.code}: ${e.message}',
        );
      }
      return;
    } on MissingPluginException {
      // An engine without MainActivity's channel (tests, a host that is not
      // the central's APK).
      if (mounted) {
        state =
            const CentralKeepAlive(status: CentralKeepAliveStatus.unsupported);
      }
      return;
    }
    await refresh();
  }

  /// Re-reads what Android says: whether the service runs and whether the
  /// tablet was prepared (Doze exemption).
  Future<void> refresh() async {
    if (!_supported || !mounted) return;
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('status');
      if (!mounted || status == null) return;
      final running = status['running'] == true;
      final exempt = status['batteryExempt'] == true;
      state = CentralKeepAlive(
        status: running
            ? CentralKeepAliveStatus.running
            : CentralKeepAliveStatus.failed,
        batteryExempt: exempt,
        error: running ? null : 'service not running',
      );
      debugPrint('[KeepAlive] service ${running ? 'running' : 'NOT running'}; '
          'battery optimisation ${exempt ? 'exempt' : 'NOT exempt — run '
              'tools/prepare_tablet.sh, Doze will cut the network'}');
    } on PlatformException catch (e) {
      debugPrint('[KeepAlive] status failed: ${e.code} ${e.message}');
    } on MissingPluginException {
      if (mounted) {
        state =
            const CentralKeepAlive(status: CentralKeepAliveStatus.unsupported);
      }
    }
  }

  @override
  void dispose() {
    if (_supported) {
      // Best effort: the provider dies with the app in central mode.
      _channel.invokeMethod<void>('stop').catchError((_) {});
    }
    super.dispose();
  }
}

final centralKeepAliveProvider =
    StateNotifierProvider<CentralKeepAliveNotifier, CentralKeepAlive>((ref) {
  return CentralKeepAliveNotifier();
});
