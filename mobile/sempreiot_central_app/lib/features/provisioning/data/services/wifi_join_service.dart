import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Programmatic join of a device's setup SoftAP (POC-BRIEF.md §6.2),
/// replacing the old "open Wi-Fi settings and join manually" step.
///
/// Android only, via `WifiNetworkSpecifier` (API 29+, no location permission
/// needed) implemented natively in `MainActivity.kt` — no maintained
/// Flutter plugin currently offers bind-and-connect-without-internet
/// semantics for a provisioning SoftAP, so this is a small platform channel
/// per POC-BRIEF §6.2's own suggestion. iOS isn't implemented: POC-BRIEF §0
/// never pins the installer phone's OS, and Apple's equivalent
/// (`NEHotspotConfiguration`) has different semantics (no traffic binding)
/// that would need separate verification on real iOS hardware — out of
/// scope to guess blind. On iOS (or Android < 10, or on any failure), the
/// caller should fall back to [openWifiSettingsManually].
class WifiJoinService {
  static const _channel = MethodChannel('com.sempreiot.central/wifi');

  /// `dart:io`'s `Platform` isn't available when compiled for web — use the
  /// foundation-safe check instead, same pattern as `kIsWeb` elsewhere in
  /// this feature (see `scan_step.dart`).
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Attempts to join [ssid]/[password] and bind this app's traffic to it.
  /// Returns true on success. Throws [WifiJoinUnsupported] when the platform
  /// can't do a programmatic join at all (non-Android, or Android < 10) —
  /// the caller should fall back to manual instructions, not retry.
  static Future<bool> connect({
    required String ssid,
    required String password,
  }) async {
    if (!_isAndroid) {
      throw const WifiJoinUnsupported('Programmatic Wi-Fi join is Android-only');
    }
    try {
      final ok = await _channel.invokeMethod<bool>('connectToSoftAp', {
        'ssid': ssid,
        'password': password,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'UNSUPPORTED_API') {
        throw WifiJoinUnsupported(e.message ?? 'Unsupported Android version');
      }
      debugPrint('[WifiJoin] connect failed: ${e.code} ${e.message}');
      throw WifiJoinFailed(e.code, e.message ?? '');
    }
  }

  /// Unbinds the app from the SoftAP network (call once provisioning is done
  /// or abandoned, so the phone's normal internet routing resumes).
  static Future<void> disconnect() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('disconnectFromSoftAp');
    } on PlatformException catch (e) {
      debugPrint('[WifiJoin] disconnect failed: ${e.code} ${e.message}');
    }
  }

  /// Fallback for iOS / pre-Android-10 / any programmatic failure: open the
  /// OS Wi-Fi settings screen so the installer can join manually.
  static Future<void> openWifiSettingsManually() async {
    await AppSettings.openAppSettings(type: AppSettingsType.wifi);
  }
}

class WifiJoinUnsupported implements Exception {
  const WifiJoinUnsupported(this.message);
  final String message;

  @override
  String toString() => 'WifiJoinUnsupported: $message';
}

/// Android tried the programmatic join and it did not succeed. [code] is the
/// platform-channel error code from MainActivity.kt: `UNAVAILABLE` (the
/// system dialog was dismissed, the SSID was not found in a scan, or the
/// passphrase was rejected) or `TIMEOUT`. Unlike [WifiJoinUnsupported] a
/// retry can succeed, but polling 192.168.4.1 without the join is pointless.
class WifiJoinFailed implements Exception {
  const WifiJoinFailed(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'WifiJoinFailed($code): $message';
}
