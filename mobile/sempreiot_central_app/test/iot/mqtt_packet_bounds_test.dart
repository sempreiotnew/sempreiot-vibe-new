import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/iot/data/repositories/iot_mqtt_repository_impl.dart';

/// The MQTT stream does not respect WebSocket frame boundaries: a packet
/// may end in the next frame, and the client must keep the start (the
/// system test's end record was lost that way, 2026-10-31).
void main() {
  /// A PUBLISH packet: fixed header, remaining length (1–2 bytes), body.
  Uint8List publish(int bodyLen) {
    final body = List<int>.filled(bodyLen, 0x41);
    final rem = <int>[];
    var n = bodyLen;
    do {
      var b = n % 128;
      n ~/= 128;
      if (n > 0) b |= 0x80;
      rem.add(b);
    } while (n > 0);
    return Uint8List.fromList([0x30, ...rem, ...body]);
  }

  Uint8List cat(List<Uint8List> parts) =>
      Uint8List.fromList([for (final p in parts) ...p]);

  test('two whole packets in one frame: both, nothing left', () {
    final a = publish(10), b = publish(300);
    final (packets, rest) = IotMqttRepositoryImpl.mqttPacketBounds(cat([a, b]));
    expect(packets, [(0, a.length), (a.length, a.length + b.length)]);
    expect(rest, isEmpty);
  });

  test('a 6 KB packet split across frames: kept, then read whole', () {
    final big = publish(6000);
    final first = big.sublist(0, 4096);
    final second = big.sublist(4096);
    final (p1, rest1) = IotMqttRepositoryImpl.mqttPacketBounds(first);
    expect(p1, isEmpty);
    expect(rest1, first, reason: 'the start waits for the next frame');
    final (p2, rest2) =
        IotMqttRepositoryImpl.mqttPacketBounds(cat([rest1, second]));
    expect(p2, [(0, big.length)]);
    expect(rest2, isEmpty);
  });

  test('a whole packet followed by the start of another: the tail is kept', () {
    final a = publish(50), b = publish(500);
    final frame = cat([a, b.sublist(0, 100)]);
    final (packets, rest) = IotMqttRepositoryImpl.mqttPacketBounds(frame);
    expect(packets, [(0, a.length)]);
    expect(rest, b.sublist(0, 100));
  });

  test('a frame cut inside the remaining-length bytes still waits', () {
    final b = publish(500); // remaining length takes 2 bytes
    final (packets, rest) =
        IotMqttRepositoryImpl.mqttPacketBounds(b.sublist(0, 2));
    expect(packets, isEmpty);
    expect(rest, b.sublist(0, 2));
  });
}
