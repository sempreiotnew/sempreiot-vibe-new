import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../../features/central/application/central_iot_provider.dart';
import '../../features/iot/application/iot_provider.dart';
import 'connectivity_provider.dart';

export 'connectivity_provider.dart' show NetworkStatus;

/// Single source of truth for network+MQTT status in both app and Central modes.
///
/// In Central mode watches [centralIotConnectionProvider]; otherwise watches
/// [iotConnectionProvider]. Consumers never need to branch on [AppConfig.isCentral].
final networkStatusProvider = Provider<NetworkStatus>((ref) {
  final connState = ref.watch(connectivityProvider);
  if (connState.isLoading) return NetworkStatus.online;

  final hasInterface = connState.valueOrNull ?? false;
  if (!hasInterface) return NetworkStatus.offline;

  final iotState = AppConfig.isCentral
      ? ref.watch(centralIotConnectionProvider)
      : ref.watch(iotConnectionProvider);

  if (iotState.valueOrNull == true) return NetworkStatus.online;
  if (iotState.hasError || iotState.valueOrNull == false) return NetworkStatus.limited;
  return NetworkStatus.online;
});
