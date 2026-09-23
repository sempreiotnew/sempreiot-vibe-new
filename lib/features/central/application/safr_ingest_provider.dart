import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_parser.dart';
import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';
import '../domain/safr/safr_identity.dart';
import 'central_installation_provider.dart';
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
  });

  final AppDatabase db;

  /// Resolves the (SYSTEM_ID, SAFR_PSK) to authenticate with, per frame, so
  /// an installation imported while running takes effect immediately.
  /// Null = the bench default [SafrIdentity.dev].
  final SafrIdentity Function()? identity;
  final void Function()? onValidFrame;
  final void Function()? onInvalidFrame;
  final Future<void> Function(SafrWireFrame frame)? onAckRequired;
  final void Function(SafrAckPayload ack)? onAckReceived;

  /// Journal replay bookkeeping (spec §7.9) — the downlink service persists
  /// the JRN_SEQ high-water mark and paginates with further EVENT_LOG_REQs.
  final void Function(SafrEventLogDataPayload log)? onJournalData;
  final void Function(String mac, int severity)? onTraffic;

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
    final result =
        parseSafr(bytes, key: id.key, expectedSystemId: id.systemId);
    if (result is! SafrWireResult) return; // v1/invalid: raw log only
    final frame = result.frame;
    final now = DateTime.now().toUtc();

    if (frame.error != null) {
      onInvalidFrame?.call();
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

    final severity = frame.payload is SafrEventPayload
        ? (frame.payload as SafrEventPayload).eventType.severity
        : 0;
    onTraffic?.call(frame.srcMac, severity);

    if (frame.msgType == SafrMsgType.ack && frame.payload is SafrAckPayload) {
      onAckReceived?.call(frame.payload as SafrAckPayload);
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

    final accepted = await _updateTrustedState(frame, packetId, now);

    // Spec §9.1: process once, ACK every time (even duplicates/replays).
    if (frame.ackRequired) {
      await onAckRequired?.call(frame);
      if (accepted != null) {
        await (db.update(db.deviceEvents)
              ..where((t) => t.id.equals(accepted)))
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

  /// Returns the inserted DeviceEvents id when an EVENT row was created.
  Future<int?> _updateTrustedState(
    SafrWireFrame frame,
    int packetId,
    DateTime now,
  ) async {
    return db.transaction(() async {
      final existing = await (db.select(db.meshDevices)
            ..where((t) => t.mac.equals(frame.srcMac)))
          .getSingleOrNull();

      // Replay detection (spec §4): equal-or-older counters from the same
      // boot are replays — never let them touch trusted state.
      if (existing != null &&
          frame.bootCtr == existing.lastBootCtr &&
          frame.msgCtr <= existing.lastMsgCtr) {
        return null;
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
        final dedupeKey = '${frame.srcMac}#${frame.msgId}';
        _recentMsgIds.removeWhere(
            (_, at) => now.difference(at) > const Duration(seconds: 30));
        isDuplicate = _recentMsgIds.containsKey(dedupeKey);
        _recentMsgIds[dedupeKey] = now;
      }

      await _upsertDevice(frame, existing, now);
      if (isDuplicate) return null;

      if (event != null) {
        return _insertEvent(
          srcMac: frame.srcMac,
          msgId: frame.msgId,
          hops: frame.hops,
          p: event,
          packetId: packetId,
          now: now,
          retx: frame.isRetx,
        );
      }
      return null;
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

    switch (payload) {
      case SafrHeartbeatPayload p:
        layer = p.layer;
        parentMac = p.parentMac;
        rssi = p.rssiToParent ?? rssi;
        battery = p.batteryPct ?? battery;
        lastHb = now;
        // Role tracks layer from the 15 s heartbeat so a root change shows
        // fast; TOPOLOGY (every 60 s) also carries role and refines it. Board
        // (layer 0) and the mesh root (layer 1) are "root"; layer 2+ are
        // relays/children. (Phase 1 has no sleeping leaves on this path.)
        role = p.layer <= 1 ? SafrNodeRole.root.wire : SafrNodeRole.node.wire;
      case SafrTopologyPayload p:
        role = p.role.wire;
        layer = p.layer;
        parentMac = p.parentMac;
        rssi = p.rssiToParent ?? rssi;
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

    // v3.1 (spec §7.11): the operator-chosen name/zone, announced once by
    // the device itself — always wins over whatever INSTALLATION guessed.
    var name = existing?.name;
    var zone = existing?.zone;
    var registryState = existing?.registryState;
    if (payload case SafrNameAnnouncePayload p) {
      name = p.name;
      zone = p.zone;
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
            zone: Value(zone),
            registryState: Value(registryState),
            lastDevSeq: Value(lastDevSeq),
            alarmLatched: Value(alarmLatched),
            alarmLatchedAt: Value(alarmLatchedAt),
          ),
        );
  }

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
            zone: Value(existing?.zone),
            registryState: Value(existing?.registryState),
            lastDevSeq: Value(lastDevSeq),
            alarmLatched: Value(alarmLatched),
            alarmLatchedAt: Value(alarmLatchedAt),
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
              zone: Value(existing?.zone ?? device.zone),
              registryState: const Value('enrolled'),
              lastDevSeq: Value(existing?.lastDevSeq ?? 0),
              alarmLatched: Value(existing?.alarmLatched ?? 0),
              alarmLatchedAt: Value(existing?.alarmLatchedAt),
            ),
          );
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

  final service = SafrIngestService(
    db: ref.watch(appDatabaseProvider),
    identity: () => ref.read(safrIdentityProvider),
    onValidFrame: link.reportValidFrame,
    onInvalidFrame: link.reportInvalidFrame,
    onAckRequired: downlink.sendAck,
    onAckReceived: downlink.handleAck,
    onJournalData: downlink.handleJournalData,
    onTraffic: (mac, severity) => traffic.emit(SafrTrafficTick(
      mac: mac,
      direction: SafrTrafficDirection.uplink,
      severity: severity,
    )),
  );

  final sub = serial.dataStream.listen((bytes) {
    service.handleFrame(bytes,
        deviceId: serial.connectedDeviceId ?? 'unknown');
  });
  ref.onDispose(sub.cancel);
  return service;
});
