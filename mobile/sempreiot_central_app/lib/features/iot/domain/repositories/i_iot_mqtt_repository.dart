import '../entities/mqtt_message_entity.dart';

/// MQTT Last-Will — the broker publishes this on the client's behalf if the
/// connection drops ungracefully (crash, network loss), without the client
/// having to do anything itself.
typedef MqttWill = ({String topic, String payload});

abstract interface class IIotMqttRepository {
  bool get isConnected;
  String? get identityId;
  String? get userId; // Cognito User Pool sub
  /// [will] is called once the identity is resolved (needed to build a
  /// per-identity will topic like `{identityId}/will`) and its result is
  /// sent as the connection's MQTT Last-Will.
  Future<void> connect({
    void Function()? onDisconnected,
    MqttWill Function(String identityId)? will,
  });
  void disconnect();
  /// [qos] 1 (the default) is acknowledged by the broker; 0 is sent once —
  /// for streams where the next message replaces a lost one.
  void publish(String topic, String payload, {bool retain = false, int qos = 1});
  Stream<MqttMessageEntity> subscribe(String topic);

  /// Stops the broker delivering [topic] to this session. Streams returned
  /// by [subscribe] for it simply go quiet.
  void unsubscribe(String topic);
}
