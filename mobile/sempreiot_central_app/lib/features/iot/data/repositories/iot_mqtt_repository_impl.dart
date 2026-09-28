import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../../core/services/sigv4_signer.dart';
import '../../../../core/utils/mqtt_log.dart';
import '../../domain/entities/mqtt_message_entity.dart';
import '../../domain/repositories/i_iot_mqtt_repository.dart';
import '../services/iot_credentials_service.dart';

String get _iotEndpoint => dotenv.env['AWS_IOT_ENDPOINT']!;
String get _region => dotenv.env['AWS_REGION']!;

class IotMqttRepositoryImpl implements IIotMqttRepository {
  // Static singleton so there is never more than one WebSocket open at a time.
  // Flutter Web hot restart does NOT reset static state (JS runtime persists),
  // so the same instance — and its existing connection — survives across
  // restarts. Without this, each restart creates a new instance, connects with
  // the same client-ID, AWS IoT does a session takeover (kicks the old socket),
  // the old notifier sees the disconnect, reschedules a connect, kicks the new
  // socket, and the loop repeats indefinitely.
  static IotMqttRepositoryImpl? _shared;
  static IotMqttRepositoryImpl? _centralShared;

  factory IotMqttRepositoryImpl({IotCredentialsService? credentialsService}) {
    return _shared ??= IotMqttRepositoryImpl._internal(
      credentialsService ?? IotCredentialsService(),
    );
  }

  /// Separate singleton for the Central device.
  /// Accepts any [IotCredentialsService] subclass — callers pass
  /// [CentralCredentialsService] without creating a dependency here.
  factory IotMqttRepositoryImpl.forCentral({required IotCredentialsService credentialsService}) {
    return _centralShared ??= IotMqttRepositoryImpl._internal(credentialsService);
  }

  IotMqttRepositoryImpl._internal(this._credentialsService);

  final IotCredentialsService _credentialsService;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _nextPacketId = 0;
  int _generation = 0;
  StreamController<({String topic, String payload})>? _publishCtrl;
  Timer? _pingTimer;
  Timer? _pingRespTimer;
  Completer<void>? _connackCompleter;
  bool _connackReceived = false;
  // SUBSCRIBE packets awaiting their SUBACK, keyed by packet ID. AWS IoT
  // signals a denied subscription only via SUBACK return code 0x80 — the
  // subscription just silently never delivers otherwise. Denials are retried
  // with backoff because IoT policy grants can land seconds after the action
  // that triggered them (e.g. a lambda attaching a policy).
  final Map<int, ({String topic, int attempt})> _pendingSubs = {};
  static const _maxSubscribeAttempts = 5;
  bool _connected = false;
  DateTime? _connectedAt;
  void Function()? _onDisconnected;
  String? _identityId;
  String? _userId;

  @override
  bool get isConnected => _connected;

  @override
  String? get identityId => _identityId;

  @override
  String? get userId => _userId;

  @override
  Future<void> connect({
    void Function()? onDisconnected,
    MqttWill Function(String identityId)? will,
  }) async {
    // If the connection survived a hot restart, just transfer the disconnect
    // callback to the new notifier — no new WebSocket, no session takeover.
    if (_connected) {
      _onDisconnected = onDisconnected;
      debugPrint('[IoT] connect() called while already connected — handing off callback');
      return;
    }

    // Bump generation so any _onDone/onError from the previous socket —
    // including the one AWS IoT fires when it kicks the old connection on
    // duplicate client-ID — is silently dropped and cannot trigger a reconnect.
    final gen = ++_generation;
    _onDisconnected = null;
    await _subscription?.cancel();
    _subscription = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _pingRespTimer?.cancel();
    _pingRespTimer = null;
    _connected = false;
    _connectedAt = null; // reset so age-check in _onDone is always fresh
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    _publishCtrl?.close();
    _publishCtrl = null;
    _pendingSubs.clear();

    final creds = await _credentialsService.fetch();
    _identityId = creds.identityId;
    _userId = creds.userId;
    final clientId = kIsWeb ? 'web-${creds.identityId}' : creds.identityId;

    final signedUrl = SigV4Signer.buildSignedWebSocketUrl(
      host: _iotEndpoint,
      region: _region,
      accessKeyId: creds.accessKeyId,
      secretAccessKey: creds.secretAccessKey,
      sessionToken: creds.sessionToken,
    );

    _onDisconnected = onDisconnected;
    _connackCompleter = Completer();
    _connackReceived = false;
    _connected = false;
    _publishCtrl = StreamController.broadcast();

    debugPrint('[IoT] connecting — clientId: $clientId');

    _channel = WebSocketChannel.connect(
      Uri.parse(signedUrl),
      protocols: const ['mqtt'],
    );
    await _channel!.ready;

    _subscription = _channel!.stream.listen(
      _onData,
      onError: (e) { if (gen == _generation) _onError(e); },
      onDone: () { if (gen == _generation) _onDone(); },
      cancelOnError: false,
    );

    final resolvedWill = will?.call(creds.identityId);
    _channel!.sink.add(Uint8List.fromList(_mqttConnect(clientId, will: resolvedWill)));

    await _connackCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('MQTT CONNACK timeout'),
    );

    // Guard: _onDone may have fired in the gap between CONNACK and here
    if (_publishCtrl?.isClosed ?? true) {
      throw StateError('Connection closed immediately after CONNACK');
    }

    _connected = true;
    _connectedAt = DateTime.now();
    debugPrint('[IoT] MQTT connected ✓');

    // Ping at half the keep-alive interval so one lost PINGREQ still leaves
    // a second one inside the broker's 1.5× keep-alive window.
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_connected) return;
      _channel?.sink.add(Uint8List.fromList(const [0xC0, 0x00]));
      _pingRespTimer?.cancel();
      final pingGen = _generation;
      _pingRespTimer = Timer(
        const Duration(seconds: 10),
        () => _onPingTimeout(pingGen),
      );
    });
  }

  @override
  void disconnect() {
    _onDisconnected = null; // suppress reconnect callback
    _connected = false;
    _identityId = null;
    _credentialsService.reset();
    _pingTimer?.cancel();
    _pingTimer = null;
    _pingRespTimer?.cancel();
    _pingRespTimer = null;
    try {
      _channel?.sink.add(Uint8List.fromList(const [0xE0, 0x00]));
    } catch (_) {}
    _channel?.sink.close();
    _subscription?.cancel();
    _channel = null;
    _subscription = null;
    _publishCtrl?.close();
    _publishCtrl = null;
    _pendingSubs.clear();
    debugPrint('[IoT] disconnected');
  }

  @override
  void publish(String topic, String payload, {bool retain = false}) {
    if (!_connected) throw StateError('Not connected');
    MqttLog.pub(topic, payload, retained: retain);
    _channel!.sink.add(Uint8List.fromList(
      _mqttPublish(topic, payload, _pid(), retain: retain),
    ));
  }

  @override
  Stream<MqttMessageEntity> subscribe(String topic) {
    if (!_connected) throw StateError('Not connected');
    MqttLog.sub(topic);
    _sendSubscribe(topic, attempt: 1);
    return _publishCtrl!.stream
        .where((m) => _topicMatches(m.topic, topic))
        .map((m) => MqttMessageEntity(topic: m.topic, payload: m.payload));
  }

  void _sendSubscribe(String topic, {required int attempt}) {
    final pid = _pid();
    _pendingSubs[pid] = (topic: topic, attempt: attempt);
    _channel!.sink.add(Uint8List.fromList(_mqttSubscribe(topic, pid)));
  }

  // ── WebSocket callbacks ───────────────────────────────────────────────────

  // A single WebSocket message can carry more than one MQTT packet — e.g.
  // subscribing to a topic with a retained message pending can bring the
  // SUBACK and the retained PUBLISH back in the same frame. This used to
  // only ever look at the first packet's type byte and treat the rest of
  // the buffer as that packet's payload — a SUBACK-then-PUBLISH frame was
  // silently dropped whole (wrong type match), which meant the QoS 1
  // retained PUBLISH never got its required PUBACK. AWS IoT then treated
  // the client as protocol-violating and closed the connection — which
  // reconnects, resubscribes, hits the same still-retained message, and
  // repeats forever. Walking every packet in the buffer fixes both the
  // lost message and the disconnect loop.
  void _onData(dynamic raw) {
    final Uint8List data;
    if (raw is Uint8List) {
      data = raw;
    } else if (raw is List<int>) {
      data = Uint8List.fromList(raw);
    } else {
      return;
    }
    if (data.isEmpty) return;

    var offset = 0;
    while (offset < data.length) {
      final consumed = _handlePacket(data, offset);
      if (consumed <= 0) break; // incomplete trailing packet — wait for more data
      offset += consumed;
    }
  }

  /// Handles one MQTT packet starting at [start] and returns how many bytes
  /// it occupied (fixed header + remaining length + body), or 0 if the
  /// buffer doesn't contain a complete packet there.
  int _handlePacket(Uint8List data, int start) {
    final type = (data[start] >> 4) & 0x0F;

    var i = start + 1;
    var multiplier = 1;
    var remLen = 0;
    int lenByte;
    do {
      if (i >= data.length) return 0;
      lenByte = data[i++];
      remLen += (lenByte & 0x7F) * multiplier;
      multiplier *= 128;
    } while ((lenByte & 0x80) != 0);

    final bodyStart = i;
    final packetEnd = bodyStart + remLen;
    if (packetEnd > data.length) return 0;

    if (!_connackReceived) {
      if (type == 2) {
        _connackReceived = true;
        final rc = remLen >= 2 ? data[bodyStart + 1] : -1;
        if (rc == 0) {
          _connackCompleter?.complete();
        } else {
          debugPrint('[IoT] CONNACK refused — code $rc');
          _connackCompleter?.completeError(Exception('MQTT CONNACK refused (code $rc)'));
        }
      }
      return packetEnd - start;
    }

    if (type == 3) {
      final qos = (data[start] >> 1) & 0x03;
      _handlePublish(data, bodyStart, packetEnd, qos);
    }
    if (type == 9 && remLen >= 3) {
      _handleSuback(data, bodyStart);
    }
    if (type == 13) {
      _pingRespTimer?.cancel();
      _pingRespTimer = null;
    }
    // Other types (PUBACK, etc.) need no action, but must still be
    // skipped correctly so any packet after them in the same buffer parses.

    return packetEnd - start;
  }

  void _onError(Object error) {
    debugPrint('[IoT] connection error: $error');
    _pingRespTimer?.cancel();
    _pingRespTimer = null;
    _connected = false;
    if (!(_connackCompleter?.isCompleted ?? true)) {
      _connackCompleter?.completeError(error);
    }
    _publishCtrl?.addError(error);
  }

  void _onDone() {
    // The WebSocket close code/reason is the actual authoritative signal
    // for *why* AWS IoT dropped the connection — log it instead of guessing.
    debugPrint('[IoT] connection closed — code: ${_channel?.closeCode}, reason: ${_channel?.closeReason}');
    _pingRespTimer?.cancel();
    _pingRespTimer = null;
    final wasConnected = _connected;
    final connectedAt = _connectedAt;
    _connected = false;
    _connectedAt = null;
    _publishCtrl?.close();
    if (wasConnected) {
      // Treat null connectedAt as an immediate drop (duration zero) so we
      // always take the deferred path rather than calling _onDisconnected
      // directly. A null here means _onDone raced with the connect path.
      final age = connectedAt != null
          ? DateTime.now().difference(connectedAt)
          : Duration.zero;
      if (age < const Duration(seconds: 3)) {
        // Connection dropped very soon after CONNACK — almost certainly AWS IoT
        // closing the previous session's socket (hot restart / duplicate client ID).
        // Delay the reconnect callback so the old socket is fully gone before
        // we open a new connection with the same client ID.
        final gen = _generation;
        debugPrint('[IoT] connection dropped within ${age.inMilliseconds}ms — deferring reconnect');
        Future.delayed(const Duration(seconds: 10), () {
          if (gen == _generation && !_connected) _onDisconnected?.call();
        });
      } else {
        _onDisconnected?.call();
      }
    } else if (!(_connackCompleter?.isCompleted ?? true)) {
      // Channel closed before CONNACK — fail fast instead of waiting for timeout
      _connackCompleter!.completeError(StateError('Connection closed during handshake'));
    }
  }

  void _onPingTimeout(int gen) {
    if (gen != _generation) return;
    debugPrint('[IoT] PINGRESP timeout — network unreachable, treating as disconnect');
    _pingRespTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _connected = false;
    _connectedAt = null;
    _publishCtrl?.close();
    _publishCtrl = null;
    _subscription?.cancel();
    _subscription = null;
    _onDisconnected?.call();
  }

  void _handleSuback(Uint8List data, int bodyStart) {
    final pid = (data[bodyStart] << 8) | data[bodyStart + 1];
    final rc = data[bodyStart + 2];
    final pending = _pendingSubs.remove(pid);
    if (pending == null) return;

    if (rc != 0x80) return; // granted (0x00/0x01/0x02)

    if (pending.attempt >= _maxSubscribeAttempts) {
      debugPrint('[IoT] ✗ subscribe to ${pending.topic} denied — giving up '
          'after ${pending.attempt} attempts');
      return;
    }

    final delay = Duration(seconds: 2 << (pending.attempt - 1));
    debugPrint('[IoT] subscribe to ${pending.topic} denied (SUBACK 0x80) — '
        'retry ${pending.attempt + 1}/$_maxSubscribeAttempts in ${delay.inSeconds}s');
    final gen = _generation;
    Timer(delay, () {
      if (gen != _generation || !_connected) return;
      _sendSubscribe(pending.topic, attempt: pending.attempt + 1);
    });
  }

  void _handlePublish(Uint8List data, int bodyStart, int packetEnd, int qos) {
    var i = bodyStart;
    final topicLen = (data[i] << 8) | data[i + 1];
    i += 2;
    final topic = utf8.decode(data.sublist(i, i + topicLen));
    i += topicLen;
    if (qos > 0) {
      final pidHi = data[i++];
      final pidLo = data[i++];
      _channel?.sink.add(Uint8List.fromList([0x40, 0x02, pidHi, pidLo])); // PUBACK
    }
    final payload = utf8.decode(data.sublist(i, packetEnd));
    MqttLog.rx(topic, payload);
    _publishCtrl?.add((topic: topic, payload: payload));
  }

  int _pid() => _nextPacketId = (_nextPacketId % 0xFFFF) + 1;

  // ── MQTT packet builders ──────────────────────────────────────────────────

  // 30s is AWS IoT's minimum keep-alive. It bounds how fast the broker
  // detects a silently-dead connection (power cut, network loss) and fires
  // the Last Will: ~1.5× keep-alive, so ≤45s. The cost is pinging every
  // 15s and less tolerance for network stalls (>45s stall = disconnect).
  static List<int> _mqttConnect(String clientId, {int keepAliveSec = 30, MqttWill? will}) {
    final id = utf8.encode(clientId);
    const protocolHeader = [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04]; // len + "MQTT" + level

    // Connect flags: bit1 clean session, bit2 will flag, bits4-3 will QoS,
    // bit5 will retain. The will is retained so a fresh subscriber (a user
    // who wasn't connected when the central dropped) still sees "offline".
    var connectFlags = 0x02;
    final payload = <int>[(id.length >> 8) & 0xFF, id.length & 0xFF, ...id];

    if (will != null) {
      connectFlags |= 0x04 | 0x08 | 0x20; // will flag + QoS 1 + retain
      final willTopic = utf8.encode(will.topic);
      final willMessage = utf8.encode(will.payload);
      payload.addAll([
        (willTopic.length >> 8) & 0xFF, willTopic.length & 0xFF, ...willTopic,
        (willMessage.length >> 8) & 0xFF, willMessage.length & 0xFF, ...willMessage,
      ]);
    }

    final vh = [...protocolHeader, connectFlags];
    final ka = [(keepAliveSec >> 8) & 0xFF, keepAliveSec & 0xFF];
    final rem = vh.length + ka.length + payload.length;
    return [0x10, ..._remLen(rem), ...vh, ...ka, ...payload];
  }

  static List<int> _mqttPublish(
    String topic,
    String msg,
    int id, {
    int qos = 1,
    bool retain = false,
  }) {
    final t = utf8.encode(topic);
    final p = utf8.encode(msg);
    final vh = [
      (t.length >> 8) & 0xFF, t.length & 0xFF, ...t,
      if (qos > 0) ...<int>[(id >> 8) & 0xFF, id & 0xFF],
    ];
    final firstByte = 0x30 | ((qos & 0x03) << 1) | (retain ? 0x01 : 0x00);
    return [firstByte, ..._remLen(vh.length + p.length), ...vh, ...p];
  }

  static List<int> _mqttSubscribe(String topic, int id, {int qos = 1}) {
    final t = utf8.encode(topic);
    final pl = [(t.length >> 8) & 0xFF, t.length & 0xFF, ...t, qos & 0x03];
    final vh = [(id >> 8) & 0xFF, id & 0xFF];
    return [0x82, ..._remLen(vh.length + pl.length), ...vh, ...pl];
  }

  static List<int> _remLen(int len) {
    final r = <int>[];
    do {
      var b = len & 0x7F;
      len >>= 7;
      if (len > 0) b |= 0x80;
      r.add(b);
    } while (len > 0);
    return r;
  }

  static bool _topicMatches(String topic, String filter) {
    if (filter == '#') return true;
    if (filter.endsWith('/#')) return topic.startsWith(filter.substring(0, filter.length - 2));
    if (filter.contains('+')) {
      final pat = filter.split('/').map((p) => p == '+' ? '[^/]+' : RegExp.escape(p)).join('/');
      return RegExp('^$pat\$').hasMatch(topic);
    }
    return topic == filter;
  }
}
