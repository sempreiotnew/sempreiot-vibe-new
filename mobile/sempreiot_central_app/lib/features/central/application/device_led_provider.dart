import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/led/led_language.dart';
import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'safr_traffic_provider.dart';
import 'topology_provider.dart';

/// Every unit's LED, replayed on the tablet from what crosses the wire —
/// the same rules as the firmware (siot_ui_led.c, siot_netcore.c,
/// siot_coordinator.c, siot_leafcore.c):
///
///  * a node pulses blue when IT transmits: 100 ms for background frames
///    (folded), 500 ms for EVENT / ACK / COMMAND / TIME_SYNC; it does not
///    pulse when it relays someone else's frame;
///  * the board pulses for its own frames AND for every frame it relays,
///    up to the tablet or down into the mesh;
///  * cyan 500 ms when the tablet ACKs the unit's EVENT;
///  * a leaf is dark except for the walk test — a button press, or the one
///    it runs by itself right after provisioning (spec §12.8): blue 100 ms
///    ("heard you"), blue 500 ms (the MANUAL_TEST left), cyan if the
///    central's ACK comes within 3 s. Its red blink (no ACK reached it) is
///    not shown: the tablet cannot know its ACK was lost on the way down;
///  * IDENTIFY: blue blink 1 s for N s, no pulses meanwhile;
///  * base: node in alarm red solid, root (level 1) green flash, board
///    magenta flash, children and leaves off. "In alarm" is the DEVICE's
///    state, not the app's latch (the ALARME badge): red while its ALARM
///    re-announces keep arriving (every 60 s, siot_netcore.c), gone when a
///    RESET clears the latch, the unit reboots (HEARTBEAT uptime) or the
///    re-announces stop.
///
/// What never crosses the wire is not shown: survey, button hold, setup,
/// and the white "finding the network" of an offline unit (offline keeps
/// the app's red look). Pulses reach the screen after the frame's trip
/// through the mesh and the USB — same order and duration, a little late.
class DeviceLedEngine extends ChangeNotifier {
  DeviceLedEngine({
    required Stream<SafrTrafficTick> traffic,
    required List<TopologyNode> Function() nodes,
    DateTime Function()? clock,
  })  : _nodes = nodes,
        _clock = clock ?? DateTime.now {
    _startedAt = _clock();
    _sub = traffic.listen(onTick);
  }

  /// When the engine started listening: an alarm latched before that had
  /// its ALARM frames go by unseen (app restart).
  late final DateTime _startedAt;

  final List<TopologyNode> Function() _nodes;
  final DateTime Function() _clock;
  late final StreamSubscription<SafrTrafficTick> _sub;

  final _leds = <String, LedTimeline>{};

  /// Leaf MAC → until when its walk test waits for the central's ACK.
  final _walkTestUntil = <String, DateTime>{};

  /// Node MAC → when its last ALARM frame (first or re-announce) arrived.
  final _alarmSeenAt = <String, DateTime>{};

  /// Nodes whose latch this engine has seen set: a later "not latched" is
  /// a confirmed RESET. Needed because the ALARM frame reaches the engine
  /// BEFORE the ingest writes the latch — "not latched yet" must not be
  /// read as "reset".
  final _latchSeen = <String>{};

  /// Units seen booting after this engine started: a latch they carry from
  /// before is not an alarm they are still in.
  final _bootedSinceStart = <String>{};

  /// Redraws when a red LED times out (no re-announce): red is static, so
  /// nothing else would repaint it.
  final _alarmExpiry = <String, Timer>{};

  LedTimeline _led(String mac) =>
      _leds.putIfAbsent(mac, () => LedTimeline(_clock()));

  static bool _isMessage(SafrMsgType? t) =>
      t == SafrMsgType.event ||
      t == SafrMsgType.ack ||
      t == SafrMsgType.command ||
      t == SafrMsgType.timeSync;

  /// One transmission → one pulse (siot_ui_led.c `on_tx`).
  void _tx(String mac, SafrMsgType? type, DateTime now) {
    if (_isMessage(type)) {
      _led(mac).pulse(LedColor.blue, ledMsgMs, now);
    } else {
      _led(mac).pulse(LedColor.blue, ledTickMs, now, fold: true);
    }
  }

  @visibleForTesting
  void onTick(SafrTrafficTick tick) {
    final now = _clock();
    final nodes = _nodes();
    TopologyNode? origin;
    String? boardMac;
    for (final n in nodes) {
      if (n.mac == tick.mac) origin = n;
      if (n.layer == 0) boardMac ??= n.mac;
    }
    final isLeaf = origin?.isLeaf ?? false;

    if (tick.direction == SafrTrafficDirection.uplink &&
        tick.msgType == SafrMsgType.event) {
      if (tick.severity == SafrEventType.alarm.severity) {
        _alarmSeenAt[tick.mac] = now;
        _alarmExpiry[tick.mac]?.cancel();
        _alarmExpiry[tick.mac] = Timer(
          const Duration(milliseconds: alarmRetxMs + alarmRetxGraceMs + 50),
          notifyListeners,
        );
      } else if (tick.eventCode == SafrEventCode.restore) {
        _alarmSeenAt.remove(tick.mac);
      }
    }

    // A HEARTBEAT from a unit that booted AFTER its last ALARM frame: it
    // rebooted, and the alarm (RAM only, siot_netcore.c) went with it. The
    // node announces itself as soon as it rejoins, so the red clears then
    // instead of waiting out a whole re-announce period.
    final uptime = tick.uptimeS;
    if (uptime != null) {
      final bootedAt =
          now.subtract(Duration(seconds: uptime, milliseconds: rebootSlackMs));
      final seen = _alarmSeenAt[tick.mac];
      if (seen != null && bootedAt.isAfter(seen)) {
        _alarmSeenAt.remove(tick.mac);
        _alarmExpiry.remove(tick.mac)?.cancel();
      }
      if (bootedAt.isAfter(_startedAt)) _bootedSinceStart.add(tick.mac);
    }

    if (tick.direction == SafrTrafficDirection.uplink) {
      if (isLeaf) {
        // §12.8: only the walk test lights a leaf.
        if (tick.msgType == SafrMsgType.event &&
            tick.eventCode == SafrEventCode.manualTest) {
          _led(tick.mac)
            ..pulse(LedColor.blue, ledTickMs, now)
            ..pulse(LedColor.blue, ledMsgMs, now);
          _walkTestUntil[tick.mac] =
              now.add(const Duration(milliseconds: leafWalkTestAckMs));
        }
      } else {
        _tx(tick.mac, tick.msgType, now);
      }
      // The board relays every uplink frame to the tablet (its own ones
      // were already counted as the origin's).
      if (boardMac != null && boardMac != tick.mac) {
        _tx(boardMac, tick.msgType, now);
      }
    } else {
      // Tablet → mesh: the board relays it down.
      if (boardMac != null) _tx(boardMac, tick.msgType, now);
      if (tick.ack) {
        if (!isLeaf) {
          _led(tick.mac).pulse(LedColor.cyan, ledMsgMs, now);
        } else {
          final until = _walkTestUntil.remove(tick.mac);
          if (until != null && until.isAfter(now)) {
            _led(tick.mac).pulse(LedColor.cyan, ledMsgMs, now);
          }
        }
      }
    }
    notifyListeners();
  }

  /// The tablet's IDENTIFY was confirmed: the unit is blinking now.
  void identify(String mac, int seconds) {
    _led(mac).identify(seconds, _clock());
    notifyListeners();
  }

  /// The device is in alarm right now, as far as the wire tells: an ALARM
  /// frame within one re-announce period, and the latch not yet cleared by
  /// a confirmed RESET.
  bool _inAlarm(TopologyNode node) {
    const windowMs = alarmRetxMs + alarmRetxGraceMs;
    final now = _clock();
    if (node.alarmLatched) {
      _latchSeen.add(node.mac);
    } else if (_latchSeen.remove(node.mac)) {
      _alarmSeenAt.remove(node.mac); // latch cleared = RESET confirmed
      return false;
    }
    final seen = _alarmSeenAt[node.mac];
    if (seen == null) {
      // Latched before this engine was listening: its next re-announce is
      // at most one period away, so assume the unit is still red till then.
      return node.alarmLatched &&
          !_bootedSinceStart.contains(node.mac) &&
          now.difference(_startedAt).inMilliseconds <= windowMs;
    }
    if (now.difference(seen).inMilliseconds > windowMs) {
      _alarmSeenAt.remove(node.mac);
      return false;
    }
    return true;
  }

  LedBase baseOf(TopologyNode node) {
    if (node.layer == 0) return LedBase.magentaFlash;
    if (node.isLeaf) return LedBase.off; // no alarm LED on a leaf yet
    if (_inAlarm(node)) return LedBase.redSolid;
    return node.layer == 1 ? LedBase.greenFlash : LedBase.off;
  }

  /// What [node]'s LED shows right now; dark for an offline unit.
  LedLook look(TopologyNode node) {
    if (!node.online) return LedLook.dark;
    return _led(node.mac).look(baseOf(node), _clock());
  }

  /// True when [node]'s LED changes over time right now, so the screen has
  /// to redraw every frame (a pulse queued, IDENTIFY, a slow flash).
  bool animating(TopologyNode node) {
    if (!node.online) return false;
    final base = baseOf(node);
    if (base == LedBase.greenFlash || base == LedBase.magentaFlash) return true;
    return _leds[node.mac]?.busy(_clock()) ?? false;
  }

  @override
  void dispose() {
    for (final t in _alarmExpiry.values) {
      t.cancel();
    }
    _sub.cancel();
    super.dispose();
  }
}

/// Started with the main screen in CENTRAL mode (not when the first device
/// circle is drawn), so no frame goes by unseen.
final deviceLedProvider = ChangeNotifierProvider<DeviceLedEngine>((ref) {
  return DeviceLedEngine(
    traffic: ref.watch(safrTrafficProvider).stream,
    nodes: () => ref.read(topologyProvider),
  );
});
