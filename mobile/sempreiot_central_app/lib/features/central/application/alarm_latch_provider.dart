import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';

/// Devices whose alarm latch is set (SAFR v3 §7.1.4 — UL 864/NFPA 72): an
/// accepted ALARM latches and only the operator RESET clears it. A RESTORE
/// from the device does NOT — that is the compliance point.
final latchedAlarmsProvider = StreamProvider<List<MeshDevice>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.meshDevices)
        ..where((t) => t.alarmLatched.equals(1))
        ..orderBy([(t) => OrderingTerm.asc(t.alarmLatchedAt)]))
      .watch();
});

/// True while any alarm latch is set — drives the alarm-hold banner.
final activeAlarmProvider = Provider<bool>((ref) {
  final latched = ref.watch(latchedAlarmsProvider).valueOrNull;
  return latched != null && latched.isNotEmpty;
});
