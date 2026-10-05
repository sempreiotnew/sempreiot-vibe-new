import 'dart:ui' show Tangent;
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_rollout_report.dart';
import '../../application/root_election_provider.dart';
import '../../application/safr_traffic_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_product.dart';
import 'device_menu.dart' show deviceAnchorOf;
import 'device_avatar.dart';
import 'ota_rede_widgets.dart';

/// The 2D map of the fire-alarm mesh, shared by Rede and "Atualizar
/// dispositivos": central on top, root marked, curved glowing links, lane
/// labels, pan / pinch / zoom buttons, and dots with trails travelling along
/// the real path of every frame — visible proof that messages cross the
/// system. The screen around it owns everything else (status strip, menus).
class MeshMap extends ConsumerStatefulWidget {
  const MeshMap({
    super.key,
    required this.nodes,
    required this.board,
    required this.election,
    required this.onNodeTap,
    this.showOta = true,
    this.overlay,
    this.selected = const {},
    this.boardSelected = false,
    this.focus,
    this.selectionTarget,
    this.onCentralTap,
  });

  /// The mesh units (layer 1 and below); the board is [board].
  final List<TopologyNode> nodes;

  /// The board (layer 0), folded into the CENTRAL chip; null = not heard.
  final TopologyNode? board;

  /// Who is root, or that the mesh is still deciding.
  final RootElectionState election;

  /// A tap on a unit, with the chip's screen rect (a menu drops from it).
  final void Function(TopologyNode node, Rect anchor) onNodeTap;

  /// Firmware push and rollout drawn on the map: the tablet and its cable,
  /// rings, the phase under each unit, the image's packets.
  final bool showOta;

  /// What is drawn on the units of an update; null = the board's own
  /// rollout ("Atualizar dispositivos" passes its run, which outlives the
  /// board's table).
  final OtaRolloutOverlay? overlay;

  /// Units chosen for an update: a ring and a check around the avatar.
  final Set<String> selected;

  /// The board (the CENTRAL) is chosen.
  final bool boardSelected;

  /// While an update runs, the units it does not touch are faded; null =
  /// nothing faded.
  final Set<String>? focus;

  /// Under a chosen unit: "v0.1.0 → [selectionTarget]"; null = its version.
  final String? selectionTarget;

  /// A tap on the CENTRAL chip; null = the chip is not tappable.
  final VoidCallback? onCentralTap;

  @override
  ConsumerState<MeshMap> createState() => _MeshMapState();
}

/// Pseudo-MAC of the central in the graph (top of the tree).
const _centralKey = '@central';

/// The tablet, beside the central while a firmware push runs: the image
/// goes from it to the board over the USB cable (protocol §13.3).
const _tabletKey = '@tablet';

/// `origin` of the packets of a firmware push (never a MAC).
const _otaOrigin = '@ota';

/// One crossing of the tablet–board link by a packet of a push.
const _otaHop = Duration(milliseconds: 900);

/// `origin` of the packets of a rollout (never a MAC): the image on its way
/// from the board to the unit that downloads it (protocol §13.4).
const _rolloutOrigin = '@rollout';

/// While a unit downloads, a packet leaves the board this often.
const _rolloutPacketEvery = Duration(milliseconds: 1500);

/// The map's zoom factor. The map is only ever translated and uniformly
/// scaled, so the x-axis entry IS the scale. Never read the "max scale on
/// axis" helper here: it also looks at the z axis, which reads 1.0 whenever
/// the map is zoomed OUT below 1:1 — the landscape opening view — and every
/// zoom, pan clamp and label position then computed with the wrong scale.
double _scaleOf(Matrix4 m) => m.storage[0];

/// Opacity of a device (and its link) that has been silent for longer than
/// [topologyStaleAfter]: still on the map, visibly faded.
const _staleOpacity = deviceStaleOpacity;

class _MeshMapState extends ConsumerState<MeshMap>
    with SingleTickerProviderStateMixin {
  /// Floor for pinch/button zoom-out; the fit scale may go below it when
  /// the tree is taller than the viewport (landscape), so the effective
  /// minimum is min(_minZoom, fit).
  static const _minZoom = 0.5;
  static const _maxZoom = 4.0;

  late final AnimationController _ticker;
  final _dots = <_TrafficDot>[];
  final _transform = TransformationController();
  Size _viewSize = Size.zero;
  Size _canvasSize = Size.zero;

  /// (viewport, canvas) the current transform was fitted for; a change in
  /// either (rotation, a new layer) re-fits so the tree never ends up
  /// off-screen or cropped.
  (Size, Size)? _fittedFor;
  StreamSubscription<SafrTrafficTick>? _trafficSub;

  /// Chunks of a firmware push, turned into packets a few at a time.
  ProviderSubscription<int>? _otaSub;
  final _otaThrottle = OtaPacketThrottle(
    every: 8,
    minGap: const Duration(milliseconds: 700),
  );

  /// A rollout: the unit that downloads now, and the packets to it.
  ProviderSubscription<String?>? _rolloutSub;
  Timer? _rolloutTimer;
  String? _downloading;

  /// A change of the tree's shape (a node joined, left or moved layer)
  /// re-fits only once the shape has held still for this long, so a
  /// failover does not make the map jump on every intermediate state.
  /// A viewport change (rotation) still re-fits at once.
  static const _refitSettle = Duration(milliseconds: 1500);
  Timer? _refitTimer;

  @override
  void initState() {
    super.initState();
    // Continuous vsync clock: the painter derives dot positions and pulse
    // phases from wall time, so one controller animates everything.
    _ticker =
        AnimationController(vsync: this, duration: const Duration(days: 1))
          ..repeat();
    _trafficSub = ref.read(safrTrafficProvider).stream.listen(_onTraffic);
    if (!widget.showOta) return;
    _otaSub = ref.listenManual<int>(
      otaPushViewProvider.select(otaChunksOnTheWay),
      (_, chunks) => _onOtaChunks(chunks),
    );
    final given = widget.overlay;
    if (given != null) {
      _onDownloading(given.downloading);
      return;
    }
    _rolloutSub = ref.listenManual<String?>(
      otaRolloutOverlayProvider.select((o) => o.downloading),
      (_, mac) => _onDownloading(mac),
      fireImmediately: true,
    );
  }

  @override
  void didUpdateWidget(MeshMap old) {
    super.didUpdateWidget(old);
    final given = widget.overlay;
    if (widget.showOta && given != null && given.downloading != _downloading) {
      _onDownloading(given.downloading);
    }
  }

  @override
  void dispose() {
    _refitTimer?.cancel();
    _rolloutTimer?.cancel();
    _rolloutSub?.close();
    _trafficSub?.cancel();
    _otaSub?.close();
    _transform.dispose();
    _ticker.dispose();
    super.dispose();
  }

  /// Button zoom: pivots on the tree's centre line and the screen's middle.
  void _zoomBy(double factor) => _applyZoom(factor);

  /// Scales the map by [factor], clamped to the zoom limits, about a pivot
  /// in SCREEN space: x = the tree's own centre line (so the tree never
  /// moves sideways on its own — the old code pivoted on a canvas point and
  /// drifted), y = [pivotY] (the fingers' row for a pinch) or the middle
  /// of the screen (buttons).
  void _applyZoom(double factor, {double? pivotY}) {
    final current = _scaleOf(_transform.value);
    final target =
        (current * factor).clamp(math.min(_minZoom, _fitScale), _maxZoom);
    final applied = target / current;
    if (applied == 1.0) return;
    final treeCentreX =
        _transform.value.getTranslation().x + _canvasSize.width / 2 * current;
    final c = Offset(treeCentreX, pivotY ?? _viewSize.height / 2);
    final about = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(applied, applied, applied, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    _transform.value = _clamped(about * _transform.value);
  }

  /// Moves the map by [delta] screen pixels.
  void _applyPan(Offset delta) {
    if (delta == Offset.zero) return;
    _transform.value = _clamped(
        Matrix4.translationValues(delta.dx, delta.dy, 0) * _transform.value);
  }

  /// Keeps at least part of the canvas on screen: the map can be dragged
  /// around freely but never completely lost (margin in screen pixels).
  Matrix4 _clamped(Matrix4 m) {
    const margin = 320.0;
    final s = _scaleOf(m);
    final t = m.getTranslation();
    final slackX = _viewSize.width - _canvasSize.width * s;
    final slackY = _viewSize.height - _canvasSize.height * s;
    final tx = t.x
        .clamp(math.min(slackX, 0.0) - margin, math.max(slackX, 0.0) + margin);
    final ty = t.y
        .clamp(math.min(slackY, 0.0) - margin, math.max(slackY, 0.0) + margin);
    if (tx == t.x && ty == t.y) return m;
    return m.clone()..setTranslationRaw(tx, ty, 0);
  }

  // Pinch / drag. Flutter reports both through one scale gesture: `scale`
  // is cumulative since the gesture started and the focal point is the
  // fingers' centre (or the single finger).
  double _gestureScale = 1.0;
  Offset _gestureFocal = Offset.zero;

  void _onScaleStart(ScaleStartDetails d) {
    _gestureScale = 1.0;
    _gestureFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.scale != _gestureScale && _gestureScale != 0) {
      _applyZoom(d.scale / _gestureScale, pivotY: d.localFocalPoint.dy);
      _gestureScale = d.scale;
    }
    _applyPan(d.localFocalPoint - _gestureFocal);
    _gestureFocal = d.localFocalPoint;
  }

  /// Below this the chips stop being readable, so the opening view never
  /// goes smaller — a very tall tree is panned instead.
  static const _fitFloor = 0.7;

  /// Opening/"fit" scale: the whole canvas in the viewport when that stays
  /// readable, else [_fitFloor]; never above 1:1.
  double get _fitScale {
    if (_viewSize.isEmpty || _canvasSize.isEmpty) return 1.0;
    final fit = math.min(_viewSize.width / _canvasSize.width,
        _viewSize.height / _canvasSize.height);
    return fit.clamp(_fitFloor, 1.0);
  }

  /// "Ajustar à tela": the tree centred in the viewport (in landscape it
  /// opens zoomed out rather than cropped). When it is still bigger than the
  /// screen at the readable floor it stays centred across (the central on
  /// the centre line, the outer siblings reached by panning) and starts at
  /// the top.
  void _fitToView() {
    final s = _fitScale;
    final tx = (_viewSize.width - _canvasSize.width * s) / 2;
    final ty = math.max(0.0, (_viewSize.height - _canvasSize.height * s) / 2);
    _transform.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(s, s, s, 1);
  }

  void _onTraffic(SafrTrafficTick tick) {
    final nodes = {
      for (final n in ref.read(topologyProvider))
        if (n.layer > 0) n.mac: n
    };
    final origin = nodes[tick.mac];
    if (origin == null) return;
    // Only animate real events (alert/alarm/trouble) from AC nodes. Their
    // routine traffic — heartbeats every 15 s, topology, ACKs — used to spawn
    // a dot every time (the constant blue balls); those are dropped so the
    // walk-test dot stands out. A battery leaf is the exception: it wakes
    // once a minute and its every frame is the news that it is alive, so its
    // heartbeat travels the tree as a calm accent-coloured packet
    // (protocol §12.2; reference row 6.8).
    final leafRoutine = tick.severity < 1 &&
        origin.isLeaf &&
        tick.direction == SafrTrafficDirection.uplink;
    // The tablet's ACK going back down is the cyan the unit's LED shows when
    // it arrives: worth a packet for any unit (walk test: blue up, cyan down).
    final ackDown = tick.ack && tick.direction == SafrTrafficDirection.downlink;
    if (tick.severity < 1 && !leafRoutine && !ackDown) return;

    // Path from the device up to the central, following parent links. The
    // first hop is the parent the frame itself named when it did (a leaf
    // that just re-bound: the registry still holds the old parent until this
    // very frame is stored); the rest follows the registry.
    final path = <String>[tick.mac];
    final firstParent =
        tick.parentMac != null && nodes.containsKey(tick.parentMac)
            ? tick.parentMac
            : origin.parentMac;
    var cursor = firstParent != null ? nodes[firstParent] : null;
    if (cursor != null) path.add(cursor.mac);
    var guard = 0;
    while (cursor?.parentMac != null &&
        nodes.containsKey(cursor!.parentMac) &&
        guard++ < 8) {
      path.add(cursor.parentMac!);
      cursor = nodes[cursor.parentMac];
    }
    path.add(_centralKey);

    final color = switch (tick.severity) {
      3 => AppColors.error,
      1 => AppColors.trouble,
      _ => ackDown ? AppColors.ledCyan : AppColors.ledBlue,
    };
    // One wake = one packet: a unit that sends several frames in a burst
    // (name, topology, heartbeat after a bind; the outbox on reconnection)
    // shows one packet, which takes on the event colour if an event is in
    // the burst — the unit's LED shows one pulse too.
    final now = DateTime.now();
    final uplink = tick.direction == SafrTrafficDirection.uplink;
    for (final d in _dots) {
      if (d.origin == tick.mac &&
          d.uplink == uplink &&
          now.difference(d.startedAt).inMilliseconds < 1200) {
        if (tick.severity > d.severity) {
          d.color = color;
          d.severity = tick.severity;
        }
        // The burst's first frame may not name a parent (NAME_ANNOUNCE) while
        // a later one does (TOPOLOGY after a re-bind): re-route the packet
        // while it is still on its first hop, so it never rides the old line.
        final newPath = uplink ? path : path.reversed.toList();
        final onFirstHop = d.progress * (d.path.length - 1) < 1.0;
        if (tick.parentMac != null &&
            onFirstHop &&
            !_samePath(d.path, newPath)) {
          d.path = newPath;
          d.duration = Duration(
              milliseconds: (leafRoutine || origin.isLeaf ? 700 : 550) *
                  (newPath.length - 1));
        }
        return;
      }
    }

    _dots.add(_TrafficDot(
      origin: tick.mac,
      uplink: tick.direction == SafrTrafficDirection.uplink,
      severity: tick.severity,
      path: tick.direction == SafrTrafficDirection.uplink
          ? path
          : path.reversed.toList(),
      // Colours = the units' LED language (reference §3.7 row 7.7, §3.6.2):
      // red alarm · orange trouble · cyan = the tablet's ACK · blue = a
      // frame sent (heartbeat, test, name, command). No amber: an ALERT such
      // as the walk test is "blue then cyan" on the unit, so here too.
      color: color,
      startedAt: DateTime.now(),
      // A leaf's packet crosses each hop a little slower: one hop more than a
      // node (leaf → parent) and the eye should be able to follow it.
      duration:
          Duration(milliseconds: (leafRoutine ? 700 : 550) * (path.length - 1)),
    ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  /// A firmware push: the board confirmed chunks. One blue packet goes from
  /// the tablet to the board (a frame sent) and one cyan packet comes back
  /// behind it (the board's ACK) — the LED language's colours, a few
  /// packets for many chunks. Only this link is ever drawn: no node and no
  /// leaf receives anything in a push.
  void _onOtaChunks(int chunks) {
    final now = DateTime.now();
    if (!_otaThrottle.take(chunks, now)) return;
    _dots
      ..add(_TrafficDot(
        origin: _otaOrigin,
        uplink: false,
        severity: 0,
        path: const [_tabletKey, _centralKey],
        color: AppColors.ledBlue,
        startedAt: now,
        duration: _otaHop,
        lane: -4,
      ))
      ..add(_TrafficDot(
        origin: _otaOrigin,
        uplink: true,
        severity: 0,
        path: const [_centralKey, _tabletKey],
        color: AppColors.ledCyan,
        startedAt: now.add(_otaHop),
        duration: _otaHop,
        lane: -4,
      ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  /// A rollout: a unit started or stopped downloading. While it downloads,
  /// packets leave the board (the CENTRAL chip) and travel the tree to it.
  void _onDownloading(String? mac) {
    if (mac == _downloading) return;
    _downloading = mac;
    _rolloutTimer?.cancel();
    _rolloutTimer = null;
    if (mac == null) {
      _dots.removeWhere((d) => d.origin == _rolloutOrigin);
      return;
    }
    _sendRolloutPacket();
    _rolloutTimer =
        Timer.periodic(_rolloutPacketEvery, (_) => _sendRolloutPacket());
  }

  /// One blue packet (a frame sent, in the LED language's colours) from
  /// the central down the unit's parents to the unit.
  void _sendRolloutPacket() {
    final mac = _downloading;
    if (mac == null || !mounted) return;
    final path = otaDownloadPath(ref.read(topologyProvider), mac, _centralKey);
    if (path == null) return;
    _dots.add(_TrafficDot(
      origin: _rolloutOrigin,
      uplink: false,
      severity: 0,
      path: path,
      color: AppColors.ledBlue,
      startedAt: DateTime.now(),
      duration: Duration(milliseconds: 550 * (path.length - 1)),
      lane: -4,
    ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  @override
  Widget build(BuildContext context) {
    final nodes = widget.nodes;
    final board = widget.board;
    final election = widget.election;
    final boardMac = board?.mac;
    // A rollout: what is drawn on every unit of it.
    final OtaRolloutOverlay rollout;
    if (!widget.showOta) {
      rollout = OtaRolloutOverlay.none;
    } else {
      rollout = widget.overlay ?? ref.watch(otaRolloutOverlayProvider);
    }
    final held = widget.showOta
        ? ref.watch(otaHeldOnBoardProvider)
        : const <SafrProductFamily, String>{};
    // A firmware push: what the board is doing with it, and what waits on
    // the board for the units (rebuilt once per percent, not per chunk).
    final activity = widget.showOta
        ? ref.watch(otaPushViewProvider.select(otaBoardActivity))
        : null;
    if (activity == null) _dots.removeWhere((d) => d.origin == _otaOrigin);

    // A push is drawn on the central: it is on the map while one runs, mesh
    // or no mesh.
    if (nodes.isEmpty && activity == null) return const _EmptyMesh();
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      _viewSize = size;
      final layout = _MeshLayout.compute(nodes, size);
      _canvasSize = layout.canvas;
      final key = (size, layout.canvas);
      if (_fittedFor != key) {
        final viewportChanged = _fittedFor == null || _fittedFor!.$1 != size;
        _fittedFor = key;
        _refitTimer?.cancel();
        if (viewportChanged) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView());
        } else {
          _refitTimer = Timer(_refitSettle, () {
            if (mounted) _fitToView();
          });
        }
      }
      return Stack(
        children: [
          // Pinch = the SAME zoom the buttons do (pivot on the
          // tree's centre line and the fingers' row), fingers'
          // travel = pan. Our own gesture math, so the tree
          // never slides sideways on its own. The canvas grows
          // past the viewport when the mesh is crowded — pan to
          // reach the rest.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 0,
                  minHeight: 0,
                  maxWidth: double.infinity,
                  maxHeight: double.infinity,
                  child: ValueListenableBuilder<Matrix4>(
                    valueListenable: _transform,
                    builder: (_, m, child) => Transform(
                      transform: m,
                      alignment: Alignment.topLeft,
                      child: child,
                    ),
                    child: SizedBox(
                      width: layout.canvas.width,
                      height: layout.canvas.height,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _MeshGraphPainter(
                                nodes: nodes,
                                layout: layout,
                                dots: _dots,
                                repaint: _ticker,
                                isDark: context.isDark,
                                boardMac: boardMac,
                                rootMac: election.rootMac,
                                candidates: election.electing
                                    ? election.candidates
                                    : const {},
                                otaLink: activity != null,
                                faded: _faded(nodes),
                              ),
                            ),
                          ),
                          if (activity != null)
                            Positioned(
                              left: layout.positions[_tabletKey]!.dx -
                                  OtaTabletChip.width / 2,
                              top: layout.positions[_tabletKey]!.dy -
                                  OtaTabletChip.circle / 2,
                              child: const OtaTabletChip(),
                            ),
                          _CentralChip(
                            position: layout.positions[_centralKey]!,
                            board: board,
                            activity: activity,
                            selected: widget.boardSelected,
                            onTap: widget.onCentralTap,
                          ),
                          for (final node in nodes)
                            if (layout.positions.containsKey(node.mac))
                              _NodeChip(
                                node: node,
                                position: layout.positions[node.mac]!,
                                isRoot:
                                    node.online && node.mac == election.rootMac,
                                isCandidate: election.electing &&
                                    election.candidates.contains(node.mac),
                                activity: rollout[node.mac],
                                pending: pendingFirmwareFor(node, held),
                                selected: widget.selected.contains(node.mac),
                                faded: widget.focus != null &&
                                    !widget.focus!.contains(node.mac),
                                selectionTarget: widget.selectionTarget,
                                onTap: (anchor) =>
                                    widget.onNodeTap(node, anchor),
                              ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Lane labels live in screen space: pinned to the
          // left edge whatever the pan/zoom, following only
          // the rows' vertical position.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _LaneLabelsPainter(
                  layout: layout,
                  transform: _transform,
                  isDark: context.isDark,
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: _ZoomControls(
              onZoomIn: () => _zoomBy(1.3),
              onZoomOut: () => _zoomBy(1 / 1.3),
              onReset: _fitToView,
            ),
          ),
        ],
      );
    });
  }
}

extension on _MeshMapState {
  /// MACs drawn faded: outside the update that runs.
  Set<String> _faded(List<TopologyNode> nodes) {
    final focus = widget.focus;
    if (focus == null) return const {};
    return {
      for (final n in nodes)
        if (!focus.contains(n.mac)) n.mac,
    };
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tooltip, VoidCallback onTap) {
      return Tooltip(
        message: tooltip,
        child: Material(
          color: context.surfaceColor.withValues(alpha: 0.92),
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(icon, size: 19, color: context.textPrimary),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Icons.add_rounded, 'Aproximar', onZoomIn),
        const SizedBox(height: 8),
        button(Icons.remove_rounded, 'Afastar', onZoomOut),
        const SizedBox(height: 8),
        button(Icons.crop_free_rounded, 'Ajustar à tela', onReset),
      ],
    );
  }
}

// ── Traveling dot model ──────────────────────────────────────────────────────

bool _samePath(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _TrafficDot {
  _TrafficDot({
    required this.origin,
    required this.uplink,
    required this.severity,
    required this.path,
    required this.color,
    required this.startedAt,
    required this.duration,
    this.lane = 0,
  });

  final String origin;
  final bool uplink;
  int severity;
  List<String> path;
  Color color;
  final DateTime startedAt;
  Duration duration;

  /// Pixels to the side of the line, to the left of the way it travels:
  /// packets that cross on one link each keep to their side.
  final double lane;

  double get progress {
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    return elapsed / duration.inMilliseconds;
  }
}

// ── Painter: background grid, curved glowing links, pulses, dot trails ──────

class _MeshGraphPainter extends CustomPainter {
  _MeshGraphPainter({
    required this.nodes,
    required this.layout,
    required this.dots,
    required Listenable repaint,
    required this.isDark,
    this.boardMac,
    this.rootMac,
    this.candidates = const {},
    this.otaLink = false,
    this.faded = const {},
  }) : super(repaint: repaint);

  final List<TopologyNode> nodes;
  final _MeshLayout layout;
  final List<_TrafficDot> dots;
  final bool isDark;
  final String? boardMac;

  /// A firmware push runs: the USB cable between the tablet and the board
  /// is drawn, in the app's accent colour (it is a cable, not a radio link:
  /// no signal colour, no dBm).
  final bool otaLink;

  /// MACs whose link is drawn faded (outside the update that runs).
  final Set<String> faded;

  /// The settled root (pulse ring) and, while electing, the contenders
  /// (faster, fainter pulse; dashed link to the central).
  final String? rootMac;
  final Set<String> candidates;

  @override
  void paint(Canvas canvas, Size size) {
    final byMac = {for (final n in nodes) n.mac: n};
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    _paintGrid(canvas, size);

    // Links: curved, two-pass (glow + core).
    for (final n in nodes) {
      final from = layout.positions[n.mac];
      if (from == null) continue;
      final parentKey = (n.parentMac != null && byMac.containsKey(n.parentMac))
          ? n.parentMac!
          : (n.layer <= 1 || n.parentMac == boardMac ? _centralKey : null);
      final to = parentKey != null ? layout.positions[parentKey] : null;
      if (to == null) continue;

      final parentOnline =
          parentKey == _centralKey || (byMac[parentKey]?.online ?? false);
      final healthy = n.online && parentOnline;
      final candidate = candidates.contains(n.mac);
      // Link colour = signal quality (system reference §3.6.2). A sleeping
      // leaf's link keeps its last dBm but wears the sleep colour: the reading
      // is from the last wake and the next one may come through any parent.
      final color = candidate
          ? AppColors.warning
          : healthy
              ? (n.sleeping ? sleepingLinkColor(isDark) : signalColor(n.rssi))
              : AppColors.error.withValues(alpha: 0.8);

      final path = _linkPath(from, to);
      // Outside the update that runs: the link fades with its unit.
      final fade = faded.contains(n.mac);
      if (fade) {
        canvas.saveLayer(
            null, Paint()..color = Colors.white.withValues(alpha: 0.32));
      }
      if (candidate) {
        // Contending for root: attached, but not yet the bridge.
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = color.withValues(alpha: 0.7),
        );
      } else if (healthy) {
        // Glow pass
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..color = color.withValues(alpha: 0.10)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = color.withValues(alpha: 0.55),
        );
      } else {
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color =
                color.withValues(alpha: n.stale ? 0.55 * _staleOpacity : 0.55),
        );
      }

      // Link quality: the child's RSSI to this parent, printed on the line in
      // the link's colour (not for a stale device — that reading is long out
      // of date). A sleeping leaf keeps its last value, in the sleep colour.
      if (n.rssi != null && !n.stale) {
        _linkLabel(
            canvas, path, '${n.rssi} dBm', healthy ? color : AppColors.error);
      }
      if (fade) canvas.restore();
    }

    if (otaLink) {
      final from = layout.positions[_tabletKey];
      final to = layout.positions[_centralKey];
      if (from != null && to != null) {
        canvas.drawPath(
          _linkPath(from, to),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = AppColors.secondary.withValues(alpha: 0.6),
        );
      }
    }

    // Pulse rings on the central and the settled root; while electing the
    // candidates get a quicker, fainter pulse instead of the root's.
    final phase = (nowMs % 2200) / 2200.0;
    _pulse(
        canvas, layout.positions[_centralKey], AppColors.secondary, phase, 30);
    final fast = (nowMs % 1100) / 1100.0;
    for (final n in nodes) {
      if (!n.online || n.layer == 0) continue;
      if (n.mac == rootMac) {
        _pulse(canvas, layout.positions[n.mac], AppColors.warning,
            (phase + 0.5) % 1.0, 26);
      } else if (candidates.contains(n.mac)) {
        _pulse(canvas, layout.positions[n.mac],
            AppColors.warning.withValues(alpha: 0.6), fast, 22);
      }
    }

    // Traveling packets: a small data packet (rounded body, two data stripes)
    // oriented along the line, with a soft glow and two fainter ghosts behind.
    dots.removeWhere((d) => d.progress >= 1.0);
    for (final dot in dots) {
      for (var k = 2; k >= 0; k--) {
        final t = dot.progress - k * 0.03;
        if (t < 0) continue;
        final tan = _tangentAlong(dot.path, t);
        if (tan == null) continue;
        // `lane` to the left of the heading (the canvas' y grows downward).
        final at = dot.lane == 0
            ? tan.position
            : tan.position + Offset(tan.vector.dy, -tan.vector.dx) * dot.lane;
        _drawPacket(canvas, at, tan.angle, dot.color,
            k == 0 ? 1.0 : 0.85 - k * 0.15, k == 0 ? 1.0 : 0.30 - k * 0.10);
      }
    }
  }

  /// Paints the RSSI value on a pill at the middle of a link.
  void _linkLabel(Canvas canvas, Path path, String text, Color color) {
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final m = metrics.first;
    final pos = m.getTangentForOffset(m.length * 0.5)?.position;
    if (pos == null) return;

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color.withValues(alpha: 0.95),
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final rect = Rect.fromCenter(
      center: pos,
      width: tp.width + 10,
      height: tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()
        ..color = (isDark ? const Color(0xFF0B0F1A) : Colors.white)
            .withValues(alpha: 0.85),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = color.withValues(alpha: 0.35),
    );
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var covered = 0.0;
      while (covered < metric.length) {
        final end = (covered + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(covered, end), paint);
        covered = end + gap;
      }
    }
  }

  Path _linkPath(Offset from, Offset to) {
    // Gentle vertical S-curve: fans siblings out from their shared parent.
    final mid = Offset.lerp(from, to, 0.5)!;
    final bend = (to.dx - from.dx).abs() * 0.001 + 0.22;
    final c1 = Offset(from.dx, from.dy - (from.dy - mid.dy) * bend * 2);
    final c2 = Offset(to.dx, to.dy + (mid.dy - to.dy) * bend * 2);
    return Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
  }

  /// One packet: 12 × 7.5 body with a lighter header band and two data
  /// stripes, rotated to travel along the link. `scale` / `alpha` draw the
  /// motion ghosts.
  void _drawPacket(Canvas canvas, Offset pos, double angle, Color color,
      double scale, double alpha) {
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.rotate(angle);
    canvas.scale(scale);
    if (alpha >= 1.0) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 20, height: 13),
        Paint()
          ..color = color.withValues(alpha: 0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 12, height: 7.5),
        const Radius.circular(1.8));
    canvas.drawRRect(body, Paint()..color = color.withValues(alpha: alpha));
    // Header band (leading edge) + two data stripes, in the body's own light.
    final ink = Paint()
      ..color = Colors.white.withValues(alpha: 0.75 * alpha)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(3.6, -2.4), const Offset(3.6, 2.4),
        ink..strokeWidth = 1.4);
    canvas.drawLine(const Offset(-4.2, -1.2), const Offset(1.4, -1.2),
        ink..strokeWidth = 0.9);
    canvas.drawLine(const Offset(-4.2, 1.2), const Offset(0.2, 1.2), ink);
    canvas.restore();
  }

  /// Position and heading along the multi-hop path (same curve as the link).
  Tangent? _tangentAlong(List<String> keys, double progress) {
    final points = [
      for (final key in keys)
        if (layout.positions[key] != null) layout.positions[key]!,
    ];
    if (points.length < 2) return null;
    final segments = points.length - 1;
    final t = (progress * segments).clamp(0.0, segments.toDouble());
    final seg = t.floor().clamp(0, segments - 1);
    final local = t - seg;
    final metrics =
        _linkPath(points[seg], points[seg + 1]).computeMetrics().toList();
    if (metrics.isEmpty) return null;
    final m = metrics.first;
    final tan = m.getTangentForOffset(m.length * local);
    if (tan == null) return null;
    // Tangent.angle is measured counter-clockwise; the canvas rotates clockwise.
    return Tangent.fromAngle(tan.position, -tan.angle);
  }

  void _pulse(
    Canvas canvas,
    Offset? center,
    Color color,
    double phase,
    double baseRadius,
  ) {
    if (center == null) return;
    canvas.drawCircle(
      center,
      baseRadius + phase * 16,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: (1 - phase) * 0.30),
    );
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.035);
    const gap = 26.0;
    for (var x = gap; x < size.width; x += gap) {
      for (var y = gap; y < size.height; y += gap) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_MeshGraphPainter old) => true;
}

// ── Arena-free tap ───────────────────────────────────────────────────────────

/// Tap detection that stays OUT of the gesture arena. A chip must never
/// compete with the viewer's pinch/pan: with a TapGestureRecognizer on the
/// chip, a pinch that began on a chip (where fingers usually land) lost part
/// of the hand's movement and the map slid away from the fingers. A raw
/// Listener sees every pointer event without claiming any of them, so the
/// viewer keeps the whole gesture; the tap fires only for a short, still,
/// single-finger touch.
class _ArenaFreeTap extends StatefulWidget {
  const _ArenaFreeTap({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ArenaFreeTap> createState() => _ArenaFreeTapState();
}

class _ArenaFreeTapState extends State<_ArenaFreeTap> {
  Offset? _down;
  int _pointers = 0;
  bool _cancelled = false;

  void _onDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) {
      _down = e.position;
      _cancelled = false;
    } else {
      _cancelled = true; // second finger: this is a pinch, not a tap
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (_down != null && (e.position - _down!).distance > kTouchSlop) {
      _cancelled = true;
    }
  }

  void _onUp(PointerUpEvent e) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers > 0) return;
    if (!_cancelled && _down != null) widget.onTap();
    _down = null;
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers = math.max(0, _pointers - 1);
    _cancelled = true;
    if (_pointers == 0) _down = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }
}

// ── Lane labels (screen-space gutter) ────────────────────────────────────────

/// CENTRAL / ROOT / CAMADA n, rotated along the left edge of the viewport.
/// Repaints with the transform so each label tracks its row's screen y while
/// its x and size never change — the gutter is fixed, the map moves.
class _LaneLabelsPainter extends CustomPainter {
  _LaneLabelsPainter({
    required this.layout,
    required this.transform,
    required this.isDark,
  }) : super(repaint: transform);

  final _MeshLayout layout;
  final TransformationController transform;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final m = transform.value;
    final scale = _scaleOf(m);
    final ty = m.getTranslation().y;

    void label(String text, double lane) {
      final y = ty + lane * scale;
      if (y < 0 || y > size.height) return; // row scrolled off-screen
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color:
                (isDark ? Colors.white : Colors.black).withValues(alpha: 0.22),
            fontSize: 8,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(10, y + tp.width / 2);
      canvas.rotate(-math.pi / 2);
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    }

    label('CENTRAL', layout.centralLane);
    final layers = layout.laneCenters.keys.toList()..sort();
    for (final ly in layers) {
      label(ly == 1 ? 'ROOT' : 'CAMADA ${ly - 1}', layout.laneCenters[ly]!);
    }
  }

  @override
  bool shouldRepaint(_LaneLabelsPainter old) =>
      old.layout != layout || old.isDark != isDark;
}

// ── Layout ───────────────────────────────────────────────────────────────────

/// Where every node sits on the canvas, plus the lanes the painter labels.
///
/// The tree always grows top → bottom: central row on top, one row per
/// layer, siblings spread across the width, rotated labels in a left gutter.
/// The canvas is at least the viewport and grows when a row or a lane would
/// otherwise overlap chips; the screen then zooms out to fit it (landscape)
/// rather than changing the picture.
class _MeshLayout {
  const _MeshLayout({
    required this.positions,
    required this.centralLane,
    required this.laneCenters,
    required this.canvas,
  });

  final Map<String, Offset> positions;

  /// y of the central row.
  final double centralLane;

  /// y of each mesh layer's row.
  final Map<int, double> laneCenters;

  /// Canvas size the chips and painter are laid out in (≥ viewport).
  final Size canvas;

  // Chip footprint: node chip 104 × ~62, central chip 120 × ~95.
  // The same margin on both sides keeps the tree centred; the left one
  // also hosts the rotated lane labels.
  static const _gutter = 36.0;
  static const _edge = 12.0;
  static const _minAcross = 116.0; // node pitch along a row
  static const _minLane = 104.0; // row pitch
  static const _tabletAside = 112.0; // tablet ↔ central, centre to centre

  static _MeshLayout compute(List<TopologyNode> nodes, Size viewport) {
    final layers = <int, List<TopologyNode>>{};
    for (final n in nodes) {
      layers.putIfAbsent(n.layer, () => []).add(n);
    }
    final layerKeys = layers.keys.toList()..sort();
    final laneCount = layerKeys.length + 1; // + central row
    var widest = 1;
    for (final l in layers.values) {
      widest = math.max(widest, l.length);
    }

    // Siblings sit at (j+1)/(n+1) of the usable width, so n chips need
    // n+1 pitches for the pitch itself to stay ≥ _minAcross.
    final width =
        math.max(viewport.width, 2 * _gutter + (widest + 1) * _minAcross);
    final height = math.max(viewport.height, 2 * _edge + laneCount * _minLane);
    final rowH = (height - 2 * _edge) / laneCount;
    final usableW = width - 2 * _gutter;
    double laneY(int i) => _edge + rowH * (i + 0.52);

    final positions = <String, Offset>{
      _centralKey: Offset(_gutter + usableW / 2, laneY(0)),
      // Beside the central, on its row, away from the lane labels; drawn
      // only while a push runs.
      _tabletKey: Offset(_gutter + usableW / 2 + _tabletAside, laneY(0)),
    };
    final laneCenters = <int, double>{};
    for (var i = 0; i < layerKeys.length; i++) {
      final row = layers[layerKeys[i]]!;
      laneCenters[layerKeys[i]] = laneY(i + 1);
      for (var j = 0; j < row.length; j++) {
        positions[row[j].mac] = Offset(
          _gutter + usableW * (j + 1) / (row.length + 1),
          laneY(i + 1),
        );
      }
    }
    return _MeshLayout(
      positions: positions,
      centralLane: laneY(0),
      laneCenters: laneCenters,
      canvas: Size(width, height),
    );
  }
}

// ── Chips ────────────────────────────────────────────────────────────────────

class _CentralChip extends StatelessWidget {
  const _CentralChip({
    required this.position,
    this.board,
    this.activity,
    this.selected = false,
    this.onTap,
  });
  final Offset position;
  final TopologyNode? board;

  /// Chosen for an update: ring and check around the disc.
  final bool selected;
  final VoidCallback? onTap;

  /// A firmware push runs: what the board is doing with it. The avatar
  /// then shows the board (the tablet is drawn beside it), a progress ring
  /// goes around it and the caption says the phase. The LED lens on top is
  /// untouched: it is the board's LED, the ring is not.
  final OtaBoardActivity? activity;

  static const _width = 120.0;
  static const _circle = 54.0;

  Widget _disc() {
    return Container(
      width: _CentralChip._circle,
      height: _CentralChip._circle,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, Color(0xFF2E6DA4)],
        ),
        border: Border.all(
          color: AppColors.secondary.withValues(alpha: 0.7),
          width: 1.6,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.secondary.withValues(alpha: 0.30),
            blurRadius: 16,
          ),
        ],
      ),
      child: Icon(
        activity == null
            ? Icons.tablet_mac_rounded
            : Icons.developer_board_rounded,
        color: Colors.white,
        size: 24,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    final chip = SizedBox(
      width: _CentralChip._width,
      child: Column(
        children: [
          // The board's LED (magenta flash, a blue pulse per relayed
          // frame) as a small lens at the top of the CENTRAL circle.
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (selected) const _SelectionRing(diameter: _circle),
              _disc(),
              if (selected) const _SelectionCheck(),
              if (activity != null)
                Positioned(
                  left: (_CentralChip._circle -
                          OtaProgressRing.sizeFor(_CentralChip._circle)) /
                      2,
                  top: (_CentralChip._circle -
                          OtaProgressRing.sizeFor(_CentralChip._circle)) /
                      2,
                  child: OtaProgressRing(
                    activity: activity!,
                    diameter: _CentralChip._circle,
                  ),
                ),
              if (board != null)
                Positioned(
                  top: -3,
                  left: (_CentralChip._circle - 11) / 2,
                  child: DeviceLedDot(node: board!, size: 11),
                ),
            ],
          ),
          const SizedBox(height: 5),
          if (activity != null)
            OtaBoardCaption(activity: activity!)
          else
            // The firmware the board runs sits on the caption's line
            // (nothing when it never said): the chip keeps its height.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'CENTRAL',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                  if (board?.fwVersion?.isNotEmpty == true) ...[
                    const SizedBox(width: 5),
                    FirmwareTag(version: board!.fwVersion),
                  ],
                ],
              ),
            ),
          if (board != null) ...[
            const SizedBox(height: 2),
            Text(
              board!.mac,
              style: TextStyle(
                color: context.textSecondary.withValues(alpha: 0.8),
                fontSize: 8,
                fontFamily: 'monospace',
              ),
            ),
            if (board!.rssi != null)
              Text(
                '${board!.rssi} dBm',
                style: TextStyle(
                  color: context.textSecondary.withValues(alpha: 0.7),
                  fontSize: 8,
                ),
              ),
          ],
        ],
      ),
    );
    return Positioned(
      left: position.dx - _CentralChip._width / 2,
      top: position.dy - _CentralChip._circle / 2,
      child: tap == null
          ? chip
          : Semantics(
              button: true,
              label: 'Central (placa)',
              child: _ArenaFreeTap(onTap: tap, child: chip),
            ),
    );
  }
}

/// The ring around a unit chosen for an update.
class _SelectionRing extends StatelessWidget {
  const _SelectionRing({required this.diameter});
  final double diameter;

  @override
  Widget build(BuildContext context) => Positioned(
        left: -6,
        top: -6,
        child: Container(
          key: const ValueKey('update-selected'),
          width: diameter + 12,
          height: diameter + 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.secondary, width: 2),
            boxShadow: [
              BoxShadow(
                color: AppColors.secondary.withValues(alpha: 0.45),
                blurRadius: 14,
              ),
            ],
          ),
        ),
      );
}

/// The check on a unit chosen for an update (top left: the LED is on top,
/// ROOT / ALARME at the bottom).
class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck();

  @override
  Widget build(BuildContext context) => Positioned(
        left: -8,
        top: -6,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: AppColors.secondary,
            shape: BoxShape.circle,
            border: Border.all(color: context.bgColor, width: 1.8),
          ),
          child: Icon(Icons.check_rounded, size: 12, color: context.bgColor),
        ),
      );
}

class _NodeChip extends StatelessWidget {
  const _NodeChip({
    required this.node,
    required this.position,
    required this.isRoot,
    required this.isCandidate,
    required this.onTap,
    this.pending,
    this.activity,
    this.selected = false,
    this.faded = false,
    this.selectionTarget,
  });

  final TopologyNode node;
  final Offset position;

  /// Chosen for an update: ring and check, and "v0.1.0 → [selectionTarget]"
  /// under the name.
  final bool selected;
  final String? selectionTarget;

  /// Outside the update that runs: drawn faded.
  final bool faded;

  /// A rollout has this unit in it: a progress ring goes around the avatar
  /// while it is being updated and the line under its name says where it
  /// is. The LED lens on top is untouched: it is the unit's LED, the ring
  /// is not.
  final OtaUnitActivity? activity;

  /// The version of an image of this unit's family that is stored on the
  /// board and was not delivered; null = none.
  final String? pending;

  /// Decided by root_election_provider, not by the unit's own claim: the
  /// ROOT badge goes to the settled root only; while the mesh is still
  /// choosing, the contenders wear CANDIDATO instead.
  final bool isRoot;
  final bool isCandidate;

  /// Called with the chip's screen rect: the device menu drops from it.
  final ValueChanged<Rect> onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - 52,
      top: position.dy - 26,
      child: Opacity(
        opacity: node.stale || faded ? deviceStaleOpacity : 1.0,
        child: Builder(
          builder: (chipContext) => _ArenaFreeTap(
            onTap: () => onTap(deviceAnchorOf(chipContext)),
            child: SizedBox(
              width: 104,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (selected) const _SelectionRing(diameter: 46),
                      DeviceAvatar(
                        node: node,
                        isRoot: isRoot,
                        isCandidate: isCandidate,
                      ),
                      if (selected) const _SelectionCheck(),
                      if (activity?.updating == true)
                        Positioned(
                          left: (46 - OtaProgressRing.sizeFor(46)) / 2,
                          top: (46 - OtaProgressRing.sizeFor(46)) / 2,
                          child: OtaUnitRing(activity: activity!, diameter: 46),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Identification: the device's name when set, otherwise the
                  // full MAC address — never a truncated fragment.
                  Text(
                    node.name?.isNotEmpty == true ? node.name! : node.mac,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: node.name?.isNotEmpty == true
                          ? context.textPrimary
                          : context.textSecondary,
                      fontSize: node.name?.isNotEmpty == true ? 9.5 : 8,
                      fontWeight: FontWeight.w600,
                      fontFamily:
                          node.name?.isNotEmpty == true ? null : 'monospace',
                      letterSpacing: node.name?.isNotEmpty == true ? 0 : -0.2,
                    ),
                  ),
                  // The firmware it runs, and whether another waits on the
                  // board; nothing when the unit never said its version. In
                  // a rollout: where the unit is in it.
                  if (activity != null)
                    OtaUnitTag(activity: activity!, version: node.fwVersion)
                  else if (selected && selectionTarget != null)
                    Text(
                      '${firmwareTagText(node.fwVersion?.isNotEmpty == true ? node.fwVersion! : '?')}'
                      ' → ${firmwareTagText(selectionTarget!)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.secondary,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  else
                    FirmwareTag(version: node.fwVersion, pending: pending),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyMesh extends StatelessWidget {
  const _EmptyMesh();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined,
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
            'A topologia aparecerá aqui assim que o root\ncomeçar a reportar pela serial.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
