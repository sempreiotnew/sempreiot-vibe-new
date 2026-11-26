import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/readings/temp_reading.dart';

/// A unit's last reading, as the tablet received it.
class LatestReading {
  const LatestReading({
    required this.at,
    required this.tempTenths,
    this.humidityPct,
    this.rising = false,
  });

  /// When the frame that carried it arrived (UTC).
  final DateTime at;

  /// °C × 10.
  final int tempTenths;

  /// Whole %, null = the frame carried none.
  final int? humidityPct;

  /// "Subindo" ([tempRising]) when the provider last ran — on every new
  /// reading of any unit.
  final bool rising;
}

/// The newest reading of every unit that ever sent one, with the "subindo"
/// rule applied to the tablet's own points (brief §4.6). The tablet's own
/// database: on a user's phone the readings come with the central's
/// snapshot (central_mirror_codec.dart), already on each `TopologyNode`.
final latestReadingsProvider =
    StreamProvider<Map<String, LatestReading>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.watchLatestReadings(tempRisingWindow).map((rows) {
    final byMac = <String, List<TempPoint>>{};
    for (final r in rows) {
      (byMac[r.deviceMac] ??= []).add(TempPoint(
        at: r.at.toUtc(),
        tenths: r.tempTenths,
        humidityPct: r.humidityPct,
      ));
    }
    final now = DateTime.now().toUtc();
    return {
      for (final e in byMac.entries)
        // Oldest first: the last is the newest.
        e.key: LatestReading(
          at: e.value.last.at,
          tempTenths: e.value.last.tenths,
          humidityPct: e.value.last.humidityPct,
          rising: tempRising(e.value, now),
        ),
    };
  });
});

/// The points of one unit's chart: what the tablet received from it in the
/// last [tempChartWindow], oldest first. Empty on a user's phone — the
/// history is not mirrored (docs/cloud/central-mirror.md §4.1).
final deviceChartProvider =
    StreamProvider.autoDispose.family<List<TempPoint>, String>((ref, mac) {
  final db = ref.watch(appDatabaseProvider);
  final since = DateTime.now().toUtc().subtract(tempChartWindow);
  return db.watchReadings(mac, since).map((rows) => [
        for (final r in rows)
          TempPoint(
            at: r.at.toUtc(),
            tenths: r.tempTenths,
            humidityPct: r.humidityPct,
          ),
      ]);
});
