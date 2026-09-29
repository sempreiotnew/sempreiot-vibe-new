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
import 'safr_ingest_provider.dart' show setupChannelProvider;
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
      // The board went silent behind an open port (spec §9.3): one trouble
      // for the site, restored when its frames come back.
      if (next == SerialLinkStatus.stalled) {
        _insertSyntheticEvent(
          severity: 1,
          kind: 'board_silent',
          description:
              'Placa sem resposta há ${serialLinkSilence.inSeconds} s — '
              'instalação sem supervisão',
        );
      } else if (prev == SerialLinkStatus.stalled &&
          next == SerialLinkStatus.connected) {
        _insertSyntheticEvent(
          severity: 0,
          kind: 'board_restored',
          description: 'Placa voltou a responder',
        );
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
    await sendGetDeviceTable();
  }

  /// v3.2 (spec §7.6 0x18): asks the board for its device table; the pages
  /// come back as DEVICE_TABLE frames routed by ingest. No ACK expected.
  /// v3.5: always asks for the entries with the product fields (format 1);
  /// an older board ignores that byte and answers in the v3.2 layout.
  Future<void> sendGetDeviceTable({int page = 0}) async {
    final frame = _encoder.encode(
      msgType: SafrMsgType.command,
      payload: SafrCommandPayload.build(
          cmd: SafrCommand.getDeviceTable,
          args: SafrGetDeviceTableArgs.build(page: page)),
      dstMac: safrBroadcastMacBytes,
    );
    await _write(frame);
  }

  // ── v3.2 lifecycle commands (spec §7.6, lifecycle §5) ─────────────

  /// Result of a lifecycle command: `ok` from the board's ACK, `detail`
  /// explains a refusal, null detail = no ACK at all (timeout).
  Future<LifecycleResult> _lifecycle({
    required SafrCommand cmd,
    required Uint8List args,
    required Uint8List dstMac,
    required String description,
    String? targetMac,
  }) async {
    final ack = await _sendTrackedAck(
      msgType: SafrMsgType.command,
      payload: SafrCommandPayload.build(cmd: cmd, args: args),
      dstMac: dstMac,
      description: description,
      targetMac: targetMac,
    );
    if (ack == null) return const LifecycleResult(false, null);
    return LifecycleResult(ack.status == SafrAckStatus.ok, ack.detail);
  }

  Future<LifecycleResult> sendSetDevice(String mac, String name, String zone) =>
      _lifecycle(
        cmd: SafrCommand.setDevice,
        args: SafrSetDeviceArgs(mac: mac, name: name, zone: zone).build(),
        dstMac: safrMacToBytes(mac),
        description: 'renomear dispositivo',
        targetMac: mac,
      );

  Future<LifecycleResult> sendRetireDevice(String mac) => _lifecycle(
        cmd: SafrCommand.retireDevice,
        args: SafrMacArgs.build(mac),
        dstMac: safrBroadcastMacBytes,
        description: 'aposentar dispositivo',
        targetMac: mac,
      );

  Future<LifecycleResult> sendUnretireDevice(String mac) => _lifecycle(
        cmd: SafrCommand.unretireDevice,
        args: SafrMacArgs.build(mac),
        dstMac: safrBroadcastMacBytes,
        description: 'reativar dispositivo',
        targetMac: mac,
      );

  Future<LifecycleResult> sendReplaceDevice(String oldMac, String newMac) =>
      _lifecycle(
        cmd: SafrCommand.replaceDevice,
        args: SafrReplaceDeviceArgs.build(oldMac: oldMac, newMac: newMac),
        dstMac: safrBroadcastMacBytes,
        description: 'substituir dispositivo',
        targetMac: oldMac,
      );

  /// Remote factory reset: DST must be the unit itself (never broadcast).
  Future<LifecycleResult> sendDecommission(String mac) => _lifecycle(
        cmd: SafrCommand.decommission,
        args: SafrMacArgs.build(mac),
        dstMac: safrMacToBytes(mac),
        description: 'apagar dispositivo da placa',
        targetMac: mac,
      );

  Future<LifecycleResult> sendForgetDevice(String mac) => _lifecycle(
        cmd: SafrCommand.forgetDevice,
        args: SafrMacArgs.build(mac),
        dstMac: safrBroadcastMacBytes,
        description: 'esquecer dispositivo',
        targetMac: mac,
      );

  // ── Setup channel (spec §3.1 v3.2, lifecycle §4.1 / §5 B) ─────────

  /// Runs [body] with the setup-channel identity open: frames from the
  /// board under SYSTEM_ID 0x0000 are then accepted by ingest.
  Future<T> _withSetupChannel<T>(
      Uint8List setupKey, Future<T> Function(SafrEncoder enc) body) async {
    final identity = SafrIdentity(systemId: 0, key: setupKey);
    _ref.read(setupChannelProvider.notifier).state = identity;
    final enc = SafrEncoder(systemId: 0, key: setupKey);
    try {
      return await body(enc);
    } finally {
      _ref.read(setupChannelProvider.notifier).state = null;
    }
  }

  /// Case B: writes [code] into a board in SETUP. The board ACKs then reboots.
  Future<LifecycleResult> sendSetInstallation(
      Uint8List setupKey, SafrInstallationCode code, String boardMac) {
    return _withSetupChannel(setupKey, (enc) async {
      final ack = await _sendTrackedAck(
        msgType: SafrMsgType.command,
        payload: SafrCommandPayload.build(
            cmd: SafrCommand.setInstallation, args: code.build()),
        dstMac: safrMacToBytes(boardMac),
        description: 'gravar instalação na placa',
        encoder: enc,
      );
      if (ack == null) return const LifecycleResult(false, null);
      return LifecycleResult(ack.status == SafrAckStatus.ok, ack.detail);
    });
  }

  Completer<SafrInstallationCode>? _codeWaiter;

  /// Called by ingest for a CODE frame on the setup channel.
  void handleCode(SafrInstallationCode code) {
    final w = _codeWaiter;
    if (w != null && !w.isCompleted) w.complete(code);
  }

  /// "Ler código da placa": proves the board sticker and pulls the code over
  /// USB (lifecycle §4.1). Null on timeout (wrong pop, board in setup, or
  /// firmware without v3.2).
  Future<SafrInstallationCode?> sendGetCode(Uint8List setupKey) {
    return _withSetupChannel(setupKey, (enc) async {
      final waiter = _codeWaiter = Completer<SafrInstallationCode>();
      for (var attempt = 0; attempt < _retryMax; attempt++) {
        final frame = enc.encode(
          msgType: SafrMsgType.command,
          payload: SafrCommandPayload.build(cmd: SafrCommand.getCode),
          dstMac: safrBroadcastMacBytes,
        );
        await _write(frame);
        try {
          return await waiter.future.timeout(_retryBackoff);
        } on TimeoutException {
          continue;
        }
      }
      _codeWaiter = null;
      return null;
    });
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
    // The cyan packet going down = the unit's cyan LED: the tablet's ACK for
    // an EVENT it sent. Heartbeats are ACKed on the wire too (spec §7.5) but
    // the parent never hands those to a leaf, so they never light a LED and
    // never travel the map.
    if (source.msgType == SafrMsgType.event) {
      _ref.read(safrTrafficProvider).emit(SafrTrafficTick(
            mac: source.srcMac,
            direction: SafrTrafficDirection.downlink,
            severity: 0,
            ack: true,
            msgType: SafrMsgType.ack,
          ));
    }
  }

  /// Root confirmed one of our F_ACK_REQ frames.
  void handleAck(SafrAckPayload ack) {
    final pending = _pending.remove(ack.ackedMsgId);
    if (pending == null) return;
    pending.retryTimer?.cancel();
    if (!pending.completer.isCompleted) pending.completer.complete(ack);
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
  /// [dstMac] = one device, or [safrBroadcastMac] for a system-wide reset.
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
        description: 'Enlace de descida sem confirmação (LINK_CHECK) — §9.3',
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
    final ack = await _sendTrackedAck(
      msgType: msgType,
      payload: payload,
      dstMac: dstMac,
      description: description,
      targetMac: targetMac,
      notifyOnFail: notifyOnFail,
    );
    return ack != null && ack.status == SafrAckStatus.ok;
  }

  /// Like [_sendTracked] but hands back the ACK itself (status + v3.2
  /// DETAIL), or null when the root never confirmed. [encoder] overrides the
  /// installation encoder for the setup channel.
  Future<SafrAckPayload?> _sendTrackedAck({
    required SafrMsgType msgType,
    required Uint8List payload,
    required Uint8List dstMac,
    required String description,
    String? targetMac,
    bool notifyOnFail = true,
    SafrEncoder? encoder,
  }) async {
    final enc = encoder ?? _encoder;
    final frame = enc.encode(
      msgType: msgType,
      payload: payload,
      dstMac: dstMac,
      ackRequired: true,
    );
    final msgId = enc.lastMsgId;

    final pending = _PendingTx(
      msgType: msgType,
      payload: payload,
      dstMac: dstMac,
      description: description,
      targetMac: targetMac,
      notifyOnFail: notifyOnFail,
      encoder: enc,
    );
    _pending[msgId] = pending;
    _scheduleRetry(msgId);

    final sent = await _write(frame);
    _emitTick(targetMac);
    if (!sent) {
      _giveUp(msgId, notify: false);
      return null;
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
      final frame = p.encoder.encode(
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
    if (!pending.completer.isCompleted) pending.completer.complete(null);
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
          msgType: SafrMsgType.command,
        ));
  }

  void dispose() {
    _hourlySync?.cancel();
    _linkCheck?.cancel();
    for (final p in _pending.values) {
      p.retryTimer?.cancel();
      if (!p.completer.isCompleted) p.completer.complete(null);
    }
    _pending.clear();
  }
}

/// Outcome of a v3.2 lifecycle command (spec §7.5 DETAIL).
class LifecycleResult {
  const LifecycleResult(this.ok, this.detail);
  final bool ok;

  /// Null = the root never ACKed (timeout).
  final SafrAckDetail? detail;

  String get message => ok
      ? 'Confirmado pela placa.'
      : detail == null
          ? 'A placa não confirmou. Verifique o cabo USB.'
          : detail == SafrAckDetail.none
              ? 'Recusado pela placa.'
              : 'Recusado: ${detail!.label}.';
}

class _PendingTx {
  _PendingTx({
    required this.msgType,
    required this.payload,
    required this.dstMac,
    required this.description,
    required this.encoder,
    this.targetMac,
    this.notifyOnFail = true,
  });

  final SafrMsgType msgType;
  final Uint8List payload;
  final Uint8List dstMac;
  final String description;
  final SafrEncoder encoder;
  final String? targetMac;
  final bool notifyOnFail;
  final completer = Completer<SafrAckPayload?>();
  Timer? retryTimer;
  int attempts = 1;
}

final safrDownlinkProvider = Provider<SafrDownlink>((ref) {
  final downlink = SafrDownlink(ref)..start();
  ref.onDispose(downlink.dispose);
  return downlink;
});
