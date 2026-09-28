import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../data/repositories/iot_mqtt_repository_impl.dart';
import '../domain/entities/mqtt_message_entity.dart';
import '../domain/repositories/i_iot_mqtt_repository.dart';

final iotMqttRepositoryProvider = Provider<IIotMqttRepository>((_) {
  return IotMqttRepositoryImpl();
});

final iotConnectionProvider =
    AsyncNotifierProvider<IotConnectionNotifier, bool>(
  IotConnectionNotifier.new,
);

class IotConnectionNotifier extends AsyncNotifier<bool> {
  static const _retryInterval = Duration(seconds: 5);
  bool _shouldReconnect = false;
  bool _connecting = false;
  bool _disposed = false;

  @override
  Future<bool> build() async {
    _disposed = false;
    // Stop reconnecting if the auth layer signs the user out.
    ref.listen(authNotifierProvider, (_, next) {
      if (next is AsyncData && next.value == null) {
        _shouldReconnect = false;
        ref.read(iotMqttRepositoryProvider).disconnect();
      }
    });
    ref.onDispose(() {
      _disposed = true;
      _shouldReconnect = false;
      ref.read(iotMqttRepositoryProvider).disconnect();
    });
    return false;
  }

  Future<void> connect() async {
    _shouldReconnect = true;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (!_shouldReconnect || _connecting) return;
    _connecting = true;
    state = const AsyncLoading();
    try {
      final repo = ref.read(iotMqttRepositoryProvider);
      await repo.connect(onDisconnected: _onUnexpectedDisconnect);
      // connect() returns immediately (without opening a new socket) when the
      // singleton repo is already connected from a previous hot restart. Either
      // way, after connect() returns we own the disconnect callback and can
      // treat the connection as ours.
      if (_disposed) return;
      state = const AsyncData(true);
      debugPrint('[IoT] ✓ connected');

      ref.invalidate(iotMessageStreamProvider);

      final id = repo.identityId;
      if (id != null) {
        repo.subscribe('$id/#').listen(
          (msg) => debugPrint('[IoT] ← [${msg.topic}]: ${msg.payload}'),
          onError: (e) => debugPrint('[IoT] own-topic subscription error: $e'),
          onDone: () => debugPrint('[IoT] own-topic subscription stream closed'),
        );
      }
    } on SessionExpiredException {
      // Refresh token has expired — stop retrying. AuthNotifier's background
      // timer will detect this on its next tick and sign the user out.
      debugPrint('[IoT] session expired — stopping reconnect');
      _shouldReconnect = false;
      if (!_disposed) state = const AsyncData(false);
    } catch (e, st) {
      debugPrint('[IoT] ✗ connection failed: $e');
      if (_disposed) return;
      state = AsyncError(e, st);
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onUnexpectedDisconnect() {
    if (!_shouldReconnect) return;
    debugPrint('[IoT] ! disconnected unexpectedly');
    state = const AsyncData(false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect) return;
    
    debugPrint('[IoT] reconnecting in ${_retryInterval.inSeconds}s…');
    Future.delayed(_retryInterval, _doConnect);
  }

  void disconnect() {
    _shouldReconnect = false;
    ref.read(iotMqttRepositoryProvider).disconnect();
    state = const AsyncData(false);
    debugPrint('[IoT] manually disconnected');
  }
}

// Usage: ref.watch(iotMessageStreamProvider('my/topic'))
final iotMessageStreamProvider =
    StreamProvider.family<MqttMessageEntity, String>((ref, topic) {
  final repo = ref.watch(iotMqttRepositoryProvider);
  if (!repo.isConnected) {
    return const Stream.empty();
  }
  debugPrint('[IoT] stream provider subscribing to: $topic');
  return repo.subscribe(topic);
});
