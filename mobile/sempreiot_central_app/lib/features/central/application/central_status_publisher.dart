import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/connectivity/network_status_provider.dart';
import '../../../core/utils/mqtt_log.dart';
import '../../iot/application/presence_provider.dart';
import 'central_iot_provider.dart';
import 'serial_link_provider.dart';
import 'supervision_provider.dart';

/// What the retained presence payload should currently say. Timestamp-free
/// so it only changes (and only triggers a publish) when the reported
/// state really changes. USB is the protocol-driven link state (valid SAFR
/// traffic), mesh follows the root node's supervision freshness.
final _statusSnapshotProvider =
    Provider<({bool ready, String wifi, String usb, String mesh})>((ref) {
  return (
    ready: ref.watch(centralIotConnectionProvider).valueOrNull ?? false,
    wifi: ref.watch(networkStatusProvider).name,
    usb: ref.watch(serialLinkProvider).name,
    mesh: ref.watch(meshLinkStateProvider),
  );
});

/// Central mode only: keeps the retained presence payload in sync with the
/// central's live Wi-Fi and USB state, so users watching
/// [centralLiveStatusProvider] see this central's real status instead of
/// their own phone's connectivity.
///
/// Publishes on a trailing debounce and always reads the state at publish
/// time: bursts like USB `connecting → connected` collapse into a single
/// publish of the final state, so a stale intermediate value can never be
/// what ends up retained on the broker.
///
/// Must stay watched while the app runs (MainScreen watches it). The data
/// rides the will topic — see [CentralLiveStatus] for why.
final centralStatusPublisherProvider = Provider<void>((ref) {
  if (!AppConfig.isCentral) return;

  Timer? debounce;

  void publishNow() {
    final snap = ref.read(_statusSnapshotProvider);
    if (!snap.ready) {
      MqttLog.event('status publish skipped — MQTT not connected',
          tag: 'Central');
      return;
    }
    final repo = ref.read(centralMqttRepositoryProvider);
    final id = repo.identityId;
    if (id == null || !repo.isConnected) return;

    final payload = jsonEncode({
      'status': 'online',
      'wifi': snap.wifi,
      'usb': snap.usb,
      'mesh': snap.mesh,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    try {
      repo.publish(presenceTopicFor(id), payload, retain: true);
    } catch (e) {
      MqttLog.event('status publish failed: $e', tag: 'Central');
    }
  }

  void schedule() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 400), publishNow);
  }

  ref.listen(_statusSnapshotProvider, (prev, next) {
    MqttLog.event('status changed $prev → $next — publishing in 400ms',
        tag: 'Central');
    schedule();
  });
  schedule();

  ref.onDispose(() => debounce?.cancel());
});
