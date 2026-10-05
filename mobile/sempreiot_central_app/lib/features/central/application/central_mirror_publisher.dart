import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/utils/mqtt_log.dart';
import '../../iot/domain/entities/mqtt_message_entity.dart';
import 'alarm_latch_provider.dart';
import 'central_iot_provider.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'central_mirror_codec.dart';
import 'device_led_provider.dart';
import 'device_update_controller.dart';
import 'device_update_history.dart';
import 'device_update_state.dart';
import 'ota_push_report.dart';
import 'ota_push_state.dart';
import 'safr_downlink_provider.dart';
import 'safr_traffic_provider.dart';
import 'serial_link_provider.dart';
import 'topology_provider.dart';

/// Publishes one mirror message; false = not sent (MQTT down).
typedef MirrorPublish = bool Function(
  String topic,
  String payload, {
  bool retain,
  int qos,
});

/// A user's phone that has this central open right now.
class MirrorWatcher {
  const MirrorWatcher({
    required this.key,
    required this.since,
    this.sub,
    this.name,
  });

  /// What tells one watcher from another: the user's id, else the name.
  final String key;

  /// The user's id, as the phone reported it (Acessos lists the same id).
  final String? sub;

  /// The account name the user signed in with, as the phone reported it.
  final String? name;

  /// When this phone started watching.
  final DateTime since;
}

/// Who is watching this central right now (CENTRAL mode): empty = nothing
/// of the map is being sent to the cloud. Kept by the mirror publisher.
final mirrorWatchersProvider =
    StateProvider<List<MirrorWatcher>>((_) => const []);

/// The central's side of the mirror (docs/cloud/central-mirror.md): sends
/// the units and the frame movements **only while a user is watching**, and
/// the held alarms always.
///
/// - A phone's `watch` ping opens the stream; it closes when the last phone
///   says `unwatch` (the user left the central), or [watchTimeout] after
///   the last ping of a phone that just vanished. With nobody watching,
///   nothing but the alarm list leaves.
/// - Frames go in batches, one every [pump] (250 ms) that had any, or as
///   soon as a batch holds [maxTicksPerBatch].
/// - The snapshot goes on a `hello`, then when the map changes (at most one
///   a second); what changes on every heartbeat — last seen, dBm — is
///   refreshed every [softRefresh] instead.
/// - The alarm list is retained, so a user who opens the app after an alarm
///   started — even with the central offline by then — still gets it.
/// - The firmware update (the run on "Atualizar dispositivos" and the image
///   on its way to the board) goes on a `hello` and when it changes, looked
///   at once a second; the history only when a phone asks for it.
/// - IDENTIFY is the one command a watching phone may ask for: the central
///   sends it as its own menu does, and every IDENTIFY blink that starts —
///   asked from a phone or from the tablet — goes to the phones as an
///   event, so their LEDs blink with the unit's.
///
/// No timer of its own: the provider calls [pump]. Never in the fire path:
/// a failed publish is dropped, nothing waits for it.
class CentralMirrorPublisher {
  CentralMirrorPublisher({
    required String? Function() identityId,
    required MirrorPublish publish,
    required List<TopologyNode> Function() nodes,
    required String Function() link,
    ({DeviceUpdateRun? run, OtaPushState? push}) Function()? ota,
    Future<List<MirrorOtaHistoryRun>> Function()? otaHistory,
    Future<bool> Function(String mac, int seconds, String by)? identify,
    void Function(List<MirrorWatcher> watchers)? onWatchers,
    DateTime Function()? clock,
  })  : _identityId = identityId,
        _publish = publish,
        _nodes = nodes,
        _link = link,
        _ota = ota,
        _otaHistory = otaHistory,
        _identify = identify,
        _onWatchers = onWatchers,
        _clock = clock ?? DateTime.now;

  static const watchTimeout = Duration(seconds: 75);
  static const snapshotGap = Duration(seconds: 1);
  static const softRefresh = Duration(seconds: 30);
  static const pumpEvery = Duration(milliseconds: 250);

  /// About 70 bytes a tick: 50 stay inside one AWS-billed message (5 KB).
  static const maxTicksPerBatch = 50;

  /// How long a unit blinks on an IDENTIFY asked from a phone — what the
  /// tablet's own menu asks for.
  static const identifySeconds = 10;

  final String? Function() _identityId;
  final MirrorPublish _publish;
  final List<TopologyNode> Function() _nodes;
  final String Function() _link;
  final ({DeviceUpdateRun? run, OtaPushState? push}) Function()? _ota;
  final Future<List<MirrorOtaHistoryRun>> Function()? _otaHistory;

  /// Sends IDENTIFY to a unit and tells whether the root confirmed it; on
  /// a confirmation it starts the blink, which comes back as [onIdentify].
  final Future<bool> Function(String mac, int seconds, String by)? _identify;
  final void Function(List<MirrorWatcher> watchers)? _onWatchers;
  final DateTime Function() _clock;

  /// Per phone: who it is and when it last pinged.
  final _watchers = <String, ({MirrorWatcher who, DateTime lastPing})>{};
  bool _helloPending = false;
  bool _mapChanged = false;
  bool _softDirty = false;
  String? _lastSignature;
  DateTime? _lastSnapshotAt;
  int _stateSeq = 0;

  final _batch = <MirrorTick>[];
  final _events = <MirrorEvent>[];
  final _identifying = <String>{};
  DateTime? _batchStart;
  int _framesSeq = 0;

  String? _alarmSignature;
  List<MirrorAlarm> _alarms = const [];

  bool _otaHelloPending = false;
  String? _lastOtaBody;
  DateTime? _lastOtaLookAt;
  int _otaSeq = 0;
  bool _sendingHistory = false;

  bool _alive(DateTime lastPing) =>
      _clock().difference(lastPing) < watchTimeout;

  /// A user has this central open right now.
  bool get watched => _watchers.values.any((w) => _alive(w.lastPing));

  /// The phones watching right now, the first to arrive first.
  List<MirrorWatcher> get watchers => [
        for (final w in _watchers.values)
          if (_alive(w.lastPing)) w.who,
      ]..sort((a, b) => a.since.compareTo(b.since));

  /// A message on the central's command topic.
  void onCommand(String payload) {
    if (isMirrorOtaHistoryRequest(payload)) {
      _sendOtaHistory();
      return;
    }
    final left = decodeMirrorUnwatch(payload);
    if (left != null) {
      if (_watchers.remove(left.sub ?? left.name ?? '?') != null) {
        _onWatchers?.call(watchers);
        if (!watched) {
          MqttLog.event('mirror: nobody watching — stream stopped',
              tag: 'Central');
        }
      }
      return;
    }
    final identify = decodeMirrorIdentify(payload);
    if (identify != null) {
      _identifyFor(identify.mac, identify.name ?? identify.sub ?? '?');
      return;
    }
    final ping = decodeMirrorWatch(payload);
    if (ping == null) return;
    final opening = !watched;
    final now = _clock();
    final key = ping.sub ?? ping.name ?? '?';
    final known = _watchers[key];
    final arriving = known == null || !_alive(known.lastPing);
    _watchers[key] = (
      who: MirrorWatcher(
        key: key,
        sub: ping.sub,
        name: ping.name ?? known?.who.name,
        since: arriving ? now : known.who.since,
      ),
      lastPing: now,
    );
    if (ping.hello || opening) {
      _helloPending = true;
      _otaHelloPending = true;
    }
    if (opening) MqttLog.event('mirror: a user is watching', tag: 'Central');
    if (arriving) _onWatchers?.call(watchers);
  }

  /// One frame movement on the mesh.
  void onTick(SafrTrafficTick tick) {
    if (!watched) return;
    final now = _clock();
    _batchStart ??= now;
    _batch.add((
      offsetMs: now.difference(_batchStart!).inMilliseconds,
      tick: tick,
    ));
    if (_batch.length >= maxTicksPerBatch) _flushFrames();
  }

  /// The map or the board link changed.
  void onMapChanged() => _mapChanged = true;

  /// An IDENTIFY blink started on [mac] (the tablet's LED engine says so):
  /// the phones' LEDs blink too.
  void onIdentify(String mac, int seconds) {
    if (!watched) return;
    _events.add((kind: MirrorEventKind.identify, mac: mac, arg: seconds));
  }

  /// A phone asked for IDENTIFY. Only from a phone that is watching, only
  /// for a mains unit the tablet hears, one at a time per unit.
  Future<void> _identifyFor(String mac, String by) async {
    final send = _identify;
    if (send == null || !watched || _identifying.contains(mac)) return;
    // Heard: the phone can now tell a central that does not answer (off
    // line, or a build without this) from a root that does not confirm.
    _events.add((kind: MirrorEventKind.identifySending, mac: mac, arg: 0));
    final known = _nodes().any((n) => n.mac == mac && n.online && !n.isLeaf);
    if (!known) {
      _events.add((kind: MirrorEventKind.identifyFailed, mac: mac, arg: 0));
      return;
    }
    _identifying.add(mac);
    var ok = false;
    try {
      ok = await send(mac, identifySeconds, by);
    } catch (e) {
      MqttLog.event('mirror: identify failed: $e', tag: 'Central');
    } finally {
      _identifying.remove(mac);
    }
    if (!ok && watched) {
      _events.add((kind: MirrorEventKind.identifyFailed, mac: mac, arg: 0));
    }
  }

  /// Every [pumpEvery]: sends what is due.
  void pump() {
    // Phones whose pings stopped: closed, in the background, no signal.
    final before = _watchers.length;
    _watchers.removeWhere((_, w) => !_alive(w.lastPing));
    if (_watchers.length != before) {
      _onWatchers?.call(watchers);
      if (_watchers.isEmpty) {
        MqttLog.event('mirror: nobody watching — stream stopped',
            tag: 'Central');
      }
    }
    if (!watched) {
      _events.clear();
      _batch.clear();
      _batchStart = null;
      _helloPending = false;
      _otaHelloPending = false;
      return;
    }
    _flushFrames();
    _maybeSnapshot();
    _maybeOta();
  }

  /// The update: looked at once a second, sent when a phone said hello or
  /// when it is not what was last sent.
  void _maybeOta() {
    final source = _ota;
    if (source == null) return;
    final now = _clock();
    final last = _lastOtaLookAt;
    if (last != null && now.difference(last) < snapshotGap) return;
    _lastOtaLookAt = now;

    final ota = source();
    final body = mirrorOtaBody(ota.run, ota.push);
    if (!_otaHelloPending && body == _lastOtaBody) return;
    final id = _identityId();
    if (id == null) return;
    final sent = _publish(
      mirrorOtaTopic(id),
      encodeMirrorOta(seq: ++_otaSeq, run: ota.run, push: ota.push),
      retain: false,
      qos: 1,
    );
    if (!sent) return;
    _otaHelloPending = false;
    _lastOtaBody = body;
  }

  /// A phone asked for the update history.
  Future<void> _sendOtaHistory() async {
    final source = _otaHistory;
    if (source == null || !watched || _sendingHistory) return;
    _sendingHistory = true;
    try {
      final runs = await source();
      final id = _identityId();
      if (id == null || !watched) return;
      _publish(
        mirrorOtaHistoryTopic(id),
        encodeMirrorOtaHistory(runs),
        retain: false,
        qos: 1,
      );
    } catch (e) {
      MqttLog.event('mirror: update history not sent: $e', tag: 'Central');
    } finally {
      _sendingHistory = false;
    }
  }

  void _flushFrames() {
    if (_batch.isEmpty && _events.isEmpty) return;
    final id = _identityId();
    if (id != null) {
      _publish(
        mirrorFramesTopic(id),
        encodeMirrorFrames(
          seq: ++_framesSeq,
          t0: _batchStart ?? _clock(),
          ticks: _batch,
          events: _events,
        ),
        retain: false,
        // An event is not repeated by the next batch: acknowledged.
        qos: _events.isEmpty ? 0 : 1,
      );
    }
    _batch.clear();
    _events.clear();
    _batchStart = null;
  }

  void _maybeSnapshot() {
    final now = _clock();
    final last = _lastSnapshotAt;
    if (last != null && now.difference(last) < snapshotGap) return;

    var due = _helloPending;
    if (_mapChanged) {
      _mapChanged = false;
      if (mirrorStateSignature(_link(), _nodes()) != _lastSignature) {
        due = true;
      } else {
        _softDirty = true;
      }
    }
    if (!due &&
        _softDirty &&
        (last == null || now.difference(last) >= softRefresh)) {
      due = true;
    }
    if (!due) return;

    final id = _identityId();
    if (id == null) return;
    final link = _link();
    final nodes = _nodes();
    final sent = _publish(
      mirrorStateTopic(id),
      encodeMirrorState(seq: ++_stateSeq, at: now, link: link, nodes: nodes),
      retain: false,
      qos: 1,
    );
    if (!sent) return;
    _helloPending = false;
    _softDirty = false;
    _lastSignature = mirrorStateSignature(link, nodes);
    _lastSnapshotAt = now;
  }

  /// The alarms held on the panel changed (or were read for the first
  /// time): published always, watched or not, and retained.
  void onAlarms(List<MirrorAlarm> alarms) {
    _alarms = alarms;
    _publishAlarms(force: false);
  }

  /// A new MQTT session: no phone is known to be watching yet, and the
  /// retained alarm list is written again — it may have changed while the
  /// central was offline.
  void onConnected() {
    if (_watchers.isNotEmpty) {
      _watchers.clear();
      _onWatchers?.call(const []);
    }
    _publishAlarms(force: true);
  }

  void _publishAlarms({required bool force}) {
    final signature = mirrorAlarmsSignature(_alarms);
    if (!force && signature == _alarmSignature) return;
    final id = _identityId();
    if (id == null) return;
    final sent = _publish(
      mirrorAlarmTopic(id),
      encodeMirrorAlarms(at: _clock(), alarms: _alarms),
      retain: true,
      qos: 1,
    );
    // Not sent = MQTT down: [onConnected] writes it when the session is back.
    if (sent) _alarmSignature = signature;
  }
}

MirrorAlarm _alarmOf(MeshDevice d) => MirrorAlarm(
      mac: d.mac,
      name: d.name,
      zone: d.zone,
      since: d.alarmLatchedAt,
    );

/// Central mode only: runs [CentralMirrorPublisher] on the tablet's live
/// providers. Must stay watched while the app runs (MainScreen watches it).
final centralMirrorPublisherProvider = Provider<void>((ref) {
  if (!AppConfig.isCentral) return;

  final publisher = CentralMirrorPublisher(
    identityId: () => ref.read(centralMqttRepositoryProvider).identityId,
    publish: (topic, payload, {retain = false, qos = 1}) {
      final repo = ref.read(centralMqttRepositoryProvider);
      if (!repo.isConnected) return false;
      try {
        repo.publish(topic, payload, retain: retain, qos: qos);
        return true;
      } catch (e) {
        MqttLog.event('mirror publish failed: $e', tag: 'Central');
        return false;
      }
    },
    nodes: () => ref.read(topologyProvider),
    link: () => ref.read(serialLinkProvider).name,
    // Read once a second while a user is watching, never listened to: with
    // nobody watching the mirror does not touch the update's providers.
    ota: () => (
      run: ref.read(deviceUpdateProvider),
      push: ref.read(otaPushViewProvider),
    ),
    otaHistory: () => ref.read(deviceUpdateHistoryProvider).recent(limit: 20),
    // The same path as the tablet's own menu (device_menu.dart): the
    // command goes down, and the blink starts only on the root's ACK.
    identify: (mac, seconds, by) async {
      final ok = await ref
          .read(safrDownlinkProvider)
          .sendCommand(mac, SafrCommand.identify, args: [seconds]);
      if (ok) ref.read(deviceLedProvider).identify(mac, seconds);
      try {
        await ref.read(appDatabaseProvider).addAudit(
          'remote',
          'identify',
          {'mac': mac, 'by': by, 'ok': ok},
        );
      } catch (_) {
        // The audit line is evidence, not state.
      }
      return ok;
    },
    onWatchers: (watchers) =>
        ref.read(mirrorWatchersProvider.notifier).state = watchers,
  );

  // The notifier's own stream, not the StreamProvider over it: two equal
  // pings in a row must both arrive.
  final commands = ref
      .watch(centralIotConnectionProvider.notifier)
      .messages
      .listen((MqttMessageEntity msg) {
    final id = ref.read(centralMqttRepositoryProvider).identityId;
    if (id != null && msg.topic == mirrorCommandTopic(id)) {
      publisher.onCommand(msg.payload);
    }
  });
  final traffic = ref.read(safrTrafficProvider).stream.listen(publisher.onTick);
  // read, not watch: the engine notifies on every frame, and on the tablet
  // it is the same engine for as long as the app runs.
  final identifies = ref
      .read(deviceLedProvider)
      .identifies
      .listen((i) => publisher.onIdentify(i.mac, i.seconds));

  ref.listen(topologyProvider, (_, __) => publisher.onMapChanged());
  ref.listen(serialLinkProvider, (_, __) => publisher.onMapChanged());
  ref.listen(latchedAlarmsProvider, (_, next) {
    final latched = next.valueOrNull;
    if (latched != null) publisher.onAlarms(latched.map(_alarmOf).toList());
  }, fireImmediately: true);
  ref.listen(centralIotConnectionProvider, (prev, next) {
    if (next.valueOrNull == true && prev?.valueOrNull != true) {
      publisher.onConnected();
    }
  }, fireImmediately: true);

  final pump = Timer.periodic(
    CentralMirrorPublisher.pumpEvery,
    (_) => publisher.pump(),
  );

  ref.onDispose(() {
    pump.cancel();
    commands.cancel();
    traffic.cancel();
    identifies.cancel();
  });
});
