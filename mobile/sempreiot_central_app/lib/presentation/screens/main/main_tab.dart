import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';

enum MainTab {
  principal,
  central,
  centrais,
  devices,
  rede;

  /// Central mode has no "Central" tab: the tablet IS the central, and
  /// its settings live in the drawer.
  static List<MainTab> get tabs =>
      AppConfig.isCentral ? [principal, devices, rede] : [principal, centrais];

  /// USER mode drilling into a specific central: the reduced set of tabs
  /// a viewer can navigate inside that central.
  static List<MainTab> get centralDetailTabs => [principal, devices, central];

  String get label => switch (this) {
        MainTab.principal => 'Principal',
        MainTab.central => 'Central',
        MainTab.centrais => 'Centrais',
        MainTab.devices => 'Dispositivos',
        MainTab.rede => 'Rede',
      };

  IconData get icon => switch (this) {
        MainTab.principal => Icons.home_rounded,
        MainTab.central => Icons.sensors_rounded,
        MainTab.centrais => Icons.hub_rounded,
        MainTab.devices => Icons.devices_rounded,
        MainTab.rede => Icons.hub_rounded,
      };
}
