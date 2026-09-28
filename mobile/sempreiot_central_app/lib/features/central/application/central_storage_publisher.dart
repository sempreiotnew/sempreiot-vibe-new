import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/utils/mqtt_log.dart';
import '../../storage/application/remote_storage_provider.dart';
import '../../storage/application/storage_provider.dart';
import '../../storage/domain/entities/storage_volume.dart';
import 'central_iot_provider.dart';

/// Central mode only: keeps a retained storage snapshot published on this
/// central's `/storage` topic, so users viewing it (remoteStorageProvider)
/// see its real disk usage.
///
/// Rides storageProvider's own 30s poll (no second read loop) and publishes
/// ONLY when a user-visible value changes — the rounded percent or the
/// formatted used/free/total strings (~100MB granularity) — so background
/// byte churn never costs a message. A manual refresh on the central's own
/// storage screen flows through the same provider and publishes on the same
/// condition. If a change happens while disconnected, the reconnect listener
/// catches it up.
///
/// Must stay watched while the app runs (MainScreen watches it).
final centralStoragePublisherProvider = Provider<void>((ref) {
  if (!AppConfig.isCentral) return;

  StorageVolume? lastPublished;

  bool sameDisplay(StorageVolume a, StorageVolume b) =>
      a.percentUsed == b.percentUsed &&
      a.formattedUsed == b.formattedUsed &&
      a.formattedAvailable == b.formattedAvailable &&
      a.formattedTotal == b.formattedTotal &&
      a.label == b.label;

  void maybePublish(StorageVolume volume) {
    if (lastPublished != null && sameDisplay(volume, lastPublished!)) return;

    final repo = ref.read(centralMqttRepositoryProvider);
    final id = repo.identityId;
    if (id == null || !repo.isConnected) return;

    final payload = jsonEncode({
      'label': volume.label,
      'totalBytes': volume.totalBytes,
      'availableBytes': volume.availableBytes,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    try {
      repo.publish(storageTopicFor(id), payload, retain: true);
      lastPublished = volume;
      MqttLog.event('storage snapshot published (${volume.formattedUsed} used)',
          tag: 'Central');
    } catch (e) {
      MqttLog.event('storage publish failed: $e', tag: 'Central');
    }
  }

  ref.listen(storageProvider, (_, next) {
    final volume = next.valueOrNull;
    if (volume != null) maybePublish(volume);
  }, fireImmediately: true);

  // Catches up after a reconnect if a change happened while offline (the
  // publish above is skipped when disconnected and lastPublished stays
  // stale, so this re-check is a no-op when nothing changed).
  ref.listen(centralIotConnectionProvider, (_, next) {
    if (next.valueOrNull != true) return;
    final volume = ref.read(storageProvider).valueOrNull;
    if (volume != null) maybePublish(volume);
  });
});
