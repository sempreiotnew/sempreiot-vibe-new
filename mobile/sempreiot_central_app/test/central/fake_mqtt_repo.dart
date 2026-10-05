import 'dart:async';

import 'package:sempreiot_central_app/features/iot/domain/entities/mqtt_message_entity.dart';
import 'package:sempreiot_central_app/features/iot/domain/repositories/i_iot_mqtt_repository.dart';

/// A user's MQTT session for the central-mirror tests: records what is
/// published, subscribed and unsubscribed; [deliver] plays the broker.
class FakeMqttRepo implements IIotMqttRepository {
  final published = <({String topic, String payload})>[];
  final subscribed = <String>[];
  final unsubscribed = <String>[];
  final _messages = StreamController<MqttMessageEntity>.broadcast();

  void deliver(String topic, String payload) =>
      _messages.add(MqttMessageEntity(topic: topic, payload: payload));

  @override
  bool get isConnected => true;

  @override
  String? get identityId => 'us-east-1:user';

  @override
  String? get userId => 'user';

  @override
  Future<void> connect({
    void Function()? onDisconnected,
    MqttWill Function(String identityId)? will,
  }) async {}

  @override
  void disconnect() {}

  @override
  void publish(String topic, String payload,
          {bool retain = false, int qos = 1}) =>
      published.add((topic: topic, payload: payload));

  @override
  Stream<MqttMessageEntity> subscribe(String topic) {
    subscribed.add(topic);
    return _messages.stream.where((m) => m.topic == topic);
  }

  @override
  void unsubscribe(String topic) => unsubscribed.add(topic);
}
