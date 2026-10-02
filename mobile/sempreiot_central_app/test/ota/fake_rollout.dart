import 'dart:async';
import 'dart:typed_data';

import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

import 'fake_board.dart';

/// What a unit does with an offer.
enum FakePlay {
  /// Downloads, verifies, restarts, passes its self-test: OTA_RESULT ok.
  update,

  /// Refuses the offer: ACK ERROR with the reason, nothing else.
  refuse,

  /// The download breaks: OTA_RESULT not ok with the reason.
  fail,

  /// Installs, restarts and fails its self-test: the image it had comes
  /// back and says SELFTEST_FAIL.
  failSelfTest,

  /// ACKs the offer and does nothing (a firmware of before the rollout).
  silent,
}

/// A mains unit behind the board.
class FakeUnit {
  FakeUnit(
    this.mac, {
    this.name = '',
    this.zone = '',
    this.product = 0x0201,
    this.version = '0.1.0',
    this.online = true,
    this.layer = 2,
    this.parent,
    List<(FakePlay, SafrOtaReason)>? plays,
  }) : plays = plays ?? [(FakePlay.update, SafrOtaReason.none)];

  final String mac;
  final String name;
  final String zone;
  final int product;
  String version;
  bool online;
  int layer;
  String? parent;

  /// What it does offer by offer; the last one repeats.
  final List<(FakePlay, SafrOtaReason)> plays;

  /// Offers it got.
  int offers = 0;
  int bootCtr = 20;
}

class _Row {
  _Row(this.unit) : version = unit.version;
  final FakeUnit unit;
  SafrOtaUnitState state = SafrOtaUnitState.waiting;
  int percent = 0;
  int attempts = 0;
  int reason = 0;
  String version;
  DateTime? changedAt;
  DateTime? ackedAt;
  bool statusSeen = false;

  bool get settled => state.settled;
}

/// The board's rollout and the mesh behind it, played the way the firmware
/// does it (firmware/components/features/siot_ota_board/src/ota_rollout.c,
/// siot_ota_node.c): one unit at a time, the root last, a unit that fails
/// offered once more after the others, OTA_ROLLOUT on every change and
/// every so often while it rolls, the ACK of an OTA_CONTROL ahead of the
/// table that follows it.
///
/// It outlives the [FakeBoard] it is attached to: an app that restarts
/// opens the port again and finds the rollout where it is.
class FakeRollout {
  FakeRollout({
    required this.identity,
    this.step = const Duration(milliseconds: 6),
    this.pageEvery = const Duration(milliseconds: 50),
    this.restartTime = const Duration(milliseconds: 30),
    this.firstStatusTime = const Duration(milliseconds: 80),
    this.percentStep = 50,
    this.entriesPerPage = 8,
  });

  final SafrIdentity identity;

  /// One step of a unit's update, and the board's tick.
  final Duration step;

  /// 5 s on the board.
  final Duration pageEvery;

  /// A unit is silent for this long while it restarts.
  final Duration restartTime;

  /// 30 s on the board: ACK OK and then nothing.
  final Duration firstStatusTime;
  final int percentStep;

  /// Entries in one page (the board fits what fits in 202 bytes).
  int entriesPerPage;

  static const maxAttempts = 2;

  // ── What the test sets ───────────────────────────────────────────────────

  final units = <FakeUnit>[];

  /// Family → version of the image the board holds.
  final stored = <int, String>{};

  /// The unit that is the mesh root: updated last.
  String? rootMac;

  /// An ALARM crossed the board in the last 10 minutes.
  bool alarmRecent = false;

  /// OTA_ROLLOUT pages are not sent (the cable loses them).
  bool mute = false;

  /// Pages with this number are lost on the way, that many times.
  final losePage = <int, int>{};

  // ── What the test reads ──────────────────────────────────────────────────

  SafrOtaRolloutState state = SafrOtaRolloutState.idle;
  int family = 0;
  String target = '';

  /// Every OTA_CONTROL the board decoded, oldest first.
  final controls = <SafrOtaControlArgs>[];

  /// GET_ROLLOUT commands heard.
  int gets = 0;

  /// MACs in the order they were offered the image.
  final offered = <String>[];

  /// Pages sent (lost ones included).
  int pagesSent = 0;

  // ── State ────────────────────────────────────────────────────────────────

  FakeBoard? _board;
  final _rows = <_Row>[];
  int _cur = -1;
  bool _aborted = false;
  Timer? _tick;
  DateTime _nextPage = DateTime.now();
  int _msgId = 900;
  bool _closed = false;

  bool get _live => state.running;

  void attach(FakeBoard board) => _board = board;

  FakeUnit unit(String mac) => units.firstWhere((u) => u.mac == mac);

  SafrOtaUnitState? stateOf(String mac) {
    for (final r in _rows) {
      if (r.unit.mac == mac) return r.state;
    }
    return null;
  }

  void close() {
    _closed = true;
    _tick?.cancel();
  }

  SafrEncoder _encoder(FakeUnit u) => _encoders.putIfAbsent(
        '${u.mac}/${u.bootCtr}',
        () => SafrEncoder(
          srcMac: safrMacToBytes(u.mac),
          bootCtr: u.bootCtr,
          systemId: identity.systemId,
          key: identity.key,
        ),
      );
  final _encoders = <String, SafrEncoder>{};

  // ── The mesh ─────────────────────────────────────────────────────────────

  void _up(
    FakeUnit u,
    SafrMsgType type,
    Uint8List payload, {
    bool ackRequired = false,
    Uint8List? dst,
    int? msgId,
  }) {
    if (_closed) return;
    _board?.relayUp(_encoder(u).encode(
          msgType: type,
          payload: payload,
          dstMac: dst ?? safrBroadcastMacBytes,
          hops: u.layer,
          ackRequired: ackRequired,
          msgId: msgId,
        ));
  }

  /// Every unit says who it is and that it is up: the tablet's registry
  /// then knows name, zone, product, firmware and place in the tree.
  void announceUnits() {
    for (final u in units) {
      if (u.online) announce(u);
    }
  }

  void announce(FakeUnit u) {
    _up(
      u,
      SafrMsgType.nameAnnounce,
      SafrNameAnnouncePayload.build(
        name: u.name,
        zone: u.zone,
        role: u.layer <= 1 ? SafrNodeRole.root : SafrNodeRole.node,
        productCode: u.product,
        hwRev: 1,
        fwVersion: u.version,
      ),
    );
    heartbeat(u);
  }

  void heartbeat(FakeUnit u) {
    final parent = safrMacToBytes(u.parent ?? FakeBoard.mac);
    _up(
      u,
      SafrMsgType.heartbeat,
      Uint8List.fromList([
        0, 0, 0, 0, 0, 0, 0, 30, //
        0x01, 0xFF, 0x7F, 0xFF, 0xC4,
        ...parent, u.layer,
      ]),
    );
  }

  /// A unit goes into alarm: its EVENT goes up (the tablet latches it) and
  /// the board pauses the rollout at its next tick.
  void alarm(String mac, {int devSeq = 7}) {
    final u = unit(mac);
    _up(
      u,
      SafrMsgType.event,
      Uint8List.fromList([
        0x03, 0x01, 0x68, 0x6E, 0x2F, 0x00, //
        0x01, 0xFF, 0x10, 0x68, 0x02, 0x26, 0x2A, 0x00, 0x00,
        (devSeq >> 8) & 0xFF, devSeq & 0xFF,
      ]),
      dst: safrCentralMacBytes,
      ackRequired: true,
    );
    alarmRecent = true;
  }

  // ── Pages (ota_rollout.c send_pages_of_rollout / send_everything) ────────

  void _page(SafrOtaRolloutPayload p) {
    pagesSent++;
    final lose = losePage[p.page] ?? 0;
    if (lose > 0) {
      losePage[p.page] = lose - 1;
      return;
    }
    if (mute || _closed) return;
    _board?.sendToTablet(SafrMsgType.otaRollout, p.build());
  }

  void _pagesOfRollout({int page = 0}) {
    final now = DateTime.now();
    final entries = [
      for (final r in _rows)
        SafrOtaRolloutEntry(
          mac: r.unit.mac,
          productCode: r.unit.product,
          state: r.state,
          percent: r.percent,
          attempts: r.attempts,
          reasonRaw: r.reason,
          ageS: r.changedAt == null
              ? null
              : now.difference(r.changedAt!).inSeconds,
          version: r.version,
        ),
    ];
    final pages =
        entries.isEmpty ? 1 : (entries.length / entriesPerPage).ceil();
    for (var pg = 1; pg <= pages; pg++) {
      if (page != 0 && page != pg) continue;
      final first = (pg - 1) * entriesPerPage;
      final end = first + entriesPerPage < entries.length
          ? first + entriesPerPage
          : entries.length;
      _page(SafrOtaRolloutPayload(
        page: pg,
        pageCount: pages,
        total: _rows.length,
        state: state,
        family: family,
        target: target,
        entries: entries.sublist(first, end),
      ));
    }
  }

  void _staged(int family) {
    final version = stored[family];
    if (version == null) return;
    _page(SafrOtaRolloutPayload(
      page: 1,
      pageCount: 1,
      total: 0,
      state: SafrOtaRolloutState.staged,
      family: family,
      target: version,
    ));
  }

  void _everything(int page) {
    final hasRollout = state != SafrOtaRolloutState.idle &&
        state != SafrOtaRolloutState.staged;
    var any = false;
    for (final f in const [0x02, 0x03]) {
      if (hasRollout && f == family) {
        _pagesOfRollout(page: page);
        any = true;
      } else if (stored.containsKey(f)) {
        _staged(f);
        any = true;
      }
    }
    if (!any) {
      _page(const SafrOtaRolloutPayload(
        page: 1,
        pageCount: 1,
        total: 0,
        state: SafrOtaRolloutState.idle,
        family: 0x02,
        target: '',
      ));
    }
  }

  void _changed() {
    _pagesOfRollout();
    _nextPage = DateTime.now().add(pageEvery);
  }

  // ── The tablet's commands ────────────────────────────────────────────────

  void onGet(Uint8List args) {
    gets++;
    _everything(SafrGetRolloutArgs.parse(args) ?? 0);
  }

  /// A node or leaf image was verified and stored by a push.
  void onStored(int family, String version) {
    stored[family] = version;
    if (this.family == family && state.ended) {
      state = SafrOtaRolloutState.idle; // that rollout was of another image
      _rows.clear();
    }
    _staged(family);
  }

  void onControl(int msgId, Uint8List args) {
    final c = SafrOtaControlArgs.parse(args);
    if (c == null) {
      _board?.ackTablet(msgId, reason: SafrOtaReason.badArgs);
      return;
    }
    controls.add(c);
    SafrOtaReason? why;
    switch (c.action) {
      case SafrOtaAction.start:
        why = _start(c);
      case SafrOtaAction.pause:
        if (!_live || c.family != family) {
          why = SafrOtaReason.badArgs;
        } else {
          state = SafrOtaRolloutState.paused;
        }
      case SafrOtaAction.resume:
        if (!_live || c.family != family) {
          why = SafrOtaReason.badArgs;
        } else if (alarmRecent) {
          why = SafrOtaReason.busyAlarm;
        } else {
          state = SafrOtaRolloutState.rolling;
        }
      case SafrOtaAction.abort:
        if (!_live || c.family != family) {
          why = SafrOtaReason.badArgs;
        } else {
          _aborted = true;
          for (final r in _rows) {
            if (r.state == SafrOtaUnitState.waiting) {
              _set(r, SafrOtaUnitState.skipped, SafrOtaReason.aborted.wire);
            }
          }
          _finishIfDone();
        }
    }
    // The ACK first: the tablet that has it then reads the table.
    _board?.ackTablet(msgId, reason: why);
    if (why == null) _changed();
  }

  bool _passes(FakeUnit u, SafrOtaControlArgs c) {
    if (!u.online) return false;
    if (u.product == 0 || (u.product >> 8) != c.family) return false;
    return switch (c.filter.kind) {
      SafrOtaFilterKind.all => true,
      SafrOtaFilterKind.product => u.product == c.filter.product,
      SafrOtaFilterKind.zone => u.zone == c.filter.zone,
      SafrOtaFilterKind.unit => u.mac == c.filter.mac,
    };
  }

  SafrOtaReason? _start(SafrOtaControlArgs c) {
    if (_live) return SafrOtaReason.busy;
    if (c.family != 0x02 && c.family != 0x03) return SafrOtaReason.badArgs;
    if (alarmRecent) return SafrOtaReason.busyAlarm;
    final version = stored[c.family];
    if (version == null) return SafrOtaReason.badArgs;
    final queue = [
      for (final u in units)
        if (_passes(u, c)) u
    ];
    if (queue.isEmpty) return SafrOtaReason.badArgs;

    _rows
      ..clear()
      ..addAll([
        for (final u in queue) _Row(u)..changedAt = DateTime.now(),
      ]);
    family = c.family;
    target = version;
    _cur = -1;
    _aborted = false;
    state = SafrOtaRolloutState.rolling;
    _tick ??= Timer.periodic(step, (_) => _onTick());
    return null;
  }

  /// The board restarted: the rollout that was running goes on, paused,
  /// from the first unit that is not settled.
  void boardRestarted() {
    if (!_live) return;
    for (final r in _rows) {
      if (!r.settled) {
        r
          ..state = SafrOtaUnitState.waiting
          ..reason = 0
          ..percent = 0
          ..changedAt = DateTime.now();
      }
    }
    _cur = -1;
    _plays++; // whatever a unit was doing is forgotten
    state = SafrOtaRolloutState.paused;
  }

  // ── The tick (ota_rollout_tick) ──────────────────────────────────────────

  void _set(_Row r, SafrOtaUnitState s, int reason) {
    r
      ..state = s
      ..reason = reason
      ..changedAt = DateTime.now();
  }

  void _finishIfDone() {
    if (_cur >= 0) return;
    if (_rows.any((r) => !r.settled)) return;
    final failed = _rows.any((r) => r.state == SafrOtaUnitState.failed);
    final cut = _rows.any((r) =>
        r.state == SafrOtaUnitState.skipped &&
        r.reason == SafrOtaReason.aborted.wire);
    state = failed || cut
        ? SafrOtaRolloutState.partial
        : SafrOtaRolloutState.done;
  }

  void _attemptFailed(_Row r, int reason) {
    if (reason == SafrOtaReason.notNewer.wire) {
      _set(r, SafrOtaUnitState.skipped, reason);
    } else {
      r.attempts++;
      final again = r.attempts < maxAttempts && !_aborted;
      _set(r, again ? SafrOtaUnitState.waiting : SafrOtaUnitState.failed,
          reason);
    }
    r.percent = 0;
    _cur = -1;
    _finishIfDone();
    _changed();
  }

  int _pickNext() {
    var best = -1;
    var bestRank = 99;
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      if (r.state != SafrOtaUnitState.waiting) continue;
      final rank = (r.unit.mac == rootMac ? 2 : 0) + (r.attempts > 0 ? 1 : 0);
      if (rank < bestRank) {
        best = i;
        bestRank = rank;
      }
    }
    return best;
  }

  void _onTick() {
    if (_closed || !_live) return;
    final now = DateTime.now();
    if (state == SafrOtaRolloutState.rolling && alarmRecent) {
      state = SafrOtaRolloutState.paused;
      _changed();
    }
    if (_cur >= 0) {
      final r = _rows[_cur];
      final acked = r.ackedAt;
      if (acked != null &&
          !r.statusSeen &&
          now.difference(acked) > firstStatusTime) {
        r.attempts = maxAttempts - 1; // not offered again in this rollout
        _attemptFailed(r, SafrOtaReason.timedOut.wire);
      }
    } else if (state == SafrOtaRolloutState.rolling) {
      final i = _pickNext();
      if (i >= 0) {
        final r = _rows[i];
        r
          ..ackedAt = null
          ..statusSeen = false
          ..percent = 0;
        _set(r, SafrOtaUnitState.offered, 0);
        _cur = i;
        offered.add(r.unit.mac);
        _changed();
        unawaited(_play(r));
      } else {
        _finishIfDone();
        if (state != SafrOtaRolloutState.rolling) _changed();
      }
    }
    if (_live && !now.isBefore(_nextPage)) {
      _pagesOfRollout();
      _nextPage = now.add(pageEvery);
    }
  }

  // ── A unit and its offer (siot_ota_node.c) ───────────────────────────────

  int _plays = 0;

  Future<void> _play(_Row r) async {
    final mine = ++_plays;
    bool gone() => _closed || mine != _plays || _rows.indexOf(r) != _cur;
    final u = r.unit;
    final (play, reason) = u.plays[
        u.offers < u.plays.length ? u.offers : u.plays.length - 1];
    u.offers++;
    final offerId = _msgId++;
    final boardMac = safrMacToBytes(FakeBoard.mac);

    await Future<void>.delayed(step);
    if (gone()) return;

    if (play == FakePlay.refuse) {
      // The unit's ACK of the board's command goes up like every frame.
      _up(
        u,
        SafrMsgType.ack,
        SafrAckPayload.build(
          ackedMsgId: offerId,
          status: SafrAckStatus.error,
          detailRaw: reason.wire,
        ),
        dst: boardMac,
      );
      _attemptFailed(r, reason.wire);
      return;
    }
    _up(u, SafrMsgType.ack, SafrAckPayload.build(ackedMsgId: offerId),
        dst: boardMac);
    r.ackedAt = DateTime.now();
    if (play == FakePlay.silent) return; // the board's tick gives up on it

    void status(SafrOtaUnitState s, int percent) {
      _up(
        u,
        SafrMsgType.otaStatus,
        SafrOtaStatusPayload(state: s, percent: percent).build(),
      );
      // ota_rollout.c on_uplink: the percent always, a page on a new state.
      r
        ..statusSeen = true
        ..percent = percent;
      if (s != r.state) {
        _set(r, s, 0);
        _changed();
      }
    }

    void result(bool ok, SafrOtaReason why) {
      _up(
        u,
        SafrMsgType.otaResult,
        SafrOtaResultPayload(ok: ok, reasonRaw: why.wire, version: u.version)
            .build(),
        ackRequired: true,
      );
      r.version = u.version;
      if (ok) {
        r.percent = 100;
        _set(r, SafrOtaUnitState.done, 0);
        _cur = -1;
        if (_live) _finishIfDone();
        _changed();
      } else {
        _attemptFailed(r, why.wire);
      }
    }

    for (var p = 0; p <= 100; p += percentStep) {
      status(SafrOtaUnitState.downloading, p);
      await Future<void>.delayed(step);
      if (gone()) return;
      if (play == FakePlay.fail && p >= 50) {
        result(false, reason);
        return;
      }
    }
    status(SafrOtaUnitState.verifying, 100);
    await Future<void>.delayed(step);
    if (gone()) return;
    status(SafrOtaUnitState.rebooting, 100);

    // It restarts: silent, and another boot when it is back.
    final old = u.version;
    u
      ..online = false
      ..bootCtr += 1;
    await Future<void>.delayed(restartTime);
    u.online = true;
    if (gone()) return;

    if (play == FakePlay.failSelfTest) {
      // The new image never confirmed itself; the one it had is back.
      u.bootCtr += 1;
      announce(u);
      result(false, SafrOtaReason.selftestFail);
      return;
    }
    u.version = target;
    announce(u);
    status(SafrOtaUnitState.selfTest, 100);
    await Future<void>.delayed(step);
    if (gone()) {
      u.version = old;
      return;
    }
    result(true, SafrOtaReason.none);
  }
}
