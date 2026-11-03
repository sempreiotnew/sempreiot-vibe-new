import 'dart:async';

import 'package:flutter/foundation.dart';
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
/// - `stalled` for [serialLinkReopenAfter] more ⇒ the port is closed and
///   opened again, and again every [serialLinkReopenEvery] while the silence
///   lasts: an adapter that stayed enumerated through a locked screen or a
///   frozen process can hold a read that never completes, and a fresh open
///   is the only way back. The status stays `stalled` through the re-open —
///   it is the same silence, not a new port, so one trouble is written, not
///   one per attempt — until a frame proves the board is back;
/// - port open, bytes flowing, but nothing ever validates ⇒ `error`
///   (wrong firmware/baud/corruption — never silently "Conectando");
/// - port open and silent from the start ⇒ `connecting`;
/// - no port ⇒ `disconnected`.
enum SerialLinkStatus { disconnected, connecting, connected, stalled, error }

/// Grace period for the first valid frame once bytes start flowing.
const _firstFrameGrace = Duration(seconds: 5);

/// Silence after the last valid frame that turns `connected` into `stalled`.
const serialLinkSilence = Duration(seconds: 20);

/// `stalled` for this long ⇒ the port is re-opened a first time.
const serialLinkReopenAfter = Duration(seconds: 20);

/// Still `stalled` ⇒ re-opened again this often.
const serialLinkReopenEvery = Duration(seconds: 30);

class SerialLinkNotifier extends StateNotifier<SerialLinkStatus> {
  /// [tick], [silence], [reopenAfter], [reopenEvery] and [reopen] exist for
  /// tests; the app uses the defaults and the serial notifier's own re-open.
  SerialLinkNotifier(
    this._ref, {
    Duration tick = const Duration(seconds: 1),
    this.silence = serialLinkSilence,
    this.reopenAfter = serialLinkReopenAfter,
    this.reopenEvery = serialLinkReopenEvery,
    Future<void> Function()? reopen,
  })  : _reopen = reopen,
        super(SerialLinkStatus.disconnected) {
    _timer = Timer.periodic(tick, (_) => _recompute());
    _ref.listen<SerialStatus>(serialProvider, (prev, next) {
      // A port that closed or failed is a new story. A port we are
      // re-opening ourselves (`connecting`, then `connected` and silent) is
      // the same stall: keep what the last session proved.
      final newPort = next == SerialStatus.disconnected ||
          next == SerialStatus.error ||
          (next == SerialStatus.connecting && !_reopening);
      if (newPort) {
        _latched = false;
        _firstBytesAt = null;
        _lastFrameAt = null;
        _reopening = false;
      }
      _recompute();
    });
    _recompute();
  }

  final Ref _ref;
  final Duration silence;
  final Duration reopenAfter;
  final Duration reopenEvery;
  final Future<void> Function()? _reopen;
  Timer? _timer;

  /// Set by the first valid frame of the current port session.
  bool _latched = false;

  /// When the first raw bytes of the current session arrived.
  DateTime? _firstBytesAt;

  /// Last frame that proved the board is talking (valid or auth-failed).
  DateTime? _lastFrameAt;

  /// Since when the link is `stalled`; null otherwise.
  DateTime? _stalledSince;

  /// The last re-open asked during the current stall; null before the first.
  DateTime? _lastReopenAt;

  /// A re-open was asked and no frame came since: the port's own
  /// `connecting` → `connected` is not a new port.
  bool _reopening = false;

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
      SerialStatus.connecting =>
        _reopening ? SerialLinkStatus.stalled : SerialLinkStatus.connecting,
      SerialStatus.connected => _sessionState(),
    };
    if (next != state) state = next;
    _maybeReopen(next);
  }

  SerialLinkStatus _sessionState() {
    final serial = _ref.read(serialProvider.notifier);
    // Framing-valid frames (SOF+LEN+CRC) count even before ingest runs.
    if (_latched || serial.validFrameCount > 0) {
      _latched = true;
      // Frames framed by the serial layer before ingest reported any count
      // as life too, so a session never stalls on its very first frame.
      final last = _lastFrameAt ?? serial.lastBytesAt;
      if (last != null && DateTime.now().difference(last) > silence) {
        return SerialLinkStatus.stalled;
      }
      // A frame since the re-open: the board is back.
      _reopening = false;
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

  /// A stall that lasts gets the port re-opened: once after [reopenAfter],
  /// then every [reopenEvery] until a frame ends the stall.
  void _maybeReopen(SerialLinkStatus next) {
    if (next != SerialLinkStatus.stalled) {
      _stalledSince = null;
      _lastReopenAt = null;
      return;
    }
    final now = DateTime.now();
    _stalledSince ??= now;
    final since = _lastReopenAt ?? _stalledSince!;
    final wait = _lastReopenAt == null ? reopenAfter : reopenEvery;
    if (now.difference(since) < wait) return;
    _lastReopenAt = now;
    _reopening = true;
    debugPrint('[SerialLink] board silent for '
        '${now.difference(_stalledSince!).inSeconds} s: re-opening the port');
    // Outside this recompute: the re-open moves the port's state, and that
    // comes back here through the listener.
    scheduleMicrotask(() {
      if (!mounted) return;
      final reopen = _reopen ?? _ref.read(serialProvider.notifier).reopen;
      reopen().catchError(
          (Object e) => debugPrint('[SerialLink] re-open failed: $e'));
    });
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
