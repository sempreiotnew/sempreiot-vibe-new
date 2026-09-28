import 'package:flutter/material.dart';

import 'app_colors.dart';

/// One signal scale for the whole product (system reference §3.6.2): the
/// thresholds the survey LEDs use (lifecycle §6, protocol §7.15) and the
/// leaf's bind preference (protocol §12.3). The Rede map paints every link,
/// its dBm label and the sheet's "Sinal" with it.
///
///   ≥ −75 dBm  good   green
///   ≥ −85 dBm  weak   yellow
///   <  −85 dBm  poor   red
const int signalGoodDbm = -75;
const int signalWeakDbm = -85;

enum SignalTier { good, weak, poor, unknown }

SignalTier signalTier(int? rssi) {
  if (rssi == null) return SignalTier.unknown;
  if (rssi >= signalGoodDbm) return SignalTier.good;
  if (rssi >= signalWeakDbm) return SignalTier.weak;
  return SignalTier.poor;
}

Color signalColor(int? rssi) => switch (signalTier(rssi)) {
      SignalTier.good => AppColors.success,
      SignalTier.weak => AppColors.warning,
      SignalTier.poor => AppColors.error,
      SignalTier.unknown => AppColors.secondary,
    };

/// Line and label colour of a link whose far end is a sleeping leaf: the
/// reading is the last wake's, still true but not live, so the map keeps the
/// dBm and drops the colour (protocol §12.2: a sleeping leaf is silent by
/// design; the next frame's parent is only known when it arrives).
Color sleepingLinkColor(bool isDark) =>
    isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
