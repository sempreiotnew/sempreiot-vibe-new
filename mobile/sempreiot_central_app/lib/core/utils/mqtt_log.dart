import 'package:flutter/foundation.dart';

/// Structured console logging for MQTT traffic so a session's publishes,
/// subscriptions and deliveries can be followed at a glance:
///
/// ```
/// [IoT] 14:02:31.482 📤 PUB 📌 us-east-1:abc…/will → {"status":"online","wifi":"online","usb":"connected",…}
/// [IoT] 14:02:31.964 📥 RX     us-east-1:abc…/will → {"status":"online",…}
/// [IoT] 14:02:30.101 📡 SUB    us-east-1:abc…/#
/// [Central] 14:02:31.010 ⚙️ status changed (usb: connecting → connected)
/// ```
///
/// 📌 marks a retained publish.
class MqttLog {
  MqttLog._();

  static const _maxPayload = 220;

  static String _ts() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.$ms';
  }

  static String _trim(String payload) => payload.length <= _maxPayload
      ? payload
      : '${payload.substring(0, _maxPayload)}… (+${payload.length - _maxPayload} chars)';

  static void pub(String topic, String payload,
          {bool retained = false, String tag = 'IoT'}) =>
      debugPrint(
          '[$tag] ${_ts()} 📤 PUB ${retained ? '📌' : '  '} $topic → ${_trim(payload)}');

  static void rx(String topic, String payload, {String tag = 'IoT'}) =>
      debugPrint('[$tag] ${_ts()} 📥 RX     $topic → ${_trim(payload)}');

  static void sub(String topic, {String tag = 'IoT'}) =>
      debugPrint('[$tag] ${_ts()} 📡 SUB    $topic');

  static void event(String message, {String tag = 'IoT'}) =>
      debugPrint('[$tag] ${_ts()} ⚙️ $message');
}
