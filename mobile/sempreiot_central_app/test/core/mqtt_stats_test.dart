import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/utils/mqtt_stats.dart';

/// The per-minute MQTT count on the console: what the cloud costs.
void main() {
  const id = 'us-east-1:central';

  tearDown(MqttStats.takeSummary);

  test('a message is billed once per 5 KB started', () {
    expect(MqttStats.billedUnits(0), 1);
    expect(MqttStats.billedUnits(5 * 1024), 1);
    expect(MqttStats.billedUnits(5 * 1024 + 1), 2);
    expect(MqttStats.billedUnits(12 * 1024), 3);
  });

  test('topics are named without the identity', () {
    expect(MqttStats.kindOf('$id/frames'), 'frames');
    expect(MqttStats.kindOf('$id/ota/history'), 'ota/history');
    expect(MqttStats.kindOf(id), 'watch');
  });

  test('one line for the minute, then a fresh count', () {
    expect(MqttStats.takeSummary(), isNull);

    for (var i = 0; i < 3; i++) {
      MqttStats.sent('$id/frames', 'x' * 1024);
    }
    MqttStats.sent('$id/state', 'x' * (12 * 1024));
    MqttStats.received(id, '{"type":"watch"}');

    expect(
      MqttStats.takeSummary(),
      '[MQTT] last 60 s — '
      'sent 4 msgs, 15 KB, 6 billed (frames 3 · state 1) '
      '· received 1 msgs, 0 KB, 1 billed (watch 1) '
      '· ≈ 420 billed/h at this rate',
    );
    expect(MqttStats.takeSummary(), isNull);
  });
}
