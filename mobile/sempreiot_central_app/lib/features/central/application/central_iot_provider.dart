import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../iot/application/presence_provider.dart';
import '../../iot/data/repositories/iot_mqtt_repository_impl.dart';
import '../../iot/domain/entities/mqtt_message_entity.dart';
import '../../iot/domain/repositories/i_iot_mqtt_repository.dart';
import '../data/services/central_credentials_service.dart';
import 'central_mirror_codec.dart';
import 'firmware_release_provider.dart'
    show firmwareCatalogTopic, centralFirmwareCatalogTopic, otaReleaseChannel;

export '../../../core/connectivity/connectivity_provider.dart'
    show NetworkStatus;

/// The central's machine identity: one instance, so the MQTT session and the
/// firmware downloads (release_downloader.dart) share its cached credentials.
final centralCredentialsServiceProvider = Provider<CentralCredentialsService>(
  (ref) => CentralCredentialsService(db: ref.read(appDatabaseProvider)),
);

final centralMqttRepositoryProvider = Provider<IIotMqttRepository>((ref) {
  return IotMqttRepositoryImpl.forCentral(
    credentialsService: ref.read(centralCredentialsServiceProvider),
  );
});

final centralIotConnectionProvider =
    AsyncNotifierProvider<CentralIotConnectionNotifier, bool>(
  CentralIotConnectionNotifier.new,
);

/// Messages others sent to this central (access requests, watch pings).
final centralMqttMessagesProvider = StreamProvider<MqttMessageEntity>((ref) {
  return ref.watch(centralIotConnectionProvider.notifier).messages;
});

class CentralIotConnectionNotifier extends AsyncNotifier<bool> {
  static const _retryInterval = Duration(seconds: 5);

  bool _shouldReconnect = false;
  bool _connecting = false;
  bool _disposed = false;

  final List<StreamSubscription<MqttMessageEntity>> _topicSubs = [];
  final _messagesCtrl = StreamController<MqttMessageEntity>.broadcast();

  Stream<MqttMessageEntity> get messages => _messagesCtrl.stream;

  @override
  Future<bool> build() async {
    _disposed = false;
    _shouldReconnect = true;

    // Connect immediately on startup — the PIN is a UI lock only.
    // The machine MQTT session must run regardless of lock state.
    Future.microtask(_doConnect);

    ref.onDispose(() {
      _disposed = true;
      _shouldReconnect = false;
      _cancelSubs();
      _messagesCtrl.close();
      final repo = ref.read(centralMqttRepositoryProvider);
      // A graceful DISCONNECT discards the Last Will, so viewers would keep
      // seeing the retained "online" forever — publish "offline" explicitly
      // before closing.
      final id = repo.identityId;
      if (id != null && repo.isConnected) {
        try {
          repo.publish(presenceTopicFor(id), '{"status":"offline"}',
              retain: true);
        } catch (_) {}
      }
      repo.disconnect();
    });

    return false;
  }

  void _cancelSubs() {
    for (final s in _topicSubs) {
      s.cancel();
    }
    _topicSubs.clear();
  }

  Future<void> _doConnect() async {
    if (!_shouldReconnect || _connecting) return;
    _connecting = true;
    state = const AsyncLoading();
    try {
      final repo = ref.read(centralMqttRepositoryProvider);
      await repo.connect(
        onDisconnected: _onUnexpectedDisconnect,
        // Retained so a viewer who wasn't connected when this central
        // dropped still sees "offline" the moment they subscribe. Topic
        // must go through presenceTopicFor so it stays in sync with what
        // viewers subscribe to (and with the shared policy's */will grant).
        will: (identityId) => (
          topic: presenceTopicFor(identityId),
          payload: '{"status":"offline"}'
        ),
      );
      if (_disposed) return;

      _cancelSubs();
      final id = repo.identityId;
      if (id != null) {
        // What others send to this central, by name — not `$id/#`, which
        // would also bring back everything the central itself publishes
        // (the mirror's frame batches, several a second):
        //  · `$id/access` — a user asks for access;
        //  · `$id`        — a user's phone is watching (central mirror);
        //  · the firmware catalogs, retained (docs/ota/ota-internet-plan.md):
        //    the one for every central and the one for this central only.
        for (final topic in [
          '$id/access',
          mirrorCommandTopic(id),
          //  · `$id/cmd/+` — a user's command that must say who asks (an
          //    Internet update from a phone): the last level is the user's
          //    Identity ID, which AWS lets only that user publish under.
          mirrorUserCommandFilter(id),
          firmwareCatalogTopic(otaReleaseChannel),
          centralFirmwareCatalogTopic(id),
        ]) {
          _topicSubs.add(repo.subscribe(topic).listen(
            (msg) {
              if (!_messagesCtrl.isClosed) _messagesCtrl.add(msg);
              debugPrint('[Central] ← [${msg.topic}] ${msg.payload}');
            },
            onError: (_) {},
            cancelOnError: false,
          ));
        }
        // Announce presence immediately — retained, so it survives until the
        // will (or a future online/offline publish) replaces it.
        repo.publish(presenceTopicFor(id), '{"status":"online"}', retain: true);
      }

      state = const AsyncData(true);
      debugPrint('[Central] ✓ MQTT connected as ${id ?? "unknown"}');
    } catch (e, st) {
      debugPrint('[Central] ✗ MQTT connection failed: $e');
      if (_disposed) return;
      state = AsyncError(e, st);
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onUnexpectedDisconnect() {
    if (!_shouldReconnect) return;
    debugPrint('[Central] ! MQTT disconnected unexpectedly');
    _cancelSubs();
    state = const AsyncData(false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect) return;
    debugPrint('[Central] reconnecting in ${_retryInterval.inSeconds}s…');
    Future.delayed(_retryInterval, _doConnect);
  }
}
