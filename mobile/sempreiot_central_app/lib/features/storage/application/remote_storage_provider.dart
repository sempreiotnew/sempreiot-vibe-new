import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../iot/application/iot_provider.dart';
import '../domain/entities/storage_volume.dart';

/// Topic where a central publishes its retained storage snapshot. Requires
/// the shared IoT policy to grant `topicfilter/*/storage` / `topic/*/storage`
/// — same `*` wildcard pattern as the `*/will` grant (see presenceTopicFor).
String storageTopicFor(String identityId) => '$identityId/storage';

/// A central's storage snapshot, read from the retained MQTT message on its
/// storage topic. Dedicated topic (instead of riding `/will`) so the retained
/// data survives the central going offline — the Last-Will publish would
/// otherwise wipe it.
class RemoteStorage {
  const RemoteStorage({required this.volume, this.updatedAt});

  final StorageVolume volume;
  final DateTime? updatedAt;
}

/// Payload schema:
/// `{"label":"...","totalBytes":N,"availableBytes":N,"updated_at":ISO8601}`
///
/// Null until the retained message arrives (or on a malformed payload).
final remoteStorageProvider =
    Provider.family<RemoteStorage?, String>((ref, identityId) {
  final msgAsync =
      ref.watch(iotMessageStreamProvider(storageTopicFor(identityId)));
  final payload = msgAsync.valueOrNull?.payload;
  if (payload == null) return null;

  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    return RemoteStorage(
      volume: StorageVolume(
        label: map['label'] as String? ?? 'Armazenamento Interno',
        totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
        availableBytes: (map['availableBytes'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? ''),
    );
  } catch (_) {
    return null;
  }
});
