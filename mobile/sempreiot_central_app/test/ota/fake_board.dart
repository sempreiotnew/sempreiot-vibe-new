import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/crc32.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// The serial port with a board behind it, byte for byte: what the tablet
/// writes is reframed and handled the way the board firmware does
/// (firmware/components/features/siot_ota_board, net/siot_link link_core.c),
/// what the board answers comes back through the tablet's own reframer.
///
/// Both ends have a line speed: bytes sent at one speed to an end that
/// listens at another never make a frame.
class FakeBoard extends SerialNotifier {
  FakeBoard({
    required this.identity,
    this.runningVersion = '0.1.0',
    this.latency = const Duration(milliseconds: 1),
    this.writeTime = const Duration(milliseconds: 2),
    this.verifyTime = const Duration(milliseconds: 20),
    this.restartTime = const Duration(milliseconds: 60),
    this.selfTestTime = const Duration(milliseconds: 200),
    Duration baudSilence = SerialNotifier.defaultBaudSilence,
  }) : super.detached(
          baudSilence: baudSilence,
          baudSettle: const Duration(milliseconds: 2),
        ) {
    _newEncoder();
  }

  static const mac = '7C:4F:AD:AE:85:90';
  static const unitMac = '5A:46:52:00:00:02';

  final SafrIdentity identity;
  final Duration latency;
  final Duration writeTime;
  final Duration verifyTime;
  final Duration restartTime;

  /// How long a new image waits to pass its self-test before it gives up
  /// and the board goes back (120 s on the board).
  final Duration selfTestTime;

  // ── What the test sets ───────────────────────────────────────────────────

  /// OTA_BAUD is never answered (firmware older than v3.5 drops it).
  bool ignoreBaud = false;

  /// OTA_PUSH_* frames are dropped: a board that cannot be updated.
  bool ignorePush = false;

  /// BEGIN is refused with this reason.
  SafrOtaReason? refuseBegin;

  /// The verdict after END: null = ok.
  SafrOtaReason? verdict;

  /// The new image never passes its self-test (the build that fails it on
  /// purpose): it says what it is when it hears the tablet, and after
  /// [selfTestTime] the board goes back to the image it had and says so.
  bool failSelfTest = false;

  /// The OTA_PUSH_RESULT of a self-test that passed is lost on the way.
  bool loseSelfTestResult = false;

  /// Chunks whose raw bytes are damaged on the wire, once each.
  final corruptOnce = <int>{};

  /// Chunks the board writes and whose ACK is lost, once each.
  final dropAckOnce = <int>{};

  /// Chunks that never reach the board (frame and bytes), that many times.
  final loseChunk = <int, int>{};

  /// When chunk `key` arrives for the first time the board is back at chunk
  /// `value`: it wants that one and says so.
  final rewindAt = <int, int>{};

  /// When chunk `key` arrives for the first time the board holds no
  /// transfer any more (it dropped it, or restarted).
  final forgetAt = <int>{};

  /// Called when a chunk was written, with its SEQ.
  void Function(int seq)? onChunkWritten;

  /// Called when the board restarts into an image it verified.
  void Function()? onRestart;

  /// A unit's EVENT with F_ACK_REQ goes up every so many chunks written:
  /// the tablet ACKs it in the middle of the push.
  int eventEveryChunks = 0;

  // ── What the test reads ──────────────────────────────────────────────────

  String runningVersion;
  int bootCtr = 3;
  int boardBaud = SerialNotifier.defaultBaudRate;
  int tabletBaud = SerialNotifier.defaultBaudRate;
  bool plugged = false;

  /// Every write to the port, as it was made.
  final writes = <Uint8List>[];

  /// Frames of the tablet the board authenticated, oldest first.
  final heard = <SafrWireFrame>[];

  /// SEQ of every chunk that arrived whole (header + raw), repeats included.
  final chunksSeen = <int>[];

  /// Images verified: family → bytes.
  final images = <int, Uint8List>{};
  final imageVersions = <int, String>{};

  int get baudCommands => heard
      .where((f) =>
          f.payload is SafrCommandPayload &&
          (f.payload as SafrCommandPayload).cmdRaw == SafrCommand.otaBaud.wire)
      .length;

  int count(SafrMsgType type) => heard.where((f) => f.msgType == type).length;

  int commands(SafrCommand cmd) => heard
      .where((f) =>
          f.payload is SafrCommandPayload &&
          (f.payload as SafrCommandPayload).cmdRaw == cmd.wire)
      .length;

  // ── Board state ──────────────────────────────────────────────────────────

  late SafrEncoder _enc;
  late SafrEncoder _unit;
  _Push? _push;
  final _buf = <int>[];
  int _rawLeft = 0;
  final _raw = <int>[];
  _Chunk? _cur;
  bool _announced = false;
  bool _selftest = false;
  String? _rolledBack;
  int _eventSeq = 100;
  Future<void> _out = Future<void>.value();
  final _timers = <Timer>[];
  bool _disposed = false;

  void _newEncoder() {
    _enc = SafrEncoder(
      srcMac: safrMacToBytes(mac),
      bootCtr: bootCtr,
      systemId: identity.systemId,
      key: identity.key,
    );
    _unit = SafrEncoder(
      srcMac: safrMacToBytes(unitMac),
      bootCtr: 40 + bootCtr,
      systemId: identity.systemId,
      key: identity.key,
    );
  }

  // ── The cable ────────────────────────────────────────────────────────────

  /// The cable goes in: the port opens at the default speed and the board
  /// — which kept running, at the speed it had — sends its heartbeat.
  void plug() {
    plugged = true;
    tabletBaud = SerialNotifier.defaultBaudRate;
    debugSetConnected(true);
    sendHeartbeat();
  }

  void unplug() {
    plugged = false;
    _buf.clear();
    _rawLeft = 0; // the board drops a raw run after 1 s without a byte
    _cur = null;
    debugSetConnected(false);
  }

  /// The board lost power: it is back at the default speed with nothing of
  /// the push.
  void powerCycle() => _boot(runningVersion);

  @override
  Future<bool> portWrite(Uint8List bytes) async {
    if (!plugged) return false;
    writes.add(Uint8List.fromList(bytes));
    // At another speed the board gets noise: no frame comes out of it.
    if (tabletBaud == boardBaud) _rx(bytes);
    return true;
  }

  @override
  Future<bool> portSetBaud(int baud) async {
    if (!plugged) return false;
    tabletBaud = baud;
    return true;
  }

  // ── Bytes in (link_core.c siot_link_stream_feed) ─────────────────────────

  void _rx(Uint8List bytes) {
    var i = 0;
    while (i < bytes.length) {
      if (_rawLeft > 0) {
        final take = _rawLeft < bytes.length - i ? _rawLeft : bytes.length - i;
        _raw.addAll(bytes.sublist(i, i + take));
        _rawLeft -= take;
        i += take;
        if (_rawLeft == 0) _rawComplete();
        continue;
      }
      _buf.add(bytes[i++]);
      _scan();
    }
  }

  void _scan() {
    while (_buf.isNotEmpty) {
      if (_buf[0] != safrSof) {
        _buf.removeAt(0);
        continue;
      }
      if (_buf.length < 4) return;
      final len = (_buf[2] << 8) | _buf[3];
      if (_buf[1] != safrVer3 || len < safrV3MinFrame || len > safrMaxFrame) {
        _buf.removeAt(0);
        continue;
      }
      if (_buf.length < len) return;
      final frame = Uint8List.fromList(_buf.sublist(0, len));
      if (!safrCrcOk(frame)) {
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, len);
      final parsed = parseSafrWireFrame(
        frame,
        key: identity.key,
        expectedSystemId: identity.systemId,
      );
      if (parsed.error == null) _onFrame(parsed);
      if (_rawLeft > 0) return; // what follows is not a frame
    }
  }

  // ── Frames (siot_coordinator.c handle_downlink, siot_ota_board.c) ────────

  void _onFrame(SafrWireFrame f) {
    final lost = _lostChunk(f);
    if (!lost) heard.add(f);

    if (!_announced && !lost) {
      // The first frame of the tablet after a boot.
      _announced = true;
      _announce();
      if (_selftest && !failSelfTest) {
        _selftest = false;
        if (!loseSelfTestResult) {
          _result(SafrOtaPushPhase.ok, 0, 0x01, 0, runningVersion);
        }
      }
      final back = _rolledBack;
      if (back != null) {
        _rolledBack = null;
        _result(SafrOtaPushPhase.failed, SafrOtaReason.selftestFail.wire, 0x01,
            0, back);
      }
    }

    switch (f.msgType) {
      case SafrMsgType.command:
        _onCommand(f, f.payload as SafrCommandPayload);
      case SafrMsgType.timeSync:
        _ack(f.msgId);
      case SafrMsgType.otaPushBegin:
        if (!ignorePush) _onBegin(f, f.payload as SafrOtaPushBeginPayload);
      case SafrMsgType.otaPushChunk:
        _onChunk(f, f.payload as SafrOtaPushChunkPayload, lost: lost);
      case SafrMsgType.otaPushEnd:
        if (!ignorePush) _onEnd(f);
      default:
        break; // ACK, EVENT_LOG_REQ: nothing to answer here
    }
  }

  bool _lostChunk(SafrWireFrame f) {
    final p = f.payload;
    if (f.msgType != SafrMsgType.otaPushChunk ||
        p is! SafrOtaPushChunkPayload) {
      return false;
    }
    final left = loseChunk[p.seq] ?? 0;
    if (left <= 0) return false;
    loseChunk[p.seq] = left - 1;
    return true;
  }

  void _onCommand(SafrWireFrame f, SafrCommandPayload c) {
    if (c.cmdRaw == SafrCommand.otaBaud.wire) {
      if (ignoreBaud) return;
      final baud = SafrOtaBaudArgs.parse(c.args);
      if (baud == null ||
          !const [115200, 230400, 460800, 921600].contains(baud)) {
        _ack(f.msgId, reason: SafrOtaReason.badArgs);
        return;
      }
      _ack(f.msgId); // at the speed the tablet listens on
      boardBaud = baud; // what is queued left at the old speed
      return;
    }
    if (c.cmdRaw == SafrCommand.getDeviceTable.wire) {
      _announce();
      return;
    }
    if (c.cmdRaw == SafrCommand.getInstallation.wire) {
      // The board answers INSTALLATION and no ACK, and the tablet waits 6 s
      // for one before it goes on with its link-up sequence. Here it gets
      // the ACK: the sequence is over in milliseconds and out of the way.
      _ack(f.msgId);
      return;
    }
    _ack(f.msgId); // LINK_CHECK and every device command
  }

  void _onBegin(SafrWireFrame f, SafrOtaPushBeginPayload img) {
    final push = _push;
    if (push != null && push.verify) {
      _ack(f.msgId, reason: SafrOtaReason.busy);
      return;
    }
    if (push != null &&
        push.img.family == img.family &&
        push.img.size == img.size &&
        _same(push.img.sha256, img.sha256)) {
      _result(
          SafrOtaPushPhase.receiving, 0, img.family, push.nextSeq, img.version);
      _ack(f.msgId);
      return;
    }
    _push = null;
    final why = refuseBegin;
    if (why != null) {
      _ack(f.msgId, reason: why);
      return;
    }
    _push = _Push(img);
    _result(SafrOtaPushPhase.receiving, 0, img.family, 0, img.version);
    _ack(f.msgId);
  }

  /// Puts the board in the middle of a push of [image]: it holds the first
  /// [chunks] chunks.
  void holdPartOf(Uint8List image, SafrOtaPushBeginPayload img, int chunks) {
    final push = _Push(img)..nextSeq = chunks;
    push.data.addAll(image.sublist(0, chunks * img.chunk));
    _push = push;
  }

  void _onChunk(SafrWireFrame f, SafrOtaPushChunkPayload c,
      {required bool lost}) {
    // The bytes are on the wire whatever the header says: always read them.
    _cur = _Chunk(c, f.msgId, store: false, lost: lost);
    _rawLeft = c.len;
    _raw.clear();
    if (lost || ignorePush) return;

    if (forgetAt.remove(c.seq)) _push = null;
    final to = rewindAt.remove(c.seq);
    final held = _push;
    if (to != null && held != null) {
      held.nextSeq = to;
      held.data.length = to * held.img.chunk;
    }

    final push = _push;
    if (push == null) {
      _ack(f.msgId, reason: SafrOtaReason.outOfOrder);
      _result(SafrOtaPushPhase.failed, SafrOtaReason.outOfOrder.wire, 0, 0, '');
      return;
    }
    if (push.verify) {
      _ack(f.msgId, reason: SafrOtaReason.busy);
      return;
    }
    if (c.seq < push.nextSeq) {
      _ack(f.msgId); // a repeat of what is written: its ACK was lost
      return;
    }
    final remaining = push.img.size - push.data.length;
    final want = remaining < push.img.chunk ? remaining : push.img.chunk;
    if (c.seq > push.nextSeq || c.len != want) {
      _result(SafrOtaPushPhase.receiving, SafrOtaReason.outOfOrder.wire,
          push.img.family, push.nextSeq, push.img.version);
      _ack(f.msgId, reason: SafrOtaReason.outOfOrder);
      return;
    }
    _cur = _Chunk(c, f.msgId, store: true, lost: false);
  }

  void _rawComplete() {
    final cur = _cur;
    _cur = null;
    final push = _push;
    if (cur == null || cur.lost) return;
    chunksSeen.add(cur.header.seq);
    if (!cur.store || push == null) return;

    final data = Uint8List.fromList(_raw);
    if (corruptOnce.remove(cur.header.seq)) data[data.length ~/ 2] ^= 0x40;
    if (otaCrc32(data) != cur.header.crc32) {
      _ack(cur.msgId, reason: SafrOtaReason.badCrc);
      return;
    }
    push.data.addAll(data);
    push.nextSeq++;
    final seq = cur.header.seq;
    if (!dropAckOnce.remove(seq)) _ack(cur.msgId, after: writeTime);
    if (eventEveryChunks > 0 && push.nextSeq % eventEveryChunks == 0) {
      sendUnitEvent();
    }
    onChunkWritten?.call(seq);
  }

  void _onEnd(SafrWireFrame f) {
    final push = _push;
    if (push == null) {
      _ack(f.msgId, reason: SafrOtaReason.outOfOrder);
      return;
    }
    if (push.verify) {
      _ack(f.msgId);
      return;
    }
    if (push.data.length != push.img.size) {
      _result(SafrOtaPushPhase.receiving, SafrOtaReason.outOfOrder.wire,
          push.img.family, push.nextSeq, push.img.version);
      _ack(f.msgId, reason: SafrOtaReason.outOfOrder);
      return;
    }
    push.verify = true;
    _ack(f.msgId);
    _later(verifyTime, _verdict);
  }

  void _verdict() {
    final push = _push;
    if (push == null || !push.verify) return;
    _push = null;
    final img = push.img;
    final data = Uint8List.fromList(push.data);
    var why = verdict;
    if (why == null && !_same(crypto.sha256.convert(data).bytes, img.sha256)) {
      why = SafrOtaReason.shaFail;
    }
    if (why != null) {
      _result(SafrOtaPushPhase.failed, why.wire, img.family, 0, img.version);
      return;
    }
    images[img.family] = data;
    imageVersions[img.family] = img.version;
    _result(SafrOtaPushPhase.ok, 0, img.family, 0, img.version);
    if (img.family == 0x01) _later(restartTime, () => _restartInto(img));
  }

  void _restartInto(SafrOtaPushBeginPayload img) {
    final old = runningVersion;
    onRestart?.call();
    _boot(img.version);
    _selftest = true;
    if (!failSelfTest) return;
    _later(selfTestTime, () {
      // Nobody passed the self-test: the image the board had is back.
      _boot(old);
      _selftest = false;
      _rolledBack = img.version;
    });
  }

  void _boot(String version) {
    bootCtr++;
    runningVersion = version;
    _newEncoder();
    boardBaud = SerialNotifier.defaultBaudRate;
    _push = null;
    _announced = false;
    _buf.clear();
    _rawLeft = 0;
    _cur = null;
    sendHeartbeat();
  }

  // ── Frames out ───────────────────────────────────────────────────────────

  void sendHeartbeat() => _send(
        SafrMsgType.heartbeat,
        Uint8List.fromList([
          0, 0, 0, 0, 0, 0, 0, 10, //
          0x01, 0xFF, 0x7F, 0xFF, 0x80,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0,
        ]),
        dst: safrBroadcastMacBytes,
      );

  /// A unit's MANUAL_TEST that asks for an ACK: traffic that is not the
  /// push.
  void sendUnitEvent() {
    final seq = _eventSeq++;
    final frame = _unit.encode(
      msgType: SafrMsgType.event,
      payload: Uint8List.fromList([
        0x02, 0x10, 0x68, 0x6E, 0x2F, 0x00, //
        0x05, 85, 0x10, 0x68, 0x02, 0x26, 0x2A, 0x00, 0x00,
        (seq >> 8) & 0xFF, seq & 0xFF,
      ]),
      dstMac: safrCentralMacBytes,
      ackRequired: true,
    );
    _deliver(frame, latency);
  }

  void _announce() => _send(
        SafrMsgType.nameAnnounce,
        SafrNameAnnouncePayload.build(
          name: 'Central',
          zone: '',
          role: SafrNodeRole.unknown,
          productCode: 0x0100,
          hwRev: 1,
          fwVersion: runningVersion,
        ),
      );

  void _result(
    SafrOtaPushPhase phase,
    int reason,
    int family,
    int nextSeq,
    String version,
  ) =>
      _send(
        SafrMsgType.otaPushResult,
        SafrOtaPushResultPayload(
          phase: phase,
          reasonRaw: reason,
          family: family,
          nextSeq: nextSeq,
          version: version,
        ).build(),
      );

  void _ack(int msgId, {SafrOtaReason? reason, Duration? after}) => _send(
        SafrMsgType.ack,
        SafrAckPayload.build(
          ackedMsgId: msgId,
          status: reason == null ? SafrAckStatus.ok : SafrAckStatus.error,
          detailRaw: reason?.wire ?? 0,
        ),
        after: after,
      );

  void _send(
    SafrMsgType type,
    Uint8List payload, {
    Uint8List? dst,
    Duration? after,
  }) {
    final frame = _enc.encode(
      msgType: type,
      payload: payload,
      dstMac: dst ?? safrCentralMacBytes,
    );
    _deliver(frame, after ?? latency);
  }

  /// In the order they were sent, at the speed the board had then.
  void _deliver(Uint8List frame, Duration after) {
    final speed = boardBaud;
    _out = _out.then((_) async {
      await Future<void>.delayed(after);
      if (_disposed || !plugged || speed != tabletBaud) return;
      debugReceive(frame);
    });
  }

  void _later(Duration after, void Function() what) {
    _timers.add(Timer(after, () {
      if (!_disposed) what();
    }));
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }
}

class _Push {
  _Push(this.img);
  final SafrOtaPushBeginPayload img;
  int nextSeq = 0;
  final data = <int>[];
  bool verify = false;
}

class _Chunk {
  _Chunk(this.header, this.msgId, {required this.store, required this.lost});
  final SafrOtaPushChunkPayload header;
  final int msgId;
  final bool store;
  final bool lost;
}
