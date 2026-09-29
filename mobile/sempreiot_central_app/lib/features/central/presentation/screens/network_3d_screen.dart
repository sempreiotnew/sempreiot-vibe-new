import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/ota_push_report.dart';
import '../../application/root_election_provider.dart';
import '../../application/safr_traffic_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_product.dart';
import '../widgets/device_avatar.dart';
import '../widgets/device_menu.dart';
import '../widgets/network_3d/detector_sprites.dart';
import '../widgets/network_3d/device_3d_chip.dart';
import '../widgets/network_3d/force_graph_3d.dart';
import '../widgets/network_3d/network_3d_math.dart';
import '../widgets/network_3d/network_3d_painter.dart';
import '../widgets/ota_rede_widgets.dart';

/// Rede 3D — PROTOTYPE. The Rede map's network as a force-directed 3D
/// graph (like Obsidian's graph view), in the Rede map's own look: the same
/// chips, links, signal colours, dBm pills, packets, pulses and lane labels.
///
/// Devices push each other apart and links pull like springs, each device
/// held at its level: top → bottom ("Árvore") or left → right ("Larga").
/// Drag a device to pull or push it — the rest reacts and settles. Drag the
/// background to turn the graph, pinch to zoom, two fingers to move; wheel
/// and arrow keys / + − on the web. A tap opens the device's menu.
class Network3dScreen extends ConsumerStatefulWidget {
  const Network3dScreen({super.key});

  @override
  ConsumerState<Network3dScreen> createState() => _Network3dScreenState();
}

class _Flight {
  _Flight({
    required this.fromTarget,
    required this.toTarget,
    required this.fromDistance,
    required this.toDistance,
    required this.fromYaw,
    required this.toYaw,
    required this.fromPitch,
    required this.toPitch,
    required this.duration,
    this.onArrive,
  }) : startedAt = DateTime.now();

  final Vec3 fromTarget, toTarget;
  final double fromDistance, toDistance, fromYaw, toYaw, fromPitch, toPitch;
  final Duration duration;
  final DateTime startedAt;
  final VoidCallback? onArrive;
}

class _Network3dScreenState extends ConsumerState<Network3dScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  final _camera = OrbitCamera(yaw: 0, pitch: 0);
  final _graph = ForceGraph3d();
  final _focus = FocusNode();
  StreamSubscription<SafrTrafficTick>? _trafficSub;

  Map<String, TopologyNode> _nodes = const {};

  /// The smoke detector model's sprites (loaded once; spheres until then).
  DetectorSprites? _sprites;
  TopologyNode? _board;
  String? _graphKey;
  final _packets = <Packet3d>[];

  /// A firmware push, as the map draws it: what the board is doing with it
  /// and what waits on the board for the units.
  OtaBoardActivity? _activity;
  Map<SafrProductFamily, String> _stored = const {};

  /// Chunks of a firmware push, turned into packets a few at a time.
  ProviderSubscription<int>? _otaSub;
  final _otaThrottle = OtaPacketThrottle(
    every: 8,
    minGap: const Duration(milliseconds: 700),
  );

  /// One crossing of the tablet–board link by a packet of a push.
  static const _otaHop = Duration(milliseconds: 900);

  Size _size = Size.zero;
  bool _fitted = false;
  _Flight? _flight;

  double _lastScale = 1;
  Offset _lastFocal = Offset.zero;
  int _pointers = 0;

  bool _touring = false;
  List<String> _tourOrder = const [];
  int _tourIndex = 0;
  Timer? _tourTimer;

  @override
  void initState() {
    super.initState();
    _ticker =
        AnimationController(vsync: this, duration: const Duration(days: 1))
          ..addListener(_onFrame)
          ..repeat();
    _trafficSub = ref.read(safrTrafficProvider).stream.listen(_onTraffic);
    _otaSub = ref.listenManual<int>(
      otaPushViewProvider.select(otaChunksOnTheWay),
      (_, chunks) => _onOtaChunks(chunks),
    );
    DetectorSprites.load().then((s) {
      if (mounted) setState(() => _sprites = s);
    });
  }

  @override
  void dispose() {
    _tourTimer?.cancel();
    _trafficSub?.cancel();
    _otaSub?.close();
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── Frame ────────────────────────────────────────────────────────────────

  void _onFrame() {
    final now = DateTime.now();
    _graph.step();
    final f = _flight;
    if (f != null) {
      final raw = now.difference(f.startedAt).inMicroseconds /
          f.duration.inMicroseconds;
      final k = Curves.easeInOutCubic.transform(raw.clamp(0.0, 1.0));
      _camera
        ..target = Vec3.lerp(f.fromTarget, f.toTarget, k)
        ..distance = f.fromDistance + (f.toDistance - f.fromDistance) * k
        ..yaw = f.fromYaw + (f.toYaw - f.fromYaw) * k
        ..pitch = f.fromPitch + (f.toPitch - f.fromPitch) * k;
      if (raw >= 1) {
        _flight = null;
        f.onArrive?.call();
      }
    }
    _packets.removeWhere((p) => p.progress(now) >= 1);
  }

  // ── Data ─────────────────────────────────────────────────────────────────

  void _sync(List<TopologyNode> all) {
    TopologyNode? board;
    final nodes = <String, TopologyNode>{};
    for (final n in all) {
      if (n.layer == 0) {
        board ??= n;
      } else {
        nodes[n.mac] = n;
      }
    }
    _nodes = nodes;
    _board = board;
    final key =
        (nodes.values.map((n) => '${n.mac}>${n.parentMac}@${n.layer}').toList()
              ..sort())
            .join(',');
    if (key != _graphKey) {
      final first = (_graphKey ?? '').isEmpty;
      _graphKey = key;
      _graph.setNodes(nodes.values.toList(), boardMac: board?.mac);
      // Opening: start settled, not as an explosion.
      if (first) _graph.settle();
      if (_touring) _tourOrder = _treeOrder();
    }
  }

  /// The tablet while a push runs: beside the CENTRAL, on its level, on
  /// the side the lane label is not (right of a row; under a column in the
  /// wide view).
  Vec3? get _tabletPos {
    if (_activity == null) return null;
    final central = _graph.pos[graphCentralKey];
    if (central == null) return null;
    return central +
        (_graph.axis == GraphAxis.vertical
            ? const Vec3(150, 0, 0)
            : const Vec3(0, -130, 0));
  }

  /// A firmware push: the board confirmed chunks. One blue packet from the
  /// tablet to the board (a frame sent), one cyan packet back behind it
  /// (the board's ACK) — as on the Rede map, and on this link only.
  void _onOtaChunks(int chunks) {
    final now = DateTime.now();
    if (!_otaThrottle.take(chunks, now)) return;
    _packets
      ..add(Packet3d(
        origin: otaPacketOrigin,
        uplink: false,
        path: const [graphTabletKey, graphCentralKey],
        color: packetColor(0, false),
        severity: 0,
        startedAt: now,
        duration: _otaHop,
        lane: -4,
      ))
      ..add(Packet3d(
        origin: otaPacketOrigin,
        uplink: true,
        path: const [graphCentralKey, graphTabletKey],
        color: packetColor(0, true),
        severity: 0,
        startedAt: now.add(_otaHop),
        duration: _otaHop,
        lane: -4,
      ));
    while (_packets.length > 40) {
      _packets.removeAt(0);
    }
  }

  /// Same packet rules as the Rede map (topology_screen.dart `_onTraffic`).
  void _onTraffic(SafrTrafficTick tick) {
    final nodes = _nodes;
    final origin = nodes[tick.mac];
    if (origin == null) return;
    final leafRoutine = tick.severity < 1 &&
        origin.isLeaf &&
        tick.direction == SafrTrafficDirection.uplink;
    final ackDown = tick.ack && tick.direction == SafrTrafficDirection.downlink;
    if (tick.severity < 1 && !leafRoutine && !ackDown) return;

    final path = <String>[tick.mac];
    final first = tick.parentMac != null && nodes.containsKey(tick.parentMac)
        ? tick.parentMac
        : origin.parentMac;
    var cursor = first != null ? nodes[first] : null;
    if (cursor != null) path.add(cursor.mac);
    var guard = 0;
    while (cursor?.parentMac != null &&
        nodes.containsKey(cursor!.parentMac) &&
        guard++ < 8) {
      path.add(cursor.parentMac!);
      cursor = nodes[cursor.parentMac];
    }
    path.add(graphCentralKey);

    final uplink = tick.direction == SafrTrafficDirection.uplink;
    final color = packetColor(tick.severity, ackDown);
    final now = DateTime.now();
    for (final p in _packets) {
      if (p.origin == tick.mac &&
          p.uplink == uplink &&
          now.difference(p.startedAt).inMilliseconds < 1200) {
        if (tick.severity > p.severity) {
          p
            ..color = color
            ..severity = tick.severity;
        }
        return;
      }
    }
    final hop =
        leafRoutine || origin.isLeaf ? packetHopMs.leaf : packetHopMs.node;
    _packets.add(Packet3d(
      origin: tick.mac,
      uplink: uplink,
      path: uplink ? path : path.reversed.toList(),
      color: color,
      severity: tick.severity,
      startedAt: now,
      duration: Duration(milliseconds: hop * (path.length - 1)),
    ));
    if (_packets.length > 40) _packets.removeAt(0);
  }

  // ── Camera ───────────────────────────────────────────────────────────────

  double get _focal => math.min(_size.width, _size.height) * 0.9;

  void _touch() {
    _flight = null;
    if (_touring) _stopTour();
  }

  /// Frames the whole graph, seen from the front (as the 2D map).
  void _fit({bool animate = true}) {
    if (_size.isEmpty) return;
    var (lo, hi) = _graph.bounds();
    // The tablet of a push is part of the picture while it is drawn.
    final tablet = _tabletPos;
    if (tablet != null) {
      lo = Vec3(math.min(lo.x, tablet.x), math.min(lo.y, tablet.y), lo.z);
      hi = Vec3(math.max(hi.x, tablet.x), math.max(hi.y, tablet.y), hi.z);
    }
    final center = Vec3.lerp(lo, hi, 0.5);
    // Half extents plus a chip's margin; the focal length is set by the
    // short side, the long side sees proportionally more.
    final halfW = (hi.x - lo.x) / 2 + 80;
    final halfH = (hi.y - lo.y) / 2 + 70;
    final f = _focal;
    final d = math.max(
            halfW * f / (_size.width / 2), halfH * f / (_size.height / 2)) +
        (hi.z - lo.z) / 2;
    final to = math.max(d, 250.0);
    if (!animate) {
      _camera
        ..target = center
        ..distance = to
        ..yaw = 0
        ..pitch = 0;
      return;
    }
    // Straight on, like the 2D map: any tilt makes the near edge project
    // larger and overshoot the frame.
    _flyTo(center, to, 0, 0);
  }

  void _flyTo(Vec3 target, double distance, double yaw, double pitch,
      {Duration duration = const Duration(milliseconds: 900),
      VoidCallback? onArrive}) {
    var dy = (yaw - _camera.yaw) % (2 * math.pi);
    if (dy > math.pi) dy -= 2 * math.pi;
    if (dy < -math.pi) dy += 2 * math.pi;
    _flight = _Flight(
      fromTarget: _camera.target,
      toTarget: target,
      fromDistance: _camera.distance,
      toDistance:
          distance.clamp(OrbitCamera.minDistance, OrbitCamera.maxDistance),
      fromYaw: _camera.yaw,
      toYaw: _camera.yaw + dy,
      fromPitch: _camera.pitch,
      toPitch: pitch.clamp(OrbitCamera.minPitch, OrbitCamera.maxPitch),
      duration: duration,
      onArrive: onArrive,
    );
  }

  /// Centres a device, close enough that its chip reads at ~1.4×.
  void _flyToDevice(String key, {VoidCallback? onArrive, Duration? duration}) {
    final p = _graph.pos[key];
    if (p == null) return;
    _flyTo(p, _focal / 1.4, _camera.yaw, _camera.pitch,
        duration: duration ?? const Duration(milliseconds: 800),
        onArrive: onArrive);
  }

  void _setAxis(GraphAxis a) {
    if (a == _graph.axis) return;
    _touch();
    setState(() => _graph.setAxis(a));
    _graph.settle();
    _fit();
  }

  // ── Tour: every device, level by level ───────────────────────────────────

  List<String> _treeOrder() {
    final keys = _graph.pos.keys.toList()
      ..sort((a, b) {
        final l = (_graph.level[a] ?? 0).compareTo(_graph.level[b] ?? 0);
        if (l != 0) return l;
        final pa = _graph.pos[a]!, pb = _graph.pos[b]!;
        return _graph.axis == GraphAxis.vertical
            ? pa.x.compareTo(pb.x)
            : pb.y.compareTo(pa.y);
      });
    return keys;
  }

  void _startTour() {
    _tourOrder = _treeOrder();
    if (_tourOrder.isEmpty) return;
    setState(() {
      _touring = true;
      _tourIndex = 0;
    });
    _tourStep();
  }

  void _tourStep() {
    if (!_touring || !mounted) return;
    if (_tourIndex >= _tourOrder.length) _tourIndex = 0;
    setState(() {});
    _flyToDevice(_tourOrder[_tourIndex],
        duration: const Duration(milliseconds: 1200), onArrive: () {
      _tourTimer?.cancel();
      _tourTimer = Timer(const Duration(milliseconds: 2200), () {
        _tourIndex++;
        _tourStep();
      });
    });
  }

  void _stopTour() {
    _tourTimer?.cancel();
    setState(() => _touring = false);
  }

  // ── Input ────────────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _touch();
    _lastScale = 1;
    _lastFocal = d.localFocalPoint;
    _pointers = d.pointerCount;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final delta = d.localFocalPoint - _lastFocal;
    _lastFocal = d.localFocalPoint;
    if (d.pointerCount != _pointers) {
      _pointers = d.pointerCount;
      _lastScale = d.scale;
      return;
    }
    if (d.pointerCount == 1) {
      _camera
        ..yaw -= delta.dx * 0.008
        ..pitch += delta.dy * 0.006;
    } else {
      final ratio = d.scale / (_lastScale == 0 ? 1 : _lastScale);
      _lastScale = d.scale;
      if (ratio.isFinite && ratio > 0) _camera.distance /= ratio;
      _camera.target = _camera.target +
          _camera.projector(_size).screenDeltaToWorld(delta, _camera.distance);
    }
    _camera.clamp();
  }

  void _zoom(double factor) {
    _touch();
    _camera
      ..distance /= factor
      ..clamp();
  }

  // Dragging a device: it follows the finger in the screen's plane.
  void _dragStart(String key) {
    _touch();
    _graph.dragged = key;
    _graph.alpha = math.max(_graph.alpha, 0.35);
  }

  void _dragUpdate(String key, Offset delta) {
    final p = _graph.pos[key];
    if (p == null) return;
    final proj = _camera.projector(_size);
    final depth = (p - proj.eye).dot(proj.forward);
    // screenDeltaToWorld moves the camera opposite a pan: negate for the
    // device to follow the finger.
    _graph.dragBy(key, proj.screenDeltaToWorld(-delta, depth));
  }

  void _dragEnd() {
    _graph.dragged = null;
    _graph.alpha = math.max(_graph.alpha, 0.3); // let the rest settle
  }

  void _openMenu(String key, BuildContext chipContext) {
    final node = key == graphCentralKey ? _board : _nodes[key];
    if (node == null) return;
    showDeviceMenu(
      context: context,
      ref: ref,
      node: node,
      anchor: deviceAnchorOf(chipContext),
    );
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    void turn(double yaw, double pitch) {
      _touch();
      _camera
        ..yaw += yaw
        ..pitch += pitch
        ..clamp();
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      turn(0.06, 0);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      turn(-0.06, 0);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      turn(0, 0.05);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      turn(0, -0.05);
    } else if (k == LogicalKeyboardKey.equal ||
        k == LogicalKeyboardKey.numpadAdd) {
      _zoom(1.15);
    } else if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract) {
      _zoom(1 / 1.15);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _sync(ref.watch(topologyProvider));
    final election = ref.watch(rootElectionProvider);
    // A firmware push (rebuilt once per percent, not per chunk).
    final (activity, stored) =
        ref.watch(otaPushViewProvider.select(otaMapOverlay));
    final appeared = (activity == null) != (_activity == null);
    _activity = activity;
    _stored = stored;
    if (activity == null) {
      _packets.removeWhere((p) => p.origin == otaPacketOrigin);
    }
    if (appeared && _fitted) {
      // The tablet came or went: frame the picture again.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => mounted && !_touring ? _fit() : null);
    }

    final tourKey = _touring && _tourOrder.isNotEmpty
        ? _tourOrder[_tourIndex % _tourOrder.length]
        : null;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Rede 3D'),
            SizedBox(width: 8),
            _ProtoChip(),
          ],
        ),
      ),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            const OtaRedeBanner(),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final size = Size(c.maxWidth, c.maxHeight);
                if (size != _size) {
                  final rotated = !_size.isEmpty;
                  _size = size;
                  // Rotation / resize: frame the graph again.
                  if (rotated) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => mounted ? _fit(animate: false) : null);
                  }
                }
                if (!_fitted && _graph.pos.length > 1) {
                  _fitted = true;
                  _fit(animate: false);
                }
                // A push is drawn on the central: it is on the map while
                // one runs, mesh or no mesh.
                if (_nodes.isEmpty && _activity == null) {
                  return const _EmptyGraph();
                }
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Listener(
                        onPointerSignal: (e) {
                          if (e is PointerScrollEvent) {
                            _zoom(e.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1);
                          }
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: _onScaleStart,
                          onScaleUpdate: _onScaleUpdate,
                          child: ClipRect(
                            child: AnimatedBuilder(
                              animation: _ticker,
                              builder: (context, _) =>
                                  _scene(context, election),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (tourKey != null)
                      Positioned(
                        top: 8,
                        left: 16,
                        right: 16,
                        child: Center(
                          child: _TourCard(
                            title: tourKey == graphCentralKey
                                ? 'Central'
                                : deviceDisplayName(_nodes[tourKey]!),
                            subtitle: tourKey == graphCentralKey
                                ? 'Placa + tablet'
                                : deviceStateLabel(_nodes[tourKey]!),
                            index: _tourIndex % _tourOrder.length + 1,
                            total: _tourOrder.length,
                          ),
                        ),
                      ),
                  ],
                );
              }),
            ),
            _Toolbar(
              axis: _graph.axis,
              touring: _touring,
              onAxis: _setAxis,
              onZoomIn: () => _zoom(1.3),
              onZoomOut: () => _zoom(1 / 1.3),
              onFit: () {
                _touch();
                _fit();
              },
              onTour: () => _touring ? _stopTour() : _startTour(),
            ),
          ],
        ),
      ),
    );
  }

  /// One frame: project, paint links underneath, then the chips far → near.
  Widget _scene(BuildContext context, RootElectionState election) {
    final proj = _camera.projector(_size);
    final projected = <String, Projected>{};
    _graph.pos.forEach((k, p) {
      final pr = proj.project(p);
      if (pr != null) projected[k] = pr;
    });
    var near = double.infinity, far = 0.0;
    for (final pr in projected.values) {
      near = math.min(near, pr.depth);
      far = math.max(far, pr.depth);
    }
    // Front at full strength, the back dimmed: reads as depth when turned.
    double fade(double depth) => far - near < 40
        ? 1
        : (1 - 0.5 * (depth - near) / (far - near)).clamp(0.5, 1.0);

    final candidates = election.electing ? election.candidates : <String>{};
    final order = projected.keys.toList()
      ..sort((a, b) => projected[b]!.depth.compareTo(projected[a]!.depth));
    final tablet = _tabletPos;
    final tabletAt = tablet == null ? null : proj.project(tablet);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: Network3dPainter(
              projector: proj,
              graph: _graph,
              projected: projected,
              nodes: _nodes,
              packets: _packets,
              isDark: context.isDark,
              depthFade: fade,
              rootMac: election.rootMac,
              candidates: candidates,
              tablet: tablet,
            ),
          ),
        ),
        if (tabletAt != null) _tabletChip(tabletAt, fade),
        for (final key in order)
          _chip(key, projected[key]!, fade, election, candidates),
      ],
    );
  }

  Widget _tabletChip(Projected pr, double Function(double) fade) {
    final s = pr.scale.clamp(0.2, 2.8);
    return Positioned(
      left: pr.offset.dx - OtaTabletChip.width / 2 * s,
      top: pr.offset.dy - OtaTabletChip.circle / 2 * s,
      child: Transform.scale(
        scale: s,
        alignment: Alignment.topLeft,
        child: Opacity(
          opacity: fade(pr.depth),
          child: const OtaTabletChip(),
        ),
      ),
    );
  }

  Widget _chip(String key, Projected pr, double Function(double) fade,
      RootElectionState election, Set<String> candidates) {
    // A chip is 104 world units wide: its size follows the world, so the
    // physics' spacing keeps chips apart on screen at any zoom.
    final s = pr.scale.clamp(0.2, 2.8);
    final isCentral = key == graphCentralKey;
    final node = _nodes[key];
    final opacity =
        fade(pr.depth) * ((node?.stale ?? false) ? deviceStaleOpacity : 1.0);
    // Devices as spheres; the light is fixed in the world, so turning the
    // graph moves their highlight.
    final light = sphereLightFor(_camera.yaw, _camera.pitch);
    final sprites = _sprites;
    final pending = node == null ? null : pendingFirmwareFor(node, _stored);
    final child = isCentral
        ? Central3dChip(light: light, board: _board, activity: _activity)
        // Sensors are smoke detectors: the Blender model once it is loaded.
        : node!.isLeaf && sprites != null
            ? Detector3dChip(
                node: node,
                sprites: sprites,
                yaw: _camera.yaw,
                pitch: _camera.pitch,
                pending: pending,
              )
            : Device3dChip(
                node: node,
                light: light,
                isRoot: node.online && node.mac == election.rootMac,
                isCandidate: candidates.contains(node.mac),
                pending: pending,
              );
    final w = isCentral ? Central3dChip.width : Device3dChip.width;
    final top = isCentral ? central3dAnchorY : device3dAnchorY;
    final dragging = _graph.dragged == key;
    return Positioned(
      key: ValueKey(key),
      left: pr.offset.dx - w / 2 * s,
      top: pr.offset.dy - top * s,
      child: Transform.scale(
        scale: s,
        alignment: Alignment.topLeft,
        child: Opacity(
          opacity: opacity,
          child: Builder(
            builder: (chipContext) => MouseRegion(
              cursor: isCentral
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.grab,
              child: GestureDetector(
                onTap: () => _openMenu(key, chipContext),
                onPanStart: isCentral ? null : (_) => _dragStart(key),
                onPanUpdate: isCentral
                    ? null
                    // The chip is scaled: its local delta × s = screen.
                    : (d) => _dragUpdate(key, d.delta * s),
                onPanEnd: isCentral ? null : (_) => _dragEnd(),
                onPanCancel: isCentral ? null : _dragEnd,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: dragging
                        ? AppColors.secondary.withValues(alpha: 0.08)
                        : null,
                    border: dragging
                        ? Border.all(
                            color: AppColors.secondary.withValues(alpha: 0.6))
                        : null,
                  ),
                  child: SizedBox(width: w, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Overlay pieces ───────────────────────────────────────────────────────────

class _ProtoChip extends StatelessWidget {
  const _ProtoChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: AppColors.secondary.withValues(alpha: 0.4), width: 0.6),
      ),
      child: const Text(
        'PROTÓTIPO',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: AppColors.secondary,
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.axis,
    required this.touring,
    required this.onAxis,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onTour,
  });

  final GraphAxis axis;
  final bool touring;
  final ValueChanged<GraphAxis> onAxis;
  final VoidCallback onZoomIn, onZoomOut, onFit, onTour;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String tip, VoidCallback onTap) => IconButton(
          tooltip: tip,
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, color: context.textPrimary, size: 20),
        );

    return Container(
      decoration: BoxDecoration(
        color: context.barColor,
        border: Border(
          top: BorderSide(
              color: context.borderColor.withValues(alpha: 0.5), width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          // Scrolls sideways on the narrowest phones instead of overflowing.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                SegmentedButton<GraphAxis>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: GraphAxis.vertical,
                      icon: Icon(Icons.account_tree_rounded, size: 18),
                      label: Text('Árvore'),
                      tooltip: 'Níveis de cima para baixo',
                    ),
                    ButtonSegment(
                      value: GraphAxis.wide,
                      icon: Icon(Icons.swap_horiz_rounded, size: 18),
                      label: Text('Larga'),
                      tooltip: 'Níveis da esquerda para a direita',
                    ),
                  ],
                  selected: {axis},
                  onSelectionChanged: (s) => onAxis(s.first),
                ),
                const SizedBox(width: 8),
                btn(Icons.add_rounded, 'Aproximar', onZoomIn),
                btn(Icons.remove_rounded, 'Afastar', onZoomOut),
                btn(Icons.center_focus_strong_rounded, 'Ajustar à tela', onFit),
                TextButton.icon(
                  onPressed: onTour,
                  icon: Icon(
                    touring ? Icons.stop_rounded : Icons.flight_rounded,
                    size: 18,
                  ),
                  label: Text(touring ? 'Parar' : 'Percorrer'),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.secondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TourCard extends StatelessWidget {
  const _TourCard({
    required this.title,
    required this.subtitle,
    required this.index,
    required this.total,
  });

  final String title, subtitle;
  final int index, total;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: context.surfaceColor.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.4), width: 0.7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.flight_rounded,
                size: 18, color: AppColors.secondary),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700),
                  ),
                  Text(
                    subtitle,
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$index / $total',
              style: TextStyle(color: context.textSecondary, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyGraph extends StatelessWidget {
  const _EmptyGraph();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.view_in_ar_rounded,
                size: 52, color: context.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              'Nenhum dispositivo na rede',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'O grafo aparece aqui assim que a placa\n'
              'reportar a malha pela serial.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
