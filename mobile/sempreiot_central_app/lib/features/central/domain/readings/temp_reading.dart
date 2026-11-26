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
