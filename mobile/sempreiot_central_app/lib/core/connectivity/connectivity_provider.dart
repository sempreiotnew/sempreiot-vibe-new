import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Raw network interface check (WiFi / mobile / ethernet present).
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final connectivity = Connectivity();
  final initial = await connectivity.checkConnectivity();
  yield initial.any((r) => r != ConnectivityResult.none);
  yield* connectivity.onConnectivityChanged.map(
    (results) => results.any((r) => r != ConnectivityResult.none),
  );
});

enum NetworkStatus {
  /// No network interface detected.
  offline,

  /// Network interface present but MQTT backend unreachable.
  limited,

  /// Fully connected — MQTT session is active.
  online,
}
