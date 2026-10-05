import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Counts every MQTT message this app sends and receives and prints one
/// line a minute, so the cost of the cloud can be read off the console:
///
/// ```
/// [MQTT] last 60 s — sent 214 msgs, 71 KB, 221 billed (frames 211 · state 3) · received 2 msgs, 0 KB, 2 billed (watch 2) · ≈ 13380 billed/h at this rate
/// ```
///
/// "Billed" is how AWS IoT counts: each message is one unit per 5 KB
/// started, charged once when published and once per client it is
/// delivered to. A minute with no message prints nothing.
class MqttStats {
  MqttStats._();

  /// AWS IoT meters a message in 5 KB increments.
  static const billedUnitBytes = 5 * 1024;
  static const window = Duration(seconds: 60);

  static final _sent = <String, _Count>{};
  static final _received = <String, _Count>{};
  static Timer? _timer;

  static void sent(String topic, String payload) => _add(_sent, topic, payload);

  static void received(String topic, String payload) =>
      _add(_received, topic, payload);

  static void _add(Map<String, _Count> into, String topic, String payload) {
    final bytes = utf8.encode(payload).length;
    final count = into.putIfAbsent(kindOf(topic), _Count.new);
    count.messages++;
    count.bytes += bytes;
    count.billed += billedUnits(bytes);
    _timer ??= Timer.periodic(window, (_) {
      final line = takeSummary();
      if (line != null) debugPrint(line);
    });
  }

  /// What a message of [bytes] costs, in billed units (never less than 1).
  static int billedUnits(int bytes) =>
      bytes <= billedUnitBytes ? 1 : (bytes / billedUnitBytes).ceil();

  /// The topic without the identity in front: `frames`, `state`, `will`…;
  /// `watch` for the bare identity topic (the central mirror's ping).
  static String kindOf(String topic) {
    final slash = topic.indexOf('/');
    return slash < 0 ? 'watch' : topic.substring(slash + 1);
  }

  /// The line for what was counted since the last call, and a fresh count;
  /// null when nothing was sent or received.
  @visibleForTesting
  static String? takeSummary() {
    if (_sent.isEmpty && _received.isEmpty) return null;
    final billed = _total(_sent).billed + _total(_received).billed;
    final perHour = billed * (3600 ~/ window.inSeconds);
    final line = '[MQTT] last ${window.inSeconds} s — '
        'sent ${_describe(_sent)} · received ${_describe(_received)} '
        '· ≈ $perHour billed/h at this rate';
    _sent.clear();
    _received.clear();
    return line;
  }

  static _Count _total(Map<String, _Count> counts) {
    final total = _Count();
    for (final c in counts.values) {
      total.messages += c.messages;
      total.bytes += c.bytes;
      total.billed += c.billed;
    }
    return total;
  }

  static String _describe(Map<String, _Count> counts) {
    final total = _total(counts);
    if (total.messages == 0) return '0 msgs';
    final kinds = counts.entries.toList()
      ..sort((a, b) => b.value.messages.compareTo(a.value.messages));
    final detail =
        kinds.map((e) => '${e.key} ${e.value.messages}').join(' · ');
    return '${total.messages} msgs, ${(total.bytes / 1024).round()} KB, '
        '${total.billed} billed ($detail)';
  }
}

class _Count {
  int messages = 0;
  int bytes = 0;
  int billed = 0;
}
