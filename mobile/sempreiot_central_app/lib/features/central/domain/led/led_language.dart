/// The units' LED language, mirrored on screen: the same colours, the same
/// durations, the same queue as the firmware's pattern engine.
///
/// SOURCE OF TRUTH: firmware/components/ui/siot_ui_led/include/siot_ui_led.h
/// and src/siot_ui_led.c (reference §3.7 row 7.7). Change a number there,
/// change it here.
library;

enum LedColor { red, green, blue, cyan, magenta, yellow, white }

/// `SIOT_LED_TICK_MS` — background traffic (HEARTBEAT, TOPOLOGY, …).
const ledTickMs = 100;

/// `SIOT_LED_MSG_MS` — EVENT / ACK / COMMAND / TIME_SYNC, and the cyan ACK.
const ledMsgMs = 500;

/// `SLOW_PERIOD_TICKS` × 50 ms / `SLOW_ON_TICKS` × 50 ms — the root's green
/// and the board's magenta: a 250 ms flash every 5 s.
const ledSlowPeriodMs = 5000;
const ledSlowOnMs = 250;

/// `BLINK_HALF_TICKS` × 50 ms — IDENTIFY blinks 500 ms on / 500 ms off.
const ledBlinkHalfMs = 500;

/// After a pulse the base resumes in its "off" part (`transient_done`:
/// phase = BLINK_HALF_TICKS), so the next slow flash comes 4.5 s later.
const ledResumePhaseMs = ledBlinkHalfMs;

/// `SIOT_LED_PULSE_QUEUE` — pulses waiting behind the one lit.
const ledPulseQueue = 8;

/// `SIOT_LEAF_WALKTEST_ACK_MS` (siot_leaf_proto.h) — a leaf shows the cyan
/// only if the central's ACK comes within this window of its walk test.
const leafWalkTestAckMs = 3000;

/// `ALARM_RETX_MS` (siot_netcore.c) — a node in alarm re-announces its
/// ALARM this often, and stops the moment it leaves alarm (RESET, reboot).
/// The red LED is shown while re-announces keep coming, plus some slack for
/// the trip through the mesh.
const alarmRetxMs = 60000;
const alarmRetxGraceMs = 10000;

/// Margin on a HEARTBEAT's UPTIME_S when deciding the unit booted after its
/// last ALARM frame (the uptime is whole seconds, plus the frame's trip).
const rebootSlackMs = 2000;

/// The steady pattern under the pulses (`pattern_for_state`).
enum LedBase { off, redSolid, greenFlash, magentaFlash }

/// What the LED shows at one instant: a colour, or dark.
class LedLook {
  const LedLook(this.color);
  static const dark = LedLook(null);

  final LedColor? color;
  bool get lit => color != null;
}

class _Segment {
  _Segment(this.color, this.start, this.end, {this.blink = false});
  final LedColor color;
  final DateTime start;
  DateTime end;
  final bool blink;
  int get ms => end.difference(start).inMilliseconds;
}

/// One unit's LED: the base pattern plus the transients (pulses, IDENTIFY)
/// laid out on a timeline, exactly as `siot_ui_led_pulse` / `_set` queue
/// them. Pure: every call takes the time, so it is testable.
class LedTimeline {
  LedTimeline(DateTime now) : _baseEpoch = now;

  final _segments = <_Segment>[];
  DateTime? _identifyUntil;

  /// Origin of the slow flash; moved to the end of every transient.
  DateTime _baseEpoch;

  void _prune(DateTime now) {
    while (_segments.isNotEmpty && !_segments.first.end.isAfter(now)) {
      _baseEpoch = _segments.first.end
          .subtract(const Duration(milliseconds: ledResumePhaseMs));
      _segments.removeAt(0);
    }
    if (_identifyUntil != null && !_identifyUntil!.isAfter(now)) {
      _identifyUntil = null;
    }
  }

  /// `siot_ui_led_pulse`: behind whatever is lit; dropped while IDENTIFY
  /// runs or when the queue is full; `fold` merges a tick into an identical
  /// one still lit or last in line.
  void pulse(LedColor color, int ms, DateTime now, {bool fold = false}) {
    _prune(now);
    if (_identifyUntil != null) return;
    if (_segments.isEmpty) {
      _segments.add(_Segment(color, now, now.add(Duration(milliseconds: ms))));
      return;
    }
    final last = _segments.last;
    if (fold && last.color == color && !last.blink) {
      if (_segments.length == 1 &&
          last.end.difference(now).inMilliseconds <= ms) {
        return; // same short pulse still lit
      }
      if (_segments.length > 1 && last.ms == ms) return; // same, last in line
    }
    if (_segments.length - 1 >= ledPulseQueue) return; // queue full
    _segments.add(
        _Segment(color, last.end, last.end.add(Duration(milliseconds: ms))));
  }

  /// `SIOT_EVT_IDENTIFY`: blue blink for [seconds], wins over queued pulses
  /// and keeps new ones out while it runs.
  void identify(int seconds, DateTime now) {
    _prune(now);
    _segments
      ..clear()
      ..add(_Segment(LedColor.blue, now, now.add(Duration(seconds: seconds)),
          blink: true));
    _identifyUntil = _segments.first.end;
  }

  /// True while a transient is lit or queued (the screen must animate).
  bool busy(DateTime now) {
    _prune(now);
    return _segments.isNotEmpty;
  }

  LedLook look(LedBase base, DateTime now) {
    _prune(now);
    if (_segments.isNotEmpty) {
      final s = _segments.first;
      if (s.start.isAfter(now)) return _base(base, now);
      if (!s.blink) return LedLook(s.color);
      final into = now.difference(s.start).inMilliseconds;
      return (into ~/ ledBlinkHalfMs).isEven ? LedLook(s.color) : LedLook.dark;
    }
    return _base(base, now);
  }

  LedLook _base(LedBase base, DateTime now) {
    final flashOn =
        now.difference(_baseEpoch).inMilliseconds % ledSlowPeriodMs <
            ledSlowOnMs;
    return switch (base) {
      LedBase.off => LedLook.dark,
      LedBase.redSolid => const LedLook(LedColor.red),
      LedBase.greenFlash =>
        flashOn ? const LedLook(LedColor.green) : LedLook.dark,
      LedBase.magentaFlash =>
        flashOn ? const LedLook(LedColor.magenta) : LedLook.dark,
    };
  }
}
