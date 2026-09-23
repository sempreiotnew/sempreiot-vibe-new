import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_encoder.dart';
import '../domain/safr/safr_identity.dart';
import 'central_installation_provider.dart';
import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'safr_traffic_provider.dart';
import 'serial_link_provider.dart';
import 'serial_provider.dart';

/// Central → root downlink (docs/safr/protocol-safr-v3.md §7.5–7.9, §9):
/// - ACKs uplink frames that carry F_ACK_REQ (called by the ingest pipeline);
/// - sends TIME_SYNC on link-up and hourly so device timestamps become real;
/// - sends LINK_CHECK every 30 s — downlink path supervision (§9.3,
///   UL 864 integrity / EN 54-25 both-directions verification);
/// - requests the root's event journal on link-up (§7.8 — EN 54-25
///   "no alarm lost") and paginates until the root answers EMPTY;
/// - sends COMMANDs with pending-ACK tracking: 3 attempts / 2 s backoff, then
///   a TROUBLE "comando sem confirmação" event;
/// - RESET (§7.1.4): the ONLY path that clears the alarm latch, and only
///   after the root confirms.
class SafrDownlink {
  SafrDownlink(this._ref);

  static const _retryBackoff = Duration(seconds: 2);
  static const _retryMax = 3;
  static const _linkCheckPeriod = Duration(seconds: 30);
  static const _jrnSeqMetaKey = 'safr_jrn_seq';

  final Ref _ref;
  SafrEncoder _encoder = SafrEncoder();
  final _pending = <int, _PendingTx>{};
  Timer? _hourlySync;
  Timer? _linkCheck;
  bool _linkCheckFailing = false;
  bool _journalDraining = false;
  int _jrnHighWater = 0;

  /// Re-keys the encoder for the imported installation. A fresh BOOT_CTR
  /// keeps CCM nonces unique across the switch (spec §9.1); MSG_ID restarts,
  /// which is fine because nothing is pending before the link is up.
  void setIdentity(SafrIdentity id) {
    _encoder = SafrEncoder(systemId: id.systemId, key: id.key);
  }

  void start() {
    setIdentity(_ref.read(safrIdentityProvider));
    _ref.listen<SafrIdentity>(safrIdentityProvider, (_, next) {
      setIdentity(next);
    });
    _ref.listen<SerialLinkStatus>(serialLinkProvider, (prev, next) {
      if (next == SerialLinkStatus.connected &&
          prev != SerialLinkStatus.connected) {
        _onLinkUp();
      }
    });
    _hourlySync = Timer.periodic(const Duration(hours: 1), (_) {
      if (_connected) sendTimeSync();
    });
    _linkCheck = Timer.periodic(_linkCheckPeriod, (_) {
      if (_connected) _sendLinkCheck();
    });
  }

  bool get _connected =>
      _ref.read(serialLinkProvider) == SerialLinkStatus.connected;

  Future<void> _onLinkUp() async {
    await sendTimeSync();
    await requestJournalBackfill();
    await sendGetInstallation();
  }

  /// v3.1 (spec §7.6): asks the board for its installation identity and
  /// enrolled device list over the serial link. The board's INSTALLATION
  /// reply is routed by the ingest pipeline, not here.
  Future<void> sendGetInstallation() {
    return _sendTracked(
      msgType: SafrMsgType.command,
      payload: SafrCommandPayload.build(cmd: SafrCommand.getInstallation),
      dstMac: safrBroadcastMacBytes,
      description: 'consulta de instalação',
      notifyOnFail: false, // best-effort — the app still works without it
    ).then((_) {});
  }

  Future<bool> _write(Uint8List frame) =>
      _ref.read(serialProvider.notifier).write(frame);

  /// ACKs a validated uplink frame — spec §9.1: process once, ACK every time.
  Future<void> sendAck(SafrWireFrame source) async {
    final frame = _encoder.encode(
      msgType: SafrMsgType.ack,
      payload: SafrAckPayload.build(ackedMsgId: source.msgId),
      dstMac: safrMacToBytes(source.srcMac),
    );
    await _write(frame);
    _ref.read(safrTrafficProvider).emit(SafrTrafficTick(
          mac: source.srcMac,
          direction: SafrTrafficDirection.downlink,
          severity: 0,
        ));
  }

  /// Root confirmed one of our F_ACK_REQ frames.
  void handleAck(SafrAckPayload ack) {
    final pending = _pending.remove(ack.ackedMsgId);
    if (pending == null) return;
    pending.retryTimer?.cancel();
    if (!pending.completer.isCompleted) {
      pending.completer.complete(ack.status == SafrAckStatus.ok);
    }
  }

  Future<void> sendTimeSync() async {
    final payload = SafrTimeSyncPayload.build(
      utcNow: DateTime.now().toUtc(),
      tzOffset: DateTime.now().timeZoneOffset,
    );
    await _sendTracked(
      msgType: SafrMsgType.timeSync,
      payload: payload,
      dstMac: safrBroadcastMacBytes,
      description: 'sincronização de horário',
    );
  }

  /// Sends a COMMAND to a device (or broadcast). Completes true when the
  /// root ACKs, false on timeout/error.
  Future<bool> sendCommand(
    String dstMac,
    SafrCommand cmd, {
    List<int> args = const [],
  }) {
    return _sendTracked(
      msgType: SafrMsgType.command,
      payload: SafrCommandPayload.build(cmd: cmd, args: args),
      dstMac: safrMacToBytes(dstMac),
      description: 'comando ${cmd.name}',
      targetMac: dstMac,
    );
  }

  /// Operator alarm reset (spec §7.1.4 — UL 864/NFPA 72). Clears the central
  /// latch ONLY after the root ACKs; returns false (latch kept) otherwise.
  Future<bool> sendReset(String dstMac) async {
    final ok = await sendCommand(dstMac, SafrCommand.reset);
    if (ok) {
      await _ref.read(appDatabaseProvider).clearAlarmLatch(mac: dstMac);
    }
    return ok;
  }

  // ── Downlink supervision (§9.3) ────────────────────────────────

  Future<void> _sendLinkCheck() async {
    final ok = await _sendTracked(
      msgType: SafrMsgType.command,
      payload: SafrCommandPayload.build(cmd: SafrCommand.linkCheck),
      dstMac: safrBroadcastMacBytes,
      description: 'verificação de enlace',
      notifyOnFail: false, // edge-triggered trouble below, not one per miss
    );
    if (!ok && !_linkCheckFailing && _connected) {
      _linkCheckFailing = true;
      await _insertSyntheticEvent(
        severity: 1,
        kind: 'link_check_failed',
        description:
            'Enlace de descida sem confirmação (LINK_CHECK) — §9.3',
      );
    } else if (ok && _linkCheckFailing) {
      _linkCheckFailing = false;
      await _insertSyntheticEvent(
        severity: 0,
        kind: 'link_check_restored',
        description: 'Enlace de descida restabelecido',
      );
    }
  }

  // ── Journal backfill (§7.8/§7.9) ───────────────────────────────

  /// Asks the root for every journaled event the central hasn't seen.
  /// EVENT_LOG_REQ carries no F_ACK_REQ — the EVENT_LOG_DATA stream is the
  /// confirmation; ingest routes each entry to [handleJournalData].
  Future<void> requestJournalBackfill() async {
    final db = _ref.read(appDatabaseProvider);
    _jrnHighWater = int.tryParse(await db.getMeta(_jrnSeqMetaKey) ?? '') ?? 0;
    _journalDraining = true;
    await _sendJournalReq(_jrnHighWater);
  }

  Future<void> _sendJournalReq(int since) async {
    final frame = _encoder.encode(
      msgType: SafrMsgType.eventLogReq,
      payload: SafrEventLogReqPayload.build(sinceJrnSeq: since),
    );
    await _write(frame);
  }

  /// Called by ingest for every EVENT_LOG_DATA. Tracks the JRN_SEQ
  /// high-water mark and paginates until the root reports EMPTY.
  void handleJournalData(SafrEventLogDataPayload log) {
    final db = _ref.read(appDatabaseProvider);

    if (log.isEmpty) {
      // Root's top is lower than ours ⇒ its journal was reset (spec §8):
      // adopt the lower mark so the next backfill starts from there.
      if (log.jrnSeq < _jrnHighWater) {
        _jrnHighWater = log.jrnSeq;
        db.setMeta(_jrnSeqMetaKey, '$_jrnHighWater');
      }
      _journalDraining = false;
      return;
    }

    if (log.jrnSeq > _jrnHighWater) {
      _jrnHighWater = log.jrnSeq;
      db.setMeta(_jrnSeqMetaKey, '$_jrnHighWater');
    }
    if (log.isLast && _journalDraining) {
      // Batch done, maybe more remain — ask again; the EMPTY reply ends it.
      _sendJournalReq(_jrnHighWater);
    }
  }

  // ── Tracked send with fast retries (§9.1) ──────────────────────

  Future<bool> _sendTracked({
    required SafrMsgType msgType,
    required Uint8List payload,
    required Uint8List dstMac,
    required String description,
    String? targetMac,
    bool notifyOnFail = true,
  }) async {
    final frame = _encoder.encode(
      msgType: msgType,
      payload: payload,
      dstMac: dstMac,
      ackRequired: true,
    );
    final msgId = _encoder.lastMsgId;

    final pending = _PendingTx(
      msgType: msgType,
      payload: payload,
      dstMac: dstMac,
      description: description,
      targetMac: targetMac,
      notifyOnFail: notifyOnFail,
    );
    _pending[msgId] = pending;
    _scheduleRetry(msgId);

    final sent = await _write(frame);
    _emitTick(targetMac);
    if (!sent) {
      _giveUp(msgId, notify: false);
      return false;
    }
    return pending.completer.future;
  }

  void _scheduleRetry(int msgId) {
    final pending = _pending[msgId];
    if (pending == null) return;
    pending.retryTimer = Timer(_retryBackoff, () async {
      final p = _pending[msgId];
      if (p == null) return;
      if (p.attempts >= _retryMax) {
        _giveUp(msgId, notify: p.notifyOnFail);
        return;
      }
      p.attempts++;
      // Same MSG_ID (receiver dedupes), fresh MSG_CTR (nonce never reused).
      final frame = _encoder.encode(
        msgType: p.msgType,
        payload: p.payload,
        dstMac: p.dstMac,
        ackRequired: true,
        msgId: msgId,
      );
      await _write(frame);
      _emitTick(p.targetMac);
      _scheduleRetry(msgId);
    });
  }

  void _giveUp(int msgId, {required bool notify}) {
    final pending = _pending.remove(msgId);
    if (pending == null) return;
    pending.retryTimer?.cancel();
    if (!pending.completer.isCompleted) pending.completer.complete(false);
    if (!notify) return;

    debugPrint('[SAFR] downlink $msgId (${pending.description}) sem ACK');
    _insertSyntheticEvent(
      severity: 1,
      kind: 'command_unconfirmed',
      description: pending.description,
      deviceMac: pending.targetMac,
    );
  }

  Future<void> _insertSyntheticEvent({
    required int severity,
    required String kind,
    required String description,
    String? deviceMac,
  }) async {
    final db = _ref.read(appDatabaseProvider);
    await db.into(db.deviceEvents).insert(DeviceEventsCompanion.insert(
          receivedAt: DateTime.now().toUtc(),
          deviceMac: deviceMac ?? safrCentralMac,
          msgType: 0, // synthetic
          severity: severity,
          detailJson: jsonEncode({
            'synthetic': true,
            'kind': kind,
            'description': description,
          }),
        ));
  }

  void _emitTick(String? targetMac) {
    if (targetMac == null) return;
    _ref.read(safrTrafficProvider).emit(SafrTrafficTick(
          mac: targetMac,
          direction: SafrTrafficDirection.downlink,
          severity: 0,
        ));
  }

  void dispose() {
    _hourlySync?.cancel();
    _linkCheck?.cancel();
    for (final p in _pending.values) {
      p.retryTimer?.cancel();
      if (!p.completer.isCompleted) p.completer.complete(false);
    }
    _pending.clear();
  }
}

class _PendingTx {
  _PendingTx({
    required this.msgType,
    required this.payload,
    required this.dstMac,
    required this.description,
    this.targetMac,
    this.notifyOnFail = true,
  });

  final SafrMsgType msgType;
  final Uint8List payload;
  final Uint8List dstMac;
  final String description;
  final String? targetMac;
  final bool notifyOnFail;
  final completer = Completer<bool>();
  Timer? retryTimer;
  int attempts = 1;
}

final safrDownlinkProvider = Provider<SafrDownlink>((ref) {
  final downlink = SafrDownlink(ref)..start();
  ref.onDispose(downlink.dispose);
  return downlink;
});
