import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'iot_provider.dart';

/// The presence topic for a central — the actual MQTT Last-Will topic, not
/// a made-up name for it. Universally subscribable by any authenticated
/// user via the shared IoT policy's `topicfilter/*/will` grant. In AWS IoT
/// policy resources only `*` is a wildcard (and it matches colons fine);
/// the MQTT wildcards `+`/`#` are treated as literal characters there —
/// which is why every past `+`-based policy attempt failed. The raw
/// identityId (colon and all) is fine in the topic itself.
String presenceTopicFor(String identityId) => '$identityId/will';

/// A central's live online/offline state, read from the retained MQTT
/// Last-Will message on its presence topic. Readable by any authenticated
/// user who knows the central's identityId — no per-relationship grant.
enum PresenceStatus { unknown, online, offline }

/// Full live status a central publishes on its presence topic. The extra
/// fields ride the retained will message because `*/will` is the only topic
/// the shared IoT policy lets every user subscribe to — a separate `/status`
/// topic would need a policy change.
///
/// Payload schema (all keys optional except `status`):
/// `{"status":"online","wifi":"online|limited|offline",
///   "usb":"connected|connecting|error|disconnected",
///   "mesh":"connected|connecting|disconnected","updated_at":ISO8601}`
class CentralLiveStatus {
  const CentralLiveStatus({
    this.presence = PresenceStatus.unknown,
    this.wifi,
    this.usb,
    this.mesh,
    this.updatedAt,
  });

  final PresenceStatus presence;
  final String? wifi;
  final String? usb;

  /// Mesh (internal device network) status — always "disconnected" until
  /// real mesh devices exist.
  final String? mesh;
  final DateTime? updatedAt;
}

final centralLiveStatusProvider =
    Provider.family<CentralLiveStatus, String>((ref, identityId) {
  final msgAsync = ref.watch(iotMessageStreamProvider(presenceTopicFor(identityId)));
  final payload = msgAsync.valueOrNull?.payload;
  if (payload == null) return const CentralLiveStatus();

  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    return CentralLiveStatus(
      presence: (map['status'] as String?) == 'online'
          ? PresenceStatus.online
          : PresenceStatus.offline,
      wifi: map['wifi'] as String?,
      usb: map['usb'] as String?,
      mesh: map['mesh'] as String?,
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? ''),
    );
  } catch (_) {
    return const CentralLiveStatus();
  }
});

final presenceStatusProvider = Provider.family<PresenceStatus, String>((ref, identityId) {
  return ref.watch(centralLiveStatusProvider(identityId)).presence;
});
