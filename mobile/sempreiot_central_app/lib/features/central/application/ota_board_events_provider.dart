import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';

/// What the board says about a firmware push (protocol §13.3), as the ingest
/// pipeline authenticated it. [bootCtr] is the BOOT_CTR of the frame: it
/// changes when the board restarts, which is how a frame of the board that
/// took the image is told from a frame of the board that runs it.
sealed class OtaBoardEvent {
  const OtaBoardEvent({required this.srcMac, required this.bootCtr});
  final String srcMac;
  final int bootCtr;
}

/// OTA_PUSH_RESULT.
class OtaPushResultEvent extends OtaBoardEvent {
  const OtaPushResultEvent({
    required super.srcMac,
    required super.bootCtr,
    required this.result,
  });
  final SafrOtaPushResultPayload result;
}

/// The board's own NAME_ANNOUNCE (§7.11): the firmware it runs. Sent on the
/// first frame it hears from the tablet after every boot and after every
/// GET_DEVICE_TABLE.
class BoardAnnounceEvent extends OtaBoardEvent {
  const BoardAnnounceEvent({
    required super.srcMac,
    required super.bootCtr,
    required this.fwVersion,
  });
  final String fwVersion;
}

/// The board's own HEARTBEAT (LAYER 0, every 15 s and once at boot): the
/// board is up. With a new [bootCtr]: it is up again after a restart.
class BoardHeartbeatEvent extends OtaBoardEvent {
  const BoardHeartbeatEvent({required super.srcMac, required super.bootCtr});
}

class OtaBoardBus {
  final _controller = StreamController<OtaBoardEvent>.broadcast(sync: true);

  Stream<OtaBoardEvent> get stream => _controller.stream;

  void emit(OtaBoardEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  void dispose() => _controller.close();
}

final otaBoardBusProvider = Provider<OtaBoardBus>((ref) {
  final bus = OtaBoardBus();
  ref.onDispose(bus.dispose);
  return bus;
});

/// The board's own row of the device registry: the unit that reported a
/// product of the board family (v3.5 NAME_ANNOUNCE) or, from a board that
/// never said what it is, the one that heartbeats from layer 0. Null until
/// the board was heard.
final boardDeviceProvider = StreamProvider<MeshDevice?>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.meshDevices)
        ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
      .watch()
      .map(pickBoardDevice);
});

/// [rows] newest first.
MeshDevice? pickBoardDevice(List<MeshDevice> rows) {
  for (final r in rows) {
    final code = r.productCode;
    if (code != null &&
        SafrProductFamily.ofCode(code) == SafrProductFamily.board) {
      return r;
    }
  }
  for (final r in rows) {
    if (r.layer == 0 && r.lastHeartbeatAt != null) return r;
  }
  return null;
}
