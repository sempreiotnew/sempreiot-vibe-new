import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import 'serial_provider.dart';

final serialLogsProvider = StreamProvider<List<SerialPacket>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  // Fetch the latest 500 DESC, then reverse so newest is at the bottom
  return (db.select(db.serialPackets)
        ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)])
        ..limit(500))
      .watch()
      .map((rows) => rows.reversed.toList());
});

/// Live wire diagnostics polled from the serial notifier: answers "are raw
/// bytes even arriving?" independently of whether anything validates.
typedef SerialWireDiag = ({int bytes, int dropped, int frames});

final serialWireDiagProvider = StreamProvider<SerialWireDiag>((ref) {
  final serial = ref.watch(serialProvider.notifier);
  SerialWireDiag read() => (
        bytes: serial.rawByteCount,
        dropped: serial.droppedByteCount,
        frames: serial.validFrameCount,
      );
  return Stream<SerialWireDiag>.multi((controller) {
    controller.add(read());
    final timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => controller.add(read()),
    );
    controller.onCancel = timer.cancel;
  });
});

/// Protocol-validation counters for the console header: every stored frame
/// passed CRC at the reframer, so total − auth failures = fully verified.
typedef SerialStats = ({int total, int crcErr, int authErr});

final serialStatsProvider = StreamProvider<SerialStats>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db
      .customSelect(
        'SELECT '
        " (SELECT COUNT(*) FROM serial_packets) AS total, "
        " (SELECT COUNT(*) FROM device_events WHERE error_kind = 'crc_failed') AS crc, "
        " (SELECT COUNT(*) FROM device_events WHERE error_kind = 'auth_failed') AS auth",
        readsFrom: {db.serialPackets, db.deviceEvents},
      )
      .watchSingle()
      .map((row) => (
            total: row.read<int>('total'),
            crcErr: row.read<int>('crc'),
            authErr: row.read<int>('auth'),
          ));
});
