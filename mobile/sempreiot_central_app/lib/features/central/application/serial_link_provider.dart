import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'serial_provider.dart';

/// Protocol-aware USB link status:
/// - the port is open and the FIRST structurally valid SAFR frame arrives
///   ⇒ `connected`; data quality from then on is judged by the Logs seriais
///   screen, not here;
/// - connected, but no valid frame for [serialLinkSilence] ⇒ `stalled`:
///   the port is open (a USB-UART adapter stays enumerated when the board
///   behind it dies) but the board is silent. The board heartbeats every
///   15 s, so this is one missed heartbeat plus margin (spec §9.3). Every
///   device is offline at once — a site without its board is unsupervised,
///   not 45 s of devices fading one by one;
/// - port open, bytes flowing, but nothing ever validates ⇒ `error`
///   (wrong firmware/baud/corruption — never silently "Conectando");
/// - port open and silent from the start ⇒ `connecting`;
/// - no port ⇒ `disconnected`.
enum SerialLinkStatus { disconnected, connecting, connected, stalled, error }

/// Grace period for the first valid frame once bytes start flowing.
const _firstFrameGrace = Duration(seconds: 5);

/// Silence after the last valid frame that turns `connected` into `stalled`.
const serialLinkSilence = Duration(seconds: 20);

class SerialLinkNotifier extends StateNotifier<SerialLinkStatus> {
  SerialLinkNotifier(this._ref) : super(SerialLinkStatus.disconnected) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
    _ref.listen<SerialStatus>(serialProvider, (prev, next) {
      if (next != SerialStatus.connected) {
        _latched = false;
        _firstBytesAt = null;
        _lastFrameAt = null;
      }
      _recompute();
    });
    _recompute();
  }

  final Ref _ref;
  Timer? _timer;

  /// Set by the first valid frame of the current port session.
  bool _latched = false;

  /// When the first raw bytes of the current session arrived.
  DateTime? _firstBytesAt;

  /// Last frame that proved the board is talking (valid or auth-failed).
  DateTime? _lastFrameAt;

  /// Called by the ingest pipeline for every fully validated frame.
  void reportValidFrame() {
    _latched = true;
    _lastFrameAt = DateTime.now();
    _recompute();
  }

  /// Kept for the ingest pipeline: an auth failure is still a structurally
  /// valid frame — the link works, the key doesn't. It latches too; the
  /// failure itself is recorded as a diagnostic event (Logs seriais).
  void reportInvalidFrame() {
    _latched = true;
    _lastFrameAt = DateTime.now();
    _recompute();
  }

  void _recompute() {
    if (!mounted) return;
    final port = _ref.read(serialProvider);
    final next = switch (port) {
      SerialStatus.disconnected => SerialLinkStatus.disconnected,
      SerialStatus.error => SerialLinkStatus.error,
      SerialStatus.connecting => SerialLinkStatus.connecting,
      SerialStatus.connected => _sessionState(),
    };
    if (next != state) state = next;
  }

  SerialLinkStatus _sessionState() {
    final serial = _ref.read(serialProvider.notifier);
    // Framing-valid frames (SOF+LEN+CRC) count even before ingest runs.
    if (_latched || serial.validFrameCount > 0) {
      _latched = true;
      // Frames framed by the serial layer before ingest reported any count
      // as life too, so a session never stalls on its very first frame.
      final last = _lastFrameAt ?? serial.lastBytesAt;
      if (last != null && DateTime.now().difference(last) > serialLinkSilence) {
        return SerialLinkStatus.stalled;
      }
      return SerialLinkStatus.connected;
    }
    final lastBytes = serial.lastBytesAt;
    if (lastBytes == null) return SerialLinkStatus.connecting; // silent port
    // Bytes flow but nothing has framed yet: give the stream a short grace
    // (boot-ROM noise), then call it what it is — a broken link.
    _firstBytesAt ??= lastBytes;
    return DateTime.now().difference(_firstBytesAt!) > _firstFrameGrace
        ? SerialLinkStatus.error
        : SerialLinkStatus.connecting;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final serialLinkProvider =
    StateNotifierProvider<SerialLinkNotifier, SerialLinkStatus>((ref) {
  return SerialLinkNotifier(ref);
});
