import '../safr/safr_v2_payloads.dart';

// Temperature and humidity as the units report them (phase 5 brief §4.6,
// §8; protocol §7.1.6 / §7.3, v3.16): the points the tablet received, the
// rules the screen applies to them and the words it says. The alarm is the
// unit's own decision — nothing here raises one.

/// One reading the tablet received from a unit.
class TempPoint {
  const TempPoint({required this.at, required this.tenths, this.humidityPct});

  /// When the tablet received the frame (UTC).
  final DateTime at;

  /// °C × 10.
  final int tenths;

  /// Whole %, null = not sent.
  final int? humidityPct;
}

/// "Subindo" (brief §4.6): the tablet's own points show this much, °C × 10,
/// within [tempRisingWindow].
const tempRisingTenths = 40;
const tempRisingWindow = Duration(seconds: 60);

/// The chart of the device screen: the last hour, and how far apart two
/// points may be and still be joined by a line (a unit that reports every
/// 60 s and lost one report is a gap, not a line).
const tempChartWindow = Duration(hours: 1);
const tempChartGap = Duration(seconds: 150);

/// The readings screen's pinch: the least and the most time the chart shows
/// (the most = what the tablet keeps, the `DeviceReadings` retention).
const tempChartZoomMin = Duration(minutes: 5);
const tempChartZoomMax = Duration(hours: 24);

/// The span after a pinch that began at [from]: fingers apart ([scale] > 1)
/// = less time, together = more, inside the two limits.
Duration pinchedChartWindow(Duration from, double scale) {
  if (scale <= 0) return from;
  final ms = (from.inMilliseconds / scale).round();
  return Duration(
      milliseconds: ms.clamp(
          tempChartZoomMin.inMilliseconds, tempChartZoomMax.inMilliseconds));
}

/// The least the two scales span at a zoom of [window]: closer in, a
/// narrower scale, so a change of a few tenths can be read. Temperature in
/// °C × 10 (1 °C at 5 min … 10 °C from one hour on), humidity in % (4 … 20).
int chartMinTempSpanTenths(Duration window) =>
    (100 * window.inSeconds / 3600).round().clamp(10, 100);
int chartMinHumiditySpan(Duration window) =>
    (20 * window.inSeconds / 3600).round().clamp(4, 20);

String _two(int v) => v.toString().padLeft(2, '0');

/// "14:05" of [utc] on the tablet's clock: a mark of the chart's time axis.
String chartClockText(DateTime utc) {
  final t = utc.toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// "26/11" of [utc] on the tablet's clock: the mark of a midnight.
String chartDayText(DateTime utc) {
  final t = utc.toLocal();
  return '${_two(t.day)}/${_two(t.month)}';
}

/// The day(s) a chart from [start] to [end] covers, on the tablet's clock:
/// "26/11/2026", or "25/11 – 26/11/2026" when it crosses a midnight.
String chartDateText(DateTime start, DateTime end) {
  final a = start.toLocal(), b = end.toLocal();
  final last = '${_two(b.day)}/${_two(b.month)}/${b.year}';
  if (a.year == b.year && a.month == b.month && a.day == b.day) return last;
  return '${_two(a.day)}/${_two(a.month)} – $last';
}

/// The steps between two marks of the time axis, in minutes.
const _chartTickMinutes = [1, 2, 5, 10, 15, 30, 60, 120, 180, 360, 720];

/// The marks of the time axis between [start] and [end]: round times of
/// the tablet's clock (every minute, every 5, every hour… — the finest step
/// that gives at most [maxTicks] marks), oldest first.
List<DateTime> chartTimeTicks(DateTime start, DateTime end, int maxTicks) {
  final span = end.difference(start);
  if (span <= Duration.zero) return const [];
  final most = maxTicks < 2 ? 2 : maxTicks;
  var step = _chartTickMinutes.last;
  for (final m in _chartTickMinutes) {
    if (span.inSeconds / (m * 60) <= most) {
      step = m;
      break;
    }
  }
  // From the tablet's midnight, so the marks fall on 14:00, 14:15…
  final local = start.toLocal();
  final midnight = DateTime(local.year, local.month, local.day);
  final sinceMidnight = local.difference(midnight).inSeconds;
  final first = (sinceMidnight / (step * 60)).ceil() * step;
  return [
    for (var t = midnight.add(Duration(minutes: first)).toUtc();
        !t.isAfter(end);
        t = t.add(Duration(minutes: step)))
      t,
  ];
}

/// "últimos 15 min", "última hora", "últimas 6 h": how much the chart shows.
String chartWindowText(Duration window) {
  final minutes = (window.inSeconds / 60).round();
  if (minutes == 60) return 'última hora';
  if (minutes < 120) return 'últimos $minutes min';
  final h = (window.inMinutes / 6).round() / 10;
  return 'últimas ${h == h.roundToDouble() ? h.round() : h.toStringAsFixed(1).replaceAll('.', ',')} h';
}

/// True while the newest of [points] is at least [tempRisingTenths] above
/// the lowest point received in the [tempRisingWindow] before it — and that
/// newest point is itself no older than the window at [now]. [points] in
/// any order; only what arrived is looked at.
bool tempRising(Iterable<TempPoint> points, DateTime now) {
  TempPoint? newest;
  for (final p in points) {
    if (newest == null || p.at.isAfter(newest.at)) newest = p;
  }
  if (newest == null) return false;
  if (now.difference(newest.at) > tempRisingWindow) return false;
  final from = newest.at.subtract(tempRisingWindow);
  for (final p in points) {
    if (identical(p, newest) || p.at.isBefore(from)) continue;
    if (newest.tenths - p.tenths >= tempRisingTenths) return true;
  }
  return false;
}

/// "24,5 °C": one decimal, as the device screen and the pill show it.
String tempText(int tenths) {
  final sign = tenths < 0 ? '-' : '';
  final abs = tenths.abs();
  return '$sign${abs ~/ 10},${abs % 10} °C';
}

/// "58 °C": whole degrees, for the words of an alarm.
String tempWholeText(int tenths) => '${(tenths / 10).round()} °C';

/// "56 %": whole percent, never decimals (the sensor is ±2 to 3 %).
String humidityText(int pct) => '$pct %';

/// How old a reading is: "há 40 s", "há 3 min", "há 2 h", "há 3 d".
String readingAgeText(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 5) return 'agora';
  if (d.inSeconds < 60) return 'há ${d.inSeconds} s';
  if (d.inMinutes < 60) return 'há ${d.inMinutes} min';
  if (d.inHours < 24) return 'há ${d.inHours} h';
  return 'há ${d.inDays} d';
}

/// Why a heat alarm fired, in words, with the reading of the EVENT that
/// said so: "Calor — 58 °C" (fixed temperature) or "Calor — subida rápida,
/// 41 °C" (rate of rise). Null for a code that is not a heat alarm.
String? heatAlarmWords(SafrEventCode code, int? tempTenths) {
  final reading = tempTenths == null ? null : tempWholeText(tempTenths);
  return switch (code) {
    SafrEventCode.heatAlarm => reading == null ? 'Calor' : 'Calor — $reading',
    SafrEventCode.heatRiseAlarm => reading == null
        ? 'Calor — subida rápida'
        : 'Calor — subida rápida, $reading',
    _ => null,
  };
}

/// The humidity trouble (SENSOR_WET), in words.
const sensorWetWords = 'Sensor molhado';
