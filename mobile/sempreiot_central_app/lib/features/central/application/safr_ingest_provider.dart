import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_parser.dart';
import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';
import '../domain/safr/safr_identity.dart';
import 'central_installation_provider.dart';
import 'ota_board_events_provider.dart';
import 'ota_rollout_events_provider.dart';
import 'board_sync_provider.dart';
import 'safr_downlink_provider.dart';
import 'safr_traffic_provider.dart';
import 'serial_link_provider.dart';
import 'serial_provider.dart';

/// Compliance posture (docs/safr/protocol-safr-v3.md §4.1 — UL 864 / EN 54-25):
/// plaintext frames never update device state. Flip only on a debug bench.
const kSafrAllowPlaintext =
    bool.fromEnvironment('SAFR_ALLOW_PLAINTEXT', defaultValue: false);

/// This installation's SYSTEM_ID (spec §3.1). Development value until
/// provisioning assigns per-installation identities.
const kSafrSystemId = safrDevSystemId;

/// Parse-on-ingest pipeline (docs/safr/protocol-safr-v3.md §10): every serial frame
/// is stored raw in SerialPackets (forensics), then decoded once into the
/// trusted MeshDevices registry + the humanized DeviceEvents feed.
/// Unauthenticated frames NEVER update device state — they only produce
/// diagnostic feed rows. Accepted ALARMs latch (§7.1.4) until operator RESET.
/// Silence after which the replay guard forgets a unit's last counters
/// (the board's `SAFR_REPLAY_FORGET_MS` says the same).
const replayForget = Duration(minutes: 10);

class SafrIngestService {
  SafrIngestService({
    required this.db,
    this.identity,
    this.onValidFrame,
    this.onInvalidFrame,
    this.onAckRequired,
    this.onAckReceived,
    this.onJournalData,
    this.onTraffic,
    this.onForeignSystem,
    this.setupIdentity,
    this.onCode,
    this.onOtaBoardEvent,
    this.onOtaRolloutEvent,
    this.onDeviceTableSynced,
  });

  /// The board's DEVICE_TABLE arrived complete (its last page): every MAC
  /// it lists. Ends a "Sincronizar com a placa" (board_sync_provider).
  final void Function(Set<String> listed)? onDeviceTableSynced;

  final AppDatabase db;

  /// Resolves the (SYSTEM_ID, SAFR_PSK) to authenticate with, per frame, so
  /// an installation imported while running takes effect immediately.
  /// Null = the bench default [SafrIdentity.dev].
  final SafrIdentity Function()? identity;
  final void Function()? onValidFrame;
  final void Function()? onInvalidFrame;
  final Future<void> Function(SafrWireFrame frame)? onAckRequired;

  /// [srcMac]: who confirms — the board, or the unit a COMMAND was for.
  final void Function(SafrAckPayload ack, String srcMac)? onAckReceived;

  /// Journal replay bookkeeping (spec §7.9) — the downlink service persists
  /// the JRN_SEQ high-water mark and paginates with further EVENT_LOG_REQs.
  final void Function(SafrEventLogDataPayload log)? onJournalData;
  final void Function(String mac, int severity, String? parentMac,
      SafrMsgType msgType, SafrEventCode? eventCode, int? uptimeS)? onTraffic;

  /// A frame whose header SYSTEM_ID is not ours (spec §3.1 "neighbouring
  /// system"). Null = ours again (a valid frame arrived). Feeds the
  /// "A placa pertence a outra instalação" banner (lifecycle §7).
  final void Function(int? foreignSystemId)? onForeignSystem;

  /// Setup channel (spec §3.1 v3.2): while the tablet talks to the board
  /// under SYSTEM_ID 0x0000 with the sticker-derived key, frames that fail
  /// the installation key are re-parsed with this identity. Null = closed.
  final SafrIdentity? Function()? setupIdentity;

  /// CODE (spec §7.13) received on the setup channel.
  final void Function(SafrInstallationCode code)? onCode;

  /// Firmware push (spec §13.3): every OTA_PUSH_RESULT, every
  /// NAME_ANNOUNCE of a unit of the board family (the version it runs) and
  /// every HEARTBEAT of the board itself (LAYER 0: it is up).
  final void Function(OtaBoardEvent event)? onOtaBoardEvent;

  /// Rollout (spec §13.4, §13.6): every OTA_ROLLOUT page of the board and
  /// every OTA_STATUS / OTA_RESULT of a unit — once each: a replay or a
  /// retransmission of one already handled is ACKed and not handed over.
  final void Function(OtaRolloutEvent event)? onOtaRolloutEvent;

  /// Recent (SRC_MAC, MSG_ID) pairs → dedupes fast retransmissions of
  /// non-EVENT frames (same MSG_ID, fresh MSG_CTR — spec §9.1). EVENTs are
  /// deduped exactly, by (SRC_MAC, DEV_SEQ), against the database.
  final _recentMsgIds = <String, DateTime>{};

  Future<void> handleFrame(Uint8List bytes, {required String deviceId}) async {
    final packetId = await db.into(db.serialPackets).insert(
          SerialPacketsCompanion.insert(
            receivedAt: DateTime.now().toUtc(),
            deviceId: deviceId,
            rawBytes: bytes,
            byteLength: bytes.length,
            hexPreview: _hexPreview(bytes),
          ),
        );

    final id = identity?.call() ?? SafrIdentity.dev;
    final result = parseSafr(bytes, key: id.key, expectedSystemId: id.systemId);
    if (result is! SafrWireResult) return; // v1/invalid: raw log only
    final frame = result.frame;
    final now = DateTime.now().toUtc();

    if (frame.error != null) {
      if (frame.error == SafrWireError.foreignSystem && frame.systemId == 0) {
        final setup = setupIdentity?.call();
        if (setup != null && await _handleSetupChannel(bytes, setup)) return;
      }
      onInvalidFrame?.call();
      if (frame.error == SafrWireError.foreignSystem) {
        onForeignSystem?.call(frame.systemId);
      }
      await _insertDiagnostic(frame, packetId, now);
      return;
    }

    // Spec §4.1: plaintext is a bench-debug facility. In production posture
    // it is logged and dropped — no state update, no ACK.
    if (!frame.isEncrypted && !kSafrAllowPlaintext) {
      onInvalidFrame?.call();
      await _insertDiagnostic(frame, packetId, now,
          overrideKind: 'plaintext_rejected');
      return;
    }

    onValidFrame?.call();
    onForeignSystem?.call(null);

    final severity = frame.payload is SafrEventPayload
        ? (frame.payload as SafrEventPayload).eventType.severity
        : 0;
    final framedParent = switch (frame.payload) {
      SafrHeartbeatPayload p => p.parentMac,
      SafrTopologyPayload p => p.parentMac,
      _ => null,
    };
    onTraffic?.call(
      frame.srcMac,
      severity,
      framedParent,
      frame.msgType,
      frame.payload is SafrEventPayload
          ? (frame.payload as SafrEventPayload).eventCode
          : null,
      frame.payload is SafrHeartbeatPayload
          ? (frame.payload as SafrHeartbeatPayload).uptimeS
          : null,
    );

    if (frame.msgType == SafrMsgType.ack && frame.payload is SafrAckPayload) {
      // Only an ACK addressed to the tablet confirms a frame of the tablet.
      // A unit's ACK of a command of the board (OTA_OFFER, spec §13.4) is
      // relayed up like every uplink frame and carries a MSG_ID of the
      // board's own sequence: it must never confirm the tablet's frame that
      // happens to have the same number.
      if (frame.dstMac == safrCentralMac || frame.isDstBroadcast) {
        onAckReceived?.call(frame.payload as SafrAckPayload, frame.srcMac);
      }
      return;
    }

    if (frame.msgType == SafrMsgType.eventLogData &&
        frame.payload is SafrEventLogDataPayload) {
      await _handleJournalData(
          frame, frame.payload as SafrEventLogDataPayload, packetId, now);
      return;
    }

    if (frame.msgType == SafrMsgType.installation &&
        frame.payload is SafrInstallationPayload) {
      await _handleInstallation(frame.payload as SafrInstallationPayload, now);
    }

    if (frame.msgType == SafrMsgType.deviceTable &&
        frame.payload is SafrDeviceTablePayload) {
      await _handleDeviceTable(frame.payload as SafrDeviceTablePayload, now);
      return; // the board's own reply: not a device to register
    }

    // v3.8 (spec §14.2): the board's zone / endereçamento tables, a kind
    // per page set — its own reply, like the device table.
    if (frame.msgType == SafrMsgType.labelTable &&
        frame.payload is SafrLabelTablePayload) {
      await _handleLabelTable(frame.payload as SafrLabelTablePayload);
      return;
    }

    // Firmware push (spec §13.3): the board's report goes to the push in
    // the order it arrived. Like an ACK above, it is handed over with no
    // wait but the raw log every frame has, so a RESULT the board sent
    // ahead of an ACK is known when that ACK is handled.
    if (frame.msgType == SafrMsgType.otaPushResult &&
        frame.payload is SafrOtaPushResultPayload) {
      onOtaBoardEvent?.call(OtaPushResultEvent(
        srcMac: frame.srcMac,
        bootCtr: frame.bootCtr,
        result: frame.payload as SafrOtaPushResultPayload,
      ));
      if (frame.ackRequired) await onAckRequired?.call(frame);
      return; // the board's own report: not a device to register
    }

    // Rollout (spec §13.6): the board's table, page by page. Its own
    // report, handed over in the order it arrived.
    if (frame.msgType == SafrMsgType.otaRollout &&
        frame.payload is SafrOtaRolloutPayload) {
      onOtaRolloutEvent
          ?.call(OtaRolloutPageEvent(frame.payload as SafrOtaRolloutPayload));
      if (frame.ackRequired) await onAckRequired?.call(frame);
      return; // the board's own report: not a device to register
    }

    final trusted = await _updateTrustedState(frame, packetId, now);
    final accepted = trusted.eventId;

    // A unit's update progress and result (spec §13.4), relayed by the
    // board: after the unit's row was refreshed (it was heard).
    if (trusted.fresh) {
      switch (frame.payload) {
        case SafrOtaStatusPayload status
            when frame.msgType == SafrMsgType.otaStatus:
          onOtaRolloutEvent
              ?.call(OtaUnitStatusEvent(mac: frame.srcMac, status: status));
        case SafrOtaResultPayload result
            when frame.msgType == SafrMsgType.otaResult:
          onOtaRolloutEvent
              ?.call(OtaUnitResultEvent(mac: frame.srcMac, result: result));
        default:
          break;
      }
    }

    final heartbeat = frame.payload;
    if (heartbeat is SafrHeartbeatPayload && heartbeat.layer == 0) {
      onOtaBoardEvent?.call(BoardHeartbeatEvent(
        srcMac: frame.srcMac,
        bootCtr: frame.bootCtr,
      ));
    }

    // The board says what it runs (spec §7.11): after the row was updated,
    // so whoever hears this reads the new version there too.
    final announce = frame.payload;
    if (frame.msgType == SafrMsgType.nameAnnounce &&
        announce is SafrNameAnnouncePayload &&
        _knownFw(announce.fwVersion) != null &&
        SafrProductFamily.ofCode(announce.productCode ?? 0) ==
            SafrProductFamily.board) {
      onOtaBoardEvent?.call(BoardAnnounceEvent(
        srcMac: frame.srcMac,
        bootCtr: frame.bootCtr,
        fwVersion: announce.fwVersion!,
      ));
    }

    // Spec §9.1: process once, ACK every time (even duplicates/replays).
    // Except a HEARTBEAT (spec §7.5): only a battery leaf's asks for an ACK,
    // and its parent's ACK is the one that counts — by the time the
    // tablet's could arrive the leaf sleeps, and the parent drops it
    // (siot_leafmgr.c forwards only ACKs that close an EVENT in custody).
    // Answering would cost a frame each way on the cable and one copy
    // through every node of the mesh, per leaf, per minute.
    if (frame.ackRequired && frame.msgType != SafrMsgType.heartbeat) {
      await onAckRequired?.call(frame);
      if (accepted != null) {
        await (db.update(db.deviceEvents)..where((t) => t.id.equals(accepted)))
            .write(DeviceEventsCompanion(ackedAt: Value(now)));
      }
    }
  }

  /// Journal replay (spec §7.9 — EN 54-25 "no alarm lost"): the inner event
  /// goes through the same acceptance rules as a live one — DEV_SEQ dedupe,
  /// latching — flagged as historic in the feed.
  Future<void> _handleJournalData(
    SafrWireFrame frame,
    SafrEventLogDataPayload log,
    int packetId,
    DateTime now,
  ) async {
    onJournalData?.call(log);
    final event = log.event;
    if (log.isEmpty || event == null) return;

    await db.transaction(() async {
      final existing = await (db.select(db.meshDevices)
            ..where((t) => t.mac.equals(log.origSrcMac)))
          .getSingleOrNull();
      if (await _isDuplicateEvent(log.origSrcMac, event.devSeq)) return;
      await _upsertDeviceFromEvent(log.origSrcMac, existing, event, now);
      await _insertEvent(
        srcMac: log.origSrcMac,
        msgId: frame.msgId,
        hops: frame.hops,
        p: event,
        packetId: packetId,
        now: now,
        historic: true,
        jrnSeq: log.jrnSeq,
      );
    });
  }

  /// `eventId`: the inserted DeviceEvents id when an EVENT row was created.
  /// `fresh`: the frame is neither a replay nor a retransmission of one
  /// already handled.
  Future<({int? eventId, bool fresh})> _updateTrustedState(
    SafrWireFrame frame,
    int packetId,
    DateTime now,
  ) async {
    return db.transaction(() async {
      final existing = await (db.select(db.meshDevices)
            ..where((t) => t.mac.equals(frame.srcMac)))
          .getSingleOrNull();

      // Replay detection (spec §4): equal-or-older counters from the same
      // boot are replays — never let them touch trusted state. A unit silent
      // for [replayForget] is a new life whatever its counters say
      // (2026-10-29, lifecycle §5 L): a reflashed unit restarted counting
      // and its first frames were dropped against its previous life.
      if (existing != null &&
          now.difference(existing.lastSeenAt) < replayForget &&
          frame.bootCtr == existing.lastBootCtr &&
          frame.msgCtr <= existing.lastMsgCtr) {
        return (eventId: null, fresh: false);
      }

      final event = frame.msgType == SafrMsgType.event &&
              frame.payload is SafrEventPayload
          ? frame.payload as SafrEventPayload
          : null;

      // Duplicate suppression (spec §9.1): EVENTs dedupe exactly by
      // (SRC_MAC, DEV_SEQ) — this absorbs the 60 s F_RETX re-announcements
      // (NFPA 72) without double-alarming; other types by MSG_ID window.
      bool isDuplicate;
      if (event != null && event.devSeq != null) {
        isDuplicate = await _isDuplicateEvent(frame.srcMac, event.devSeq);
      } else {
        // BOOT_CTR is part of the identity: a retransmission comes from
        // the same boot; a unit that restarted (into a new firmware, §13.4)
        // counts its MSG_IDs from the start again.
        final dedupeKey = '${frame.srcMac}#${frame.bootCtr}#${frame.msgId}';
        _recentMsgIds.removeWhere(
            (_, at) => now.difference(at) > const Duration(seconds: 30));
        isDuplicate = _recentMsgIds.containsKey(dedupeKey);
        _recentMsgIds[dedupeKey] = now;
      }

      await _upsertDevice(frame, existing, now);
      if (isDuplicate) return (eventId: null, fresh: false);

      if (event != null) {
        final id = await _insertEvent(
          srcMac: frame.srcMac,
          msgId: frame.msgId,
          hops: frame.hops,
          p: event,
          packetId: packetId,
          now: now,
          retx: frame.isRetx,
        );
        return (eventId: id, fresh: true);
      }
      return (eventId: null, fresh: true);
    });
  }

  Future<bool> _isDuplicateEvent(String mac, int? devSeq) async {
    if (devSeq == null || devSeq == 0) return false;
    final row = await (db.select(db.deviceEvents)
          ..where((t) => t.deviceMac.equals(mac) & t.devSeq.equals(devSeq))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  Future<void> _upsertDevice(
    SafrWireFrame frame,
    MeshDevice? existing,
    DateTime now,
  ) async {
    final payload = frame.payload;
    var role = existing?.role ?? SafrNodeRole.unknown.wire;
    var layer = existing?.layer ?? frame.hops;
    String? parentMac = existing?.parentMac;
    int? rssi = existing?.lastRssi;
    int? battery = existing?.batteryPct;
    DateTime? lastHb = existing?.lastHeartbeatAt;
    var lastDevSeq = existing?.lastDevSeq ?? 0;
    var alarmLatched = existing?.alarmLatched ?? 0;
    var alarmLatchedAt = existing?.alarmLatchedAt;
    var parentCandidates = existing?.parentCandidates;
    var dlHeard = existing?.dlHeard;

    switch (payload) {
      case SafrHeartbeatPayload p:
        layer = p.layer;
        parentMac = p.parentMac;
        rssi = p.rssiToParent ?? rssi;
        // What this heartbeat says, nothing older: a mains unit sends no
        // battery (0xFF) and must not keep one from a battery life of the
        // same MAC (2026-10-29).
        battery = p.batteryPct;
        lastHb = now;
        // v3.6 DL_HEARD: what this heartbeat says, nothing older — a
        // 20-byte heartbeat or a restarted window (0xFF) clears it.
        dlHeard = p.dlHeard;
        // The role from THIS frame, every time (2026-10-29): a battery leaf
        // asks its parent for an ACK on every heartbeat (spec §4 F_ACK_REQ,
        // §12.2); a mains unit never does. Then the layer: the board (0) and
        // the mesh root (1) are "root", layer 2+ relays. The old rule "once a
        // leaf, always a leaf" kept a unit reflashed as a mains product drawn
        // as a battery one for ever; units are swapped and reflashed often,
        // so nothing about a MAC's past may outlive what it sends now.
        role = frame.ackRequired
            ? SafrNodeRole.leaf.wire
            : (p.layer <= 1 ? SafrNodeRole.root.wire : SafrNodeRole.node.wire);
        // A unit that is not a leaf has no parent candidates (spec §12.7).
        if (role != SafrNodeRole.leaf.wire) parentCandidates = null;
      case SafrTopologyPayload p:
        role = p.role.wire;
        layer = p.layer;
        parentMac = p.parentMac;
        rssi = p.rssiToParent ?? rssi;
        if (p.role == SafrNodeRole.leaf) {
          // Spec §12.7: a leaf's "children" are the parents it heard.
          parentCandidates = jsonEncode([
            for (final c in p.children) {'mac': c.mac, 'rssi': c.rssi},
          ]);
        }
      case SafrEventPayload p:
        battery = p.batteryPct ?? battery;
        if (p.devSeq != null && p.devSeq! > lastDevSeq) {
          lastDevSeq = p.devSeq!;
        }
        // Alarm latch (spec §7.1.4 — UL 864/NFPA 72): set on ALARM, cleared
        // only by clearAlarmLatch() after an operator RESET. RESTORE events
        // deliberately do NOT touch it.
        if (p.eventType == SafrEventType.alarm && alarmLatched == 0) {
          alarmLatched = 1;
          alarmLatchedAt = now;
        }
      default:
        break;
    }

    // v3.1 (spec §7.11): the operator-chosen name, announced once by the
    // device itself — always wins over whatever INSTALLATION guessed. (The
    // zone slot of that frame is reserved since v3.8: ignored.)
    var name = existing?.name;
    var registryState = existing?.registryState;
    // v3.5 product identity: kept across every frame that does not carry it.
    var productCode = existing?.productCode;
    var hwRev = existing?.hwRev;
    var fwVersion = existing?.fwVersion;
    if (payload case SafrNameAnnouncePayload p) {
      name = p.name;
      // v3.2 trailing ROLE byte: a leaf says so on its very first frame.
      if (p.role != SafrNodeRole.unknown) role = p.role.wire;
      // v3.5 extension: the unit's own word, as said (2026-10-29). A unit
      // that carries the fields and says PRODUCT 0 is not in the catalogue
      // NOW (reflashed as a devkit, say) and the old product must not stay.
      // Only an announce without the fields (older firmware) leaves the
      // known values alone.
      if (p.hasProductFields) {
        productCode = _knownProduct(p.productCode);
        hwRev = _knownHwRev(p.hwRev);
        fwVersion = _knownFw(p.fwVersion) ?? fwVersion;
      }
    }
    // Spec §13.4: an OTA_RESULT's VERSION is what the unit runs NOW — the
    // new image, or the old one after a rollback. A leaf says its name only
    // once per installation, so without this the tablet kept showing the
    // version it had before the update.
    if (payload case SafrOtaResultPayload p) {
      fwVersion = _knownFw(p.version) ?? fwVersion;
    }
    // Hearing directly from a device (any frame) means it's live — supersedes
    // the 'enrolled' marker INSTALLATION may have set before this ever arrived.
    if (registryState == 'enrolled') registryState = null;

    await db.into(db.meshDevices).insertOnConflictUpdate(
          MeshDevicesCompanion(
            mac: Value(frame.srcMac),
            role: Value(role),
            layer: Value(layer),
            parentMac: Value(parentMac),
            lastRssi: Value(rssi),
            batteryPct: Value(battery),
            firstSeenAt: Value(existing?.firstSeenAt ?? now),
            lastSeenAt: Value(now),
            lastHeartbeatAt: Value(lastHb),
            lastBootCtr: Value(frame.bootCtr),
            lastMsgCtr: Value(frame.msgCtr),
            // Owned by the supervision provider: it flips this flag and
            // emits the missing/restored events on the state edges.
            supervisionState: Value(existing?.supervisionState ?? 0),
            name: Value(name),
            registryState: Value(registryState),
            lastDevSeq: Value(lastDevSeq),
            alarmLatched: Value(alarmLatched),
            alarmLatchedAt: Value(alarmLatchedAt),
            parentCandidates: Value(parentCandidates),
            productCode: Value(productCode),
            hwRev: Value(hwRev),
            fwVersion: Value(fwVersion),
            dlHeard: Value(dlHeard),
            // Owned by the supervision provider (spec §9.4 degraded link).
            linkDegraded: Value(existing?.linkDegraded ?? 0),
          ),
        );
  }

  // v3.5 product fields: what counts as "the frame says something".
  static int? _knownProduct(int? code) =>
      code == null || code == safrProductUnknown ? null : code;
  static int? _knownHwRev(int? rev) => rev == null || rev == 0 ? null : rev;
  static String? _knownFw(String? fw) => fw == null || fw.isEmpty ? null : fw;

  /// Registry update for a journal-replayed event: the frame counters belong
  /// to the root, so only event-derived fields (battery, DEV_SEQ, latch) are
  /// touched — never the replay-protection counters of the origin device.
  Future<void> _upsertDeviceFromEvent(
    String mac,
    MeshDevice? existing,
    SafrEventPayload p,
    DateTime now,
  ) async {
    var lastDevSeq = existing?.lastDevSeq ?? 0;
    if (p.devSeq != null && p.devSeq! > lastDevSeq) lastDevSeq = p.devSeq!;
    var alarmLatched = existing?.alarmLatched ?? 0;
    var alarmLatchedAt = existing?.alarmLatchedAt;
    if (p.eventType == SafrEventType.alarm && alarmLatched == 0) {
      alarmLatched = 1;
      alarmLatchedAt = now;
    }

    await db.into(db.meshDevices).insertOnConflictUpdate(
          MeshDevicesCompanion(
            mac: Value(mac),
            role: Value(existing?.role ?? SafrNodeRole.unknown.wire),
            layer: Value(existing?.layer ?? 0),
            parentMac: Value(existing?.parentMac),
            lastRssi: Value(existing?.lastRssi),
            batteryPct: Value(p.batteryPct ?? existing?.batteryPct),
            firstSeenAt: Value(existing?.firstSeenAt ?? now),
            lastSeenAt: Value(existing?.lastSeenAt ?? now),
            lastHeartbeatAt: Value(existing?.lastHeartbeatAt),
            lastBootCtr: Value(existing?.lastBootCtr ?? 0),
            lastMsgCtr: Value(existing?.lastMsgCtr ?? 0),
            supervisionState: Value(existing?.supervisionState ?? 0),
            name: Value(existing?.name),
            registryState: Value(existing?.registryState),
            lastDevSeq: Value(lastDevSeq),
            alarmLatched: Value(alarmLatched),
            alarmLatchedAt: Value(alarmLatchedAt),
            productCode: Value(existing?.productCode),
            hwRev: Value(existing?.hwRev),
            fwVersion: Value(existing?.fwVersion),
          ),
        );
  }

  /// Reply to GET_INSTALLATION (spec §7.6/§7.10, v3.1): seeds a registry row
  /// for every enrolled device not yet heard from directly, so the app can
  /// show its name/zone before its first live frame arrives. Never touches a
  /// device that has already reported itself (registryState == null there).
  Future<void> _handleInstallation(
    SafrInstallationPayload installation,
    DateTime now,
  ) async {
    for (final device in installation.enrolled) {
      final existing = await (db.select(db.meshDevices)
            ..where((t) => t.mac.equals(device.mac)))
          .getSingleOrNull();
      if (existing != null && existing.registryState != 'enrolled') {
        continue; // already known live — don't downgrade or overwrite it
      }
      await db.into(db.meshDevices).insertOnConflictUpdate(
            MeshDevicesCompanion(
              mac: Value(device.mac),
              role: Value(existing?.role ?? SafrNodeRole.unknown.wire),
              layer: Value(existing?.layer ?? 0),
              parentMac: Value(existing?.parentMac),
              lastRssi: Value(existing?.lastRssi),
              batteryPct: Value(existing?.batteryPct),
              firstSeenAt: Value(existing?.firstSeenAt ?? now),
              lastSeenAt: Value(existing?.lastSeenAt ?? now),
              lastHeartbeatAt: Value(existing?.lastHeartbeatAt),
              lastBootCtr: Value(existing?.lastBootCtr ?? 0),
              lastMsgCtr: Value(existing?.lastMsgCtr ?? 0),
              supervisionState: Value(existing?.supervisionState ?? 0),
              name: Value(existing?.name ?? device.name),
              registryState: const Value('enrolled'),
              lastDevSeq: Value(existing?.lastDevSeq ?? 0),
              alarmLatched: Value(existing?.alarmLatched ?? 0),
              alarmLatchedAt: Value(existing?.alarmLatchedAt),
              productCode: Value(existing?.productCode),
              hwRev: Value(existing?.hwRev),
              fwVersion: Value(existing?.fwVersion),
            ),
          );
    }
  }

  /// Setup channel (spec §3.1): only ACK and CODE are accepted there.
  Future<bool> _handleSetupChannel(Uint8List bytes, SafrIdentity setup) async {
    final result = parseSafr(bytes, key: setup.key, expectedSystemId: 0);
    if (result is! SafrWireResult) return false;
    final frame = result.frame;
    if (frame.error != null || !frame.isEncrypted) return false;
    if (frame.msgType == SafrMsgType.ack && frame.payload is SafrAckPayload) {
      onAckReceived?.call(frame.payload as SafrAckPayload, frame.srcMac);
      return true;
    }
    if (frame.msgType == SafrMsgType.code && frame.payload is SafrCodePayload) {
      onCode?.call((frame.payload as SafrCodePayload).code);
      return true;
    }
    return false;
  }

  /// v3.2 DEVICE_TABLE (spec §7.12, lifecycle §3): mirror the board's table
  /// into the registry. Rows the board lists get its state/flags/name/zone
  /// (the board's annotation wins over what this tablet guessed) and, from
  /// v3.5, product / hardware revision / firmware version; after the
  /// last page, rows the board no longer lists and that were only ever
  /// board-sourced are pruned.
  final _tableSeen = <String>{};

  Future<void> _handleDeviceTable(
      SafrDeviceTablePayload page, DateTime now) async {
    if (page.page == 1) _tableSeen.clear();
    for (final e in page.entries) {
      _tableSeen.add(e.mac);
      final existing = await (db.select(db.meshDevices)
            ..where((t) => t.mac.equals(e.mac)))
          .getSingleOrNull();
      final live = existing != null && existing.registryState != 'enrolled';
      await db.into(db.meshDevices).insertOnConflictUpdate(
            MeshDevicesCompanion(
              mac: Value(e.mac),
              role: Value(e.role == SafrNodeRole.unknown
                  ? (existing?.role ?? SafrNodeRole.unknown.wire)
                  : e.role.wire),
              layer: Value(existing?.layer ?? 0),
              parentMac: Value(existing?.parentMac),
              lastRssi: Value(existing?.lastRssi),
              batteryPct: Value(existing?.batteryPct),
              firstSeenAt: Value(existing?.firstSeenAt ?? now),
              lastSeenAt: Value(existing?.lastSeenAt ??
                  (e.lastSeenAgeS == null
                      ? now
                      : now.subtract(Duration(seconds: e.lastSeenAgeS!)))),
              lastHeartbeatAt: Value(existing?.lastHeartbeatAt),
              lastBootCtr: Value(existing?.lastBootCtr ?? 0),
              lastMsgCtr: Value(existing?.lastMsgCtr ?? 0),
              supervisionState: Value(existing?.supervisionState ?? 0),
              name: Value(e.name.isNotEmpty ? e.name : existing?.name),
              registryState: Value(live ? null : 'enrolled'),
              lastDevSeq: Value(existing?.lastDevSeq ?? 0),
              alarmLatched: Value(existing?.alarmLatched ?? 0),
              alarmLatchedAt: Value(existing?.alarmLatchedAt),
              boardState: Value(e.state.wire),
              boardFlags: Value(e.flags),
              tableSyncedAt: Value(now),
              // v3.5: only what the board actually knows; a v3.2 page (or
              // a 0 / empty field) leaves the stored values alone.
              productCode:
                  Value(_knownProduct(e.productCode) ?? existing?.productCode),
              hwRev: Value(_knownHwRev(e.hwRev) ?? existing?.hwRev),
              fwVersion: Value(_knownFw(e.fwVersion) ?? existing?.fwVersion),
              // v3.8 (format 2): the board's ids are the truth; an older
              // page leaves what this tablet holds.
              zoneId: Value(page.hasLabelFields ? e.zoneId : existing?.zoneId),
              addressId: Value(
                  page.hasLabelFields ? e.addressId : existing?.addressId),
              linkKind: Value(
                  page.hasLabelFields ? e.linkKind : existing?.linkKind ?? 0),
            ),
          );
    }
    if (page.isLastPage) {
      final listed = Set.of(_tableSeen);
      await db.pruneUnlistedBoardRows(listed);
      _tableSeen.clear();
      onDeviceTableSynced?.call(listed);
    }
  }

  /// LABEL_TABLE pages of one kind, gathered until the last; the tablet's
  /// copy then becomes exactly the board's table (spec §14.2).
  final _labelPages = <SafrLabelKind, Map<int, String>>{};

  Future<void> _handleLabelTable(SafrLabelTablePayload page) async {
    final gathered = page.page == 1
        ? (_labelPages[page.kind] = <int, String>{})
        : (_labelPages[page.kind] ??= <int, String>{});
    for (final l in page.labels) {
      gathered[l.id] = l.name;
    }
    if (page.isLastPage) {
      _labelPages.remove(page.kind);
      await db.replaceLabels(page.kind.wire, gathered);
    }
  }

  Future<int> _insertEvent({
    required String srcMac,
    required int msgId,
    required int hops,
    required SafrEventPayload p,
    required int packetId,
    required DateTime now,
    bool retx = false,
    bool historic = false,
    int? jrnSeq,
  }) {
    return db.into(db.deviceEvents).insert(DeviceEventsCompanion.insert(
          receivedAt: now,
          deviceMac: srcMac,
          msgType: SafrMsgType.event.wire,
          eventType: Value(p.eventTypeRaw),
          eventCode: Value(p.eventCodeRaw),
          severity: p.eventType.severity,
          packetId: Value(packetId),
          devSeq: Value(p.devSeq),
          detailJson: jsonEncode({
            'msg_id': msgId,
            'hops': hops,
            'device_ts': p.timestamp.toIso8601String(),
            'battery_pct': p.batteryPct,
            'smoke_raw': p.smokeRaw,
            'temp_tenths': p.tempTenths,
            'humidity_pct': p.humidityPct,
            'ac_ok': p.acOk,
            'on_battery': p.onBattery,
            'charging': p.charging,
            'tamper': p.tamper,
            'fault_flags': p.faultFlags,
            'fault_code': p.faultCode,
            if (retx) 'retx': true,
            if (historic) 'historic': true,
            if (jrnSeq != null) 'jrn_seq': jrnSeq,
          }),
        ));
  }

  Future<void> _insertDiagnostic(
    SafrWireFrame frame,
    int packetId,
    DateTime now, {
    String? overrideKind,
  }) async {
    final errorKind = overrideKind ??
        switch (frame.error!) {
          SafrWireError.authFailed => 'auth_failed',
          SafrWireError.crcFailed => 'crc_failed',
          SafrWireError.foreignSystem => 'foreign_system',
          _ => 'parse_error',
        };
    await db.into(db.deviceEvents).insert(DeviceEventsCompanion.insert(
          receivedAt: now,
          deviceMac: frame.srcMac.isEmpty ? '?' : frame.srcMac,
          msgType: frame.msgTypeRaw,
          severity: 1, // trouble: the link needs attention
          errorKind: Value(errorKind),
          packetId: Value(packetId),
          detailJson: jsonEncode({
            'error': errorKind,
            'msg_id': frame.msgId,
            'len': frame.lenField,
            if (frame.systemId != null) 'system_id': frame.systemId,
          }),
        ));
  }
}

String _hexPreview(Uint8List bytes) {
  final end = bytes.length < 32 ? bytes.length : 32;
  return bytes
      .sublist(0, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
}

/// Wires the ingest pipeline to the live serial stream. Watched once at
/// central-mode startup (main.dart).
final safrIngestProvider = Provider<SafrIngestService>((ref) {
  final serial = ref.watch(serialProvider.notifier);
  final link = ref.read(serialLinkProvider.notifier);
  final downlink = ref.read(safrDownlinkProvider);
  final traffic = ref.read(safrTrafficProvider);
  final otaBus = ref.read(otaBoardBusProvider);
  final rolloutBus = ref.read(otaRolloutBusProvider);

  final service = SafrIngestService(
    db: ref.watch(appDatabaseProvider),
    identity: () => ref.read(safrIdentityProvider),
    onForeignSystem: (sid) {
      final notifier = ref.read(foreignSystemIdProvider.notifier);
      if (notifier.state != sid) notifier.state = sid;
    },
    setupIdentity: () => ref.read(setupChannelProvider),
    onCode: downlink.handleCode,
    onOtaBoardEvent: otaBus.emit,
    onOtaRolloutEvent: rolloutBus.emit,
    onValidFrame: link.reportValidFrame,
    onInvalidFrame: link.reportInvalidFrame,
    onAckRequired: downlink.sendAck,
    onAckReceived: (ack, src) => downlink.handleAck(ack, srcMac: src),
    onDeviceTableSynced: (listed) =>
        ref.read(boardSyncProvider.notifier).tableArrived(listed),
    onJournalData: downlink.handleJournalData,
    onTraffic: (mac, severity, parentMac, msgType, eventCode, uptimeS) =>
        traffic.emit(SafrTrafficTick(
      mac: mac,
      direction: SafrTrafficDirection.uplink,
      severity: severity,
      parentMac: parentMac,
      msgType: msgType,
      eventCode: eventCode,
      uptimeS: uptimeS,
    )),
  );

  final sub = serial.dataStream.listen((bytes) {
    service.handleFrame(bytes, deviceId: serial.connectedDeviceId ?? 'unknown');
  });
  ref.onDispose(sub.cancel);
  return service;
});

/// SYSTEM_ID seen in the header of the last frame the board sent that was
/// NOT ours (null once a frame authenticates). The tablet shows a banner:
/// the board belongs to another installation, or the wrong backup was
/// imported here (lifecycle §7).
final foreignSystemIdProvider = StateProvider<int?>((_) => null);

/// The setup-channel identity (SYSTEM_ID 0x0000, key from the board sticker)
/// while a SET_INSTALLATION / GET_CODE exchange is in flight; null otherwise.
final setupChannelProvider = StateProvider<SafrIdentity?>((_) => null);
