import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_v2_payloads.dart';
import 'safr_downlink_provider.dart';

/// Sound on/off per device, as the operator last set it — the MACs whose
/// sounder is silenced. Devices never report this state (protocol §7.6 has
/// no status for it), so it is what the tablet sent and the root ACKed;
/// RAM only, everything reads "on" again after a restart.
///
/// Off = COMMAND SILENCE (latch kept, §7.6 0x01). On = COMMAND RELAY_SET 1:
/// the protocol has no UNSILENCE, and RELAY_SET drives the sounder output
/// whether or not an alarm is up.
class DeviceSoundNotifier extends StateNotifier<Set<String>> {
  DeviceSoundNotifier(this._downlink) : super(const {});

  final SafrDownlink _downlink;

  bool isSilenced(String mac) => state.contains(mac);

  /// Sends the command; the state flips only on the root's ACK.
  Future<bool> setSound(String mac, {required bool on}) async {
    final ok = on
        ? await _downlink.sendCommand(mac, SafrCommand.relaySet, args: [1])
        : await _downlink.sendCommand(mac, SafrCommand.silence);
    if (ok) {
      state = on ? ({...state}..remove(mac)) : {...state, mac};
    }
    return ok;
  }
}

final deviceSoundProvider =
    StateNotifierProvider<DeviceSoundNotifier, Set<String>>(
  (ref) => DeviceSoundNotifier(ref.watch(safrDownlinkProvider)),
);
