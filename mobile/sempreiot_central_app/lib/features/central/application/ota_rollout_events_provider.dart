import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_v2_payloads.dart';

/// What crosses the serial link about a rollout (protocol §13.4, §13.6), as
/// the ingest pipeline authenticated it and in the order it arrived.
sealed class OtaRolloutEvent {
  const OtaRolloutEvent();
}

/// One page of the board's OTA_ROLLOUT.
class OtaRolloutPageEvent extends OtaRolloutEvent {
  const OtaRolloutPageEvent(this.page);
  final SafrOtaRolloutPayload page;
}

/// A unit's OTA_STATUS, relayed unchanged by the board; [mac] is the frame's
/// SRC_MAC.
class OtaUnitStatusEvent extends OtaRolloutEvent {
  const OtaUnitStatusEvent({required this.mac, required this.status});
  final String mac;
  final SafrOtaStatusPayload status;
}

/// A unit's OTA_RESULT, relayed unchanged by the board; [mac] is the frame's
/// SRC_MAC. The tablet ACKs the frame like every frame that asks for it.
class OtaUnitResultEvent extends OtaRolloutEvent {
  const OtaUnitResultEvent({required this.mac, required this.result});
  final String mac;
  final SafrOtaResultPayload result;
}

class OtaRolloutBus {
  final _controller = StreamController<OtaRolloutEvent>.broadcast(sync: true);

  Stream<OtaRolloutEvent> get stream => _controller.stream;

  void emit(OtaRolloutEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  void dispose() => _controller.close();
}

final otaRolloutBusProvider = Provider<OtaRolloutBus>((ref) {
  final bus = OtaRolloutBus();
  ref.onDispose(bus.dispose);
  return bus;
});

/// Counts the link-up sequences of the downlink that ran to their end
/// (TIME_SYNC, the journal, GET_INSTALLATION, GET_DEVICE_TABLE): what asks
/// the board something once the link is up does it when this moves.
final linkUpSequenceProvider = StateProvider<int>((_) => 0);
