import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/mqtt_log.dart';
import '../../auth/application/auth_provider.dart';
import '../../iot/application/iot_provider.dart';
import '../../iot/application/presence_provider.dart';
import '../../iot/domain/entities/mqtt_message_entity.dart';
import '../../iot/domain/repositories/i_iot_mqtt_repository.dart';
import 'central_mirror_codec.dart';
import 'device_led_provider.dart';
import 'device_update_state.dart';
import 'ota_push_state.dart';
import 'safr_traffic_provider.dart';
import 'topology_provider.dart';

/// USER mode: the central whose screens are open (its identity id), or null.
/// While it is set, the Rede and Dispositivos screens draw that central from
/// the mirror instead of a board on this device's USB port — and are view
/// only (docs/cloud/central-mirror.md §5).
final viewedCentralProvider = StateProvider<String?>((_) => null);

/// True on a phone looking at a central through the mirror: nothing can be
/// commanded from here, so every action that sends a frame or edits the
/// central's registry is hidden.
final mirrorViewOnlyProvider =
    Provider<bool>((ref) => ref.watch(viewedCentralProvider) != null);

/// What became of an Identificar asked from the phone.
enum MirrorIdentifyOutcome {
  /// The root confirmed: the unit is blinking.
  confirmed,

  /// The central sent it and the root did not confirm (or the central
  /// refused: a unit without communication).
  notConfirmed,

  /// The central never said it heard the request: it is offline, or its
  /// app is a build that does not know the request.
  noAnswer,
}

/// What the phone knows of the viewed central.
class CentralMirrorView {
  const CentralMirrorView({
    this.nodes = const [],
    this.link = 'disconnected',
    this.snapshotAt,
    this.centralOnline = false,
    this.connected = false,
    this.run,
    this.push = const OtaPushState(),
    this.otaHistory = const [],
  });

  /// The units of the last snapshot, their last-seen time kept moving by
  /// the frames that arrived since.
  final List<TopologyNode> nodes;

  /// The central's board link (`SerialLinkStatus` name).
  final String link;

  /// When the central took the last snapshot; null = none arrived yet.
  final DateTime? snapshotAt;

  /// The central's presence (its retained `will`).
  final bool centralOnline;

  /// This phone's own MQTT session is up.
  final bool connected;

  /// The firmware update on the tablet's "Atualizar dispositivos": running,
  /// or ended and not dismissed there. Null = none.
  final DeviceUpdateRun? run;

  /// The image on its way from the tablet to the board (idle = none).
  final OtaPushState push;

  /// The updates kept on the tablet, newest first — as of the last time
  /// this phone asked ([CentralMirrorViewer.requestOtaHistory]).
  final List<MirrorOtaHistoryRun> otaHistory;

  /// A snapshot arrived, the central is online and so is this phone: the
  /// picture is live.
  bool get live => snapshotAt != null && centralOnline && connected;

  /// The viewed central's board link is up.
  bool get linkUp => live && link == 'connected';

  CentralMirrorView copyWith({
    List<TopologyNode>? nodes,
    String? link,
    DateTime? snapshotAt,
    bool? centralOnline,
    bool? connected,
    Object? run = _keep,
    OtaPushState? push,
    List<MirrorOtaHistoryRun>? otaHistory,
  }) =>
      CentralMirrorView(
        nodes: nodes ?? this.nodes,
        link: link ?? this.link,
        snapshotAt: snapshotAt ?? this.snapshotAt,
        centralOnline: centralOnline ?? this.centralOnline,
        connected: connected ?? this.connected,
        run: identical(run, _keep) ? this.run : run as DeviceUpdateRun?,
        push: push ?? this.push,
        otaHistory: otaHistory ?? this.otaHistory,
      );
}

const _keep = Object();

/// An Identificar this phone asked for: its outcome, and the timer that
/// ends the wait.
class _IdentifyAsked {
  final done = Completer<MirrorIdentifyOutcome>();
  Timer? timer;
}

/// The phone's side of the mirror: tells the central it is watching, takes
/// its snapshots and replays its frame movements into the app's own traffic
/// bus — so the LED engine and the packets on the map run unchanged.
///
/// Pings every [pingEvery] while the central is open and the app is in the
/// foreground; the central stops streaming by itself when the pings stop.
class CentralMirrorViewer extends StateNotifier<CentralMirrorView> {
  CentralMirrorViewer({
    required this.centralId,
    required IIotMqttRepository repo,
    required SafrTrafficBus traffic,
    String? Function()? accountName,
    void Function(String mac, int seconds)? onIdentify,
    DateTime Function()? clock,
  })  : _repo = repo,
        _traffic = traffic,
        _accountName = accountName,
        _onIdentify = onIdentify,
        _clock = clock ?? DateTime.now,
        super(const CentralMirrorView());

  static const pingEvery = Duration(seconds: 30);

  /// A lost batch asks for the snapshot again, but not more often than this.
  static const helloGap = Duration(seconds: 5);

  final String? centralId;
  final IIotMqttRepository _repo;
  final SafrTrafficBus _traffic;

  /// The name the user signed in with: the tablet shows who is watching.
  final String? Function()? _accountName;

  /// An IDENTIFY blink started on the central: this phone's LED engine
  /// starts the same blink.
  final void Function(String mac, int seconds)? _onIdentify;
  final DateTime Function() _clock;

  /// How long a phone waits for the central to say it heard an Identificar
  /// (it answers within a batch, a quarter of a second, plus the cloud).
  static const identifyAnswerTimeout = Duration(seconds: 6);

  /// How long it then waits for the outcome (the central itself retries
  /// the command for a few seconds).
  static const identifyTimeout = Duration(seconds: 15);

  /// Unit → the IDENTIFY this phone asked for and still waits on.
  final _identifyAsked = <String, _IdentifyAsked>{};

  /// The account name, as last read: [dispose] must not ask for it again
  /// (the provider behind it is gone by then).
  String? _name;

  String? _who() {
    try {
      return _name = _accountName?.call() ?? _name;
    } catch (_) {
      return _name;
    }
  }

  StreamSubscription<MqttMessageEntity>? _stateSub;
  StreamSubscription<MqttMessageEntity>? _framesSub;
  StreamSubscription<MqttMessageEntity>? _otaSub;
  StreamSubscription<MqttMessageEntity>? _otaHistorySub;
  Timer? _pingTimer;
  final _replay = <Timer>{};
  bool _connected = false;
  bool _foreground = true;
  int? _framesSeq;
  DateTime? _lastHelloAt;

  /// The user's MQTT session is up (again): subscribe and say hello.
  void onConnected() {
    final id = centralId;
    if (id == null || !mounted) return;
    _connected = true;
    _cancelSubs();
    try {
      _stateSub = _repo
          .subscribe(mirrorStateTopic(id))
          .listen((m) => _onState(m.payload), onError: (_) {});
      _framesSub = _repo
          .subscribe(mirrorFramesTopic(id))
          .listen((m) => _onFrames(m.payload), onError: (_) {});
      _otaSub = _repo
          .subscribe(mirrorOtaTopic(id))
          .listen((m) => _onOta(m.payload), onError: (_) {});
      _otaHistorySub = _repo
          .subscribe(mirrorOtaHistoryTopic(id))
          .listen((m) => _onOtaHistory(m.payload), onError: (_) {});
    } catch (_) {
      // Dropped between the notice and the subscribe: the next one retries.
      _connected = false;
      return;
    }
    _framesSeq = null;
    state = state.copyWith(connected: true);
    _startPinging();
  }

  /// The user's MQTT session dropped: the picture stops being fed.
  void onDisconnected() {
    _connected = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    _cancelSubs();
    if (mounted && state.connected) state = state.copyWith(connected: false);
  }

  /// The central's presence changed. Back online = a new session on its
  /// side, which knows of no watcher: say hello at once.
  void setCentralOnline(bool online) {
    if (!mounted || online == state.centralOnline) return;
    state = state.copyWith(centralOnline: online);
    if (online) _ping(hello: true);
  }

  /// In the background nobody is looking: stop pinging, the central stops
  /// streaming after its timeout. Back in front: hello.
  void setForeground(bool foreground) {
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      _startPinging();
    } else {
      _pingTimer?.cancel();
      _pingTimer = null;
      _unwatch();
    }
  }

  /// Tells the central this phone is not looking any more, so it stops
  /// streaming now instead of at its timeout.
  void _unwatch() {
    final id = centralId;
    if (id == null || !_connected || !_repo.isConnected) return;
    try {
      _repo.publish(
        mirrorCommandTopic(id),
        encodeMirrorUnwatch(sub: _repo.userId, name: _who()),
      );
    } catch (e) {
      MqttLog.event('mirror unwatch failed: $e');
    }
  }

  void _startPinging() {
    _pingTimer?.cancel();
    _pingTimer = null;
    if (!_connected || !_foreground) return;
    _ping(hello: true);
    _pingTimer = Timer.periodic(pingEvery, (_) => _ping());
  }

  void _ping({bool hello = false}) {
    final id = centralId;
    if (id == null || !_connected || !_foreground || !_repo.isConnected) {
      return;
    }
    if (hello) _lastHelloAt = _clock();
    try {
      _repo.publish(
        mirrorCommandTopic(id),
        encodeMirrorWatch(hello: hello, sub: _repo.userId, name: _who()),
      );
    } catch (e) {
      MqttLog.event('mirror ping failed: $e');
    }
  }

  void _onState(String payload) {
    final snapshot = decodeMirrorState(payload);
    if (snapshot == null || !mounted) return;
    state = state.copyWith(
      nodes: snapshot.nodes,
      link: snapshot.link,
      snapshotAt: snapshot.at,
    );
  }

  void _onOta(String payload) {
    final ota = decodeMirrorOta(payload);
    if (ota == null || !mounted) return;
    final ended = state.run?.running == true && ota.run?.running != true;
    state = state.copyWith(
      run: ota.run,
      push: ota.push ?? const OtaPushState(),
    );
    // An update just ended: the history has a new line.
    if (ended && state.otaHistory.isNotEmpty) requestOtaHistory();
  }

  void _onOtaHistory(String payload) {
    final runs = decodeMirrorOtaHistory(payload);
    if (runs == null || !mounted) return;
    state = state.copyWith(otaHistory: runs);
  }

  /// Asks the central for the updates it keeps (the phone's "Atualizar
  /// dispositivos" does, when it opens).
  void requestOtaHistory() {
    final id = centralId;
    if (id == null || !_connected || !_repo.isConnected) return;
    try {
      _repo.publish(mirrorCommandTopic(id), encodeMirrorOtaHistoryRequest());
    } catch (e) {
      MqttLog.event('mirror history request failed: $e');
    }
  }

  /// Asks the central to make [mac] blink (IDENTIFY). Confirmed once the
  /// central says the root confirmed it — the unit and its LED on screen
  /// blink then.
  Future<MirrorIdentifyOutcome> sendIdentify(String mac) {
    final id = centralId;
    if (id == null || !_connected || !_repo.isConnected) {
      return Future.value(MirrorIdentifyOutcome.noAnswer);
    }
    final waiting = _identifyAsked[mac];
    if (waiting != null) return waiting.done.future;
    try {
      _repo.publish(
        mirrorCommandTopic(id),
        encodeMirrorIdentify(mac, sub: _repo.userId, name: _who()),
      );
    } catch (e) {
      MqttLog.event('mirror identify failed: $e');
      return Future.value(MirrorIdentifyOutcome.noAnswer);
    }
    final asked = _IdentifyAsked();
    _identifyAsked[mac] = asked;
    asked.timer = Timer(identifyAnswerTimeout,
        () => _identifyDone(mac, MirrorIdentifyOutcome.noAnswer));
    return asked.done.future;
  }

  void _identifyDone(String mac, MirrorIdentifyOutcome outcome) {
    final asked = _identifyAsked.remove(mac);
    if (asked == null) return;
    asked.timer?.cancel();
    if (!asked.done.isCompleted) asked.done.complete(outcome);
    MqttLog.event('mirror identify $mac: ${outcome.name}');
  }

  void _onEvent(MirrorEvent event) {
    switch (event.kind) {
      case MirrorEventKind.identifySending:
        // The central heard it: now wait for what the root says.
        final asked = _identifyAsked[event.mac];
        if (asked == null) return;
        asked.timer?.cancel();
        asked.timer = Timer(identifyTimeout,
            () => _identifyDone(event.mac, MirrorIdentifyOutcome.notConfirmed));
      case MirrorEventKind.identify:
        _onIdentify?.call(event.mac, event.arg);
        _identifyDone(event.mac, MirrorIdentifyOutcome.confirmed);
      case MirrorEventKind.identifyFailed:
        _identifyDone(event.mac, MirrorIdentifyOutcome.notConfirmed);
    }
  }

  void _onFrames(String payload) {
    final frames = decodeMirrorFrames(payload);
    if (frames == null || !mounted) return;
    frames.events.forEach(_onEvent);
    final expected = _framesSeq == null ? null : _framesSeq! + 1;
    _framesSeq = frames.seq;
    // A batch went missing: what it changed is unknown, so ask for the
    // snapshot again and carry on.
    if (expected != null && frames.seq != expected) {
      final last = _lastHelloAt;
      if (last == null || _clock().difference(last) >= helloGap) {
        _ping(hello: true);
      }
    }
    for (final t in frames.ticks) {
      if (t.offsetMs <= 0) {
        _emit(t.tick);
        continue;
      }
      late final Timer timer;
      timer = Timer(Duration(milliseconds: t.offsetMs), () {
        _replay.remove(timer);
        _emit(t.tick);
      });
      _replay.add(timer);
    }
  }

  void _emit(SafrTrafficTick tick) {
    if (!mounted) return;
    // A frame from a unit is the unit heard now: what the tablet's registry
    // does on every frame, done here from the tick.
    if (tick.direction == SafrTrafficDirection.uplink) {
      final i = state.nodes.indexWhere((n) => n.mac == tick.mac);
      if (i >= 0) {
        final nodes = [...state.nodes];
        nodes[i] = _copy(nodes[i], lastSeenAt: _clock().toUtc());
        state = state.copyWith(nodes: nodes);
      }
    }
    _traffic.emit(tick);
  }

  void _cancelSubs() {
    _stateSub?.cancel();
    _framesSub?.cancel();
    _otaSub?.cancel();
    _otaHistorySub?.cancel();
    _stateSub = null;
    _framesSub = null;
    _otaSub = null;
    _otaHistorySub = null;
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    for (final t in _replay) {
      t.cancel();
    }
    for (final mac in _identifyAsked.keys.toList()) {
      _identifyDone(mac, MirrorIdentifyOutcome.noAnswer);
    }
    _cancelSubs();
    final id = centralId;
    if (_foreground) _unwatch(); // in the background it was already said
    if (id != null && _repo.isConnected) {
      // Without this the broker keeps delivering the stream to this phone
      // for as long as anyone else is watching the same central.
      try {
        _repo.unsubscribe(mirrorStateTopic(id));
        _repo.unsubscribe(mirrorFramesTopic(id));
        _repo.unsubscribe(mirrorOtaTopic(id));
        _repo.unsubscribe(mirrorOtaHistoryTopic(id));
      } catch (_) {}
    }
    super.dispose();
  }
}

TopologyNode _copy(
  TopologyNode n, {
  DateTime? lastSeenAt,
  bool? online,
  bool? heard,
  bool? updating,
}) =>
    TopologyNode(
      mac: n.mac,
      role: n.role,
      layer: n.layer,
      parentMac: n.parentMac,
      rssi: n.rssi,
      batteryPct: n.batteryPct,
      online: online ?? n.online,
      lastSeenAt: lastSeenAt ?? n.lastSeenAt,
      alarmLatched: n.alarmLatched,
      alarmLatchedAt: n.alarmLatchedAt,
      name: n.name,
      zone: n.zone,
      boardState: n.boardState,
      boardFlags: n.boardFlags,
      parentCandidates: n.parentCandidates,
      productCode: n.productCode,
      hwRev: n.hwRev,
      fwVersion: n.fwVersion,
      updating: updating ?? n.updating,
      heard: heard ?? n.heard,
    );

/// The mirror of the viewed central; rebuilt (and the old one unsubscribed)
/// whenever another central is opened or the user leaves.
///
/// It must have a listener for as long as the app runs in USER mode
/// (MainScreen listens): an unlistened provider is only rebuilt when it is
/// next read, so the mirror would start watching when a screen first asks
/// for the map (not when the central is opened) and — worse — would go on
/// pinging after the user left, because nothing reads it any more.
// (Typed by hand: it reaches the LED engine, which reaches the map, which
// reads this provider — too round for the type to be inferred.)
final StateNotifierProvider<CentralMirrorViewer, CentralMirrorView>
    centralMirrorProvider =
    StateNotifierProvider<CentralMirrorViewer, CentralMirrorView>((ref) {
  final id = ref.watch(viewedCentralProvider);
  final viewer = CentralMirrorViewer(
    centralId: id,
    repo: ref.read(iotMqttRepositoryProvider),
    traffic: ref.read(safrTrafficProvider),
    accountName: () => ref.read(authNotifierProvider).valueOrNull?.userId,
    onIdentify: (mac, seconds) =>
        ref.read(deviceLedProvider).identify(mac, seconds),
  );
  if (id == null) return viewer;

  ref.listen(iotConnectionProvider, (_, next) {
    if (next.valueOrNull == true) {
      viewer.onConnected();
    } else {
      viewer.onDisconnected();
    }
  }, fireImmediately: true);
  ref.listen(presenceStatusProvider(id), (_, next) {
    viewer.setCentralOnline(next == PresenceStatus.online);
  }, fireImmediately: true);

  final lifecycle = AppLifecycleListener(
    onResume: () => viewer.setForeground(true),
    onHide: () => viewer.setForeground(false),
    onPause: () => viewer.setForeground(false),
  );
  ref.onDispose(lifecycle.dispose);
  return viewer;
});

/// The viewed central's units for the Rede and Dispositivos screens. Never
/// stale as live: without a live picture (no snapshot yet, or the central
/// offline) every unit is drawn without communication.
final mirrorTopologyProvider = Provider<List<TopologyNode>>((ref) {
  final view = ref.watch(centralMirrorProvider);
  if (view.live) return view.nodes;
  return [
    for (final n in view.nodes)
      _copy(n, online: false, heard: false, updating: false),
  ];
});

/// The alarms a central holds, from its retained alarm list: there even
/// when the alarm started before the app was opened, and even when the
/// central is offline now. Null until the list arrives.
final centralAlarmsProvider =
    Provider.family<MirrorAlarms?, String>((ref, identityId) {
  final msg = ref.watch(iotMessageStreamProvider(mirrorAlarmTopic(identityId)));
  final payload = msg.valueOrNull?.payload;
  return payload == null ? null : decodeMirrorAlarms(payload);
});
