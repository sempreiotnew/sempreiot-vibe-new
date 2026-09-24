import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/safr_downlink_provider.dart';
import '../../application/safr_traffic_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';

/// Rede — live map of the fire-alarm mesh. Central on top, root marked,
/// curved glowing links, and dots with trails traveling along the real path
/// of every frame: visible proof that messages cross the system.
class TopologyScreen extends ConsumerStatefulWidget {
  const TopologyScreen({super.key, this.embedded = false});

  /// True when hosted inside the Rede tab (no own Scaffold/AppBar).
  final bool embedded;

  @override
  ConsumerState<TopologyScreen> createState() => _TopologyScreenState();
}

/// Pseudo-MAC of the central in the graph (top of the tree).
const _centralKey = '@central';

/// The map's zoom factor. The map is only ever translated and uniformly
/// scaled, so the x-axis entry IS the scale. Never read the "max scale on
/// axis" helper here: it also looks at the z axis, which reads 1.0 whenever
/// the map is zoomed OUT below 1:1 — the landscape opening view — and every
/// zoom, pan clamp and label position then computed with the wrong scale.
double _scaleOf(Matrix4 m) => m.storage[0];

/// Opacity of a device (and its link) that has been silent for longer than
/// [topologyStaleAfter]: still on the map, visibly faded.
const _staleOpacity = 0.32;

class _TopologyScreenState extends ConsumerState<TopologyScreen>
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

  @override
  void initState() {
    super.initState();
    // Continuous vsync clock: the painter derives dot positions and pulse
    // phases from wall time, so one controller animates everything.
    _ticker =
        AnimationController(vsync: this, duration: const Duration(days: 1))
          ..repeat();
    _trafficSub = ref.read(safrTrafficProvider).stream.listen(_onTraffic);
  }

  @override
  void dispose() {
    _trafficSub?.cancel();
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
    // Only animate real events (alert/alarm/trouble). Routine traffic —
    // heartbeats, topology, ACKs — used to spawn a dot every time (the
    // constant blue balls); those are dropped so the walk-test dot stands out.
    if (tick.severity < 1) return;
    final nodes = {
      for (final n in ref.read(topologyProvider))
        if (n.layer > 0) n.mac: n
    };
    if (!nodes.containsKey(tick.mac)) return;

    // Path from the device up to the central, following parent links.
    final path = <String>[tick.mac];
    var cursor = nodes[tick.mac];
    var guard = 0;
    while (cursor?.parentMac != null &&
        nodes.containsKey(cursor!.parentMac) &&
        guard++ < 8) {
      path.add(cursor.parentMac!);
      cursor = nodes[cursor.parentMac];
    }
    path.add(_centralKey);

    _dots.add(_TrafficDot(
      path: tick.direction == SafrTrafficDirection.uplink
          ? path
          : path.reversed.toList(),
      color: switch (tick.severity) {
        3 => AppColors.error,
        2 => AppColors.warning,
        1 => AppColors.trouble,
        _ => tick.direction == SafrTrafficDirection.downlink
            ? AppColors.success
            : AppColors.secondary,
      },
      startedAt: DateTime.now(),
      duration: Duration(milliseconds: 550 * (path.length - 1)),
    ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  @override
  Widget build(BuildContext context) {
    // The board (layer 0) is folded into the CENTRAL chip, not drawn as its
    // own node; the mesh (layer 1+) hangs off the central directly.
    final allNodes = ref.watch(topologyProvider);
    TopologyNode? board;
    final nodes = <TopologyNode>[];
    for (final n in allNodes) {
      if (n.layer == 0) {
        board ??= n;
      } else {
        nodes.add(n);
      }
    }
    final boardMac = board?.mac;

    final body = Column(
      children: [
        _MeshStatusBar(nodes: nodes, onClear: _clearRegistry),
        Expanded(
          child: nodes.isEmpty
              ? const _EmptyMesh()
              : LayoutBuilder(builder: (context, constraints) {
                  final size =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  _viewSize = size;
                  final layout = _MeshLayout.compute(nodes, size);
                  _canvasSize = layout.canvas;
                  final key = (size, layout.canvas);
                  if (_fittedFor != key) {
                    _fittedFor = key;
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _fitToView());
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
                                          ),
                                        ),
                                      ),
                                      _CentralChip(
                                          position:
                                              layout.positions[_centralKey]!,
                                          board: board),
                                      for (final node in nodes)
                                        if (layout.positions
                                            .containsKey(node.mac))
                                          _NodeChip(
                                            node: node,
                                            position:
                                                layout.positions[node.mac]!,
                                            onTap: () => _showNodeSheet(node),
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
                }),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('Rede Mesh'),
        backgroundColor: context.bgColor,
        elevation: 0,
      ),
      body: body,
    );
  }

  /// Wipes the device registry so the map stops showing units from old
  /// sessions or installations. Live devices reappear on their next heartbeat.
  Future<void> _clearRegistry() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Limpar dispositivos'),
        content: const Text(
            'Remove todos os dispositivos do mapa da rede, inclusive os '
            'inativos. Os que estiverem ativos reaparecem no próximo '
            'heartbeat; o histórico de logs é mantido.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(appDatabaseProvider).clearMeshDevices();
    }
  }

  /// The sheet is taller than the default half-screen budget (facts + three
  /// commands + feedback), so it is scroll-controlled, capped at 90 % of the
  /// viewport and scrolls inside; on wide screens it stays a readable column.
  void _showNodeSheet(TopologyNode node) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
        ),
        child: SingleChildScrollView(
          child: _NodeDetailSheet(node: node),
        ),
      ),
    );
  }
}

// ── Status bar ───────────────────────────────────────────────────────────────

class _MeshStatusBar extends StatelessWidget {
  const _MeshStatusBar({required this.nodes, required this.onClear});
  final List<TopologyNode> nodes;

  /// "Limpar dispositivos" lives here, not floating over the canvas, so it
  /// can never collide with the zoom controls on a short landscape screen.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final online = nodes.where((n) => n.online && !n.sleeping).length;
    final sleeping = nodes.where((n) => n.sleeping).length;
    final offline = nodes.where((n) => !n.online).length;
    DateTime? lastSeen;
    for (final n in nodes) {
      if (lastSeen == null || n.lastSeenAt.isAfter(lastSeen)) {
        lastSeen = n.lastSeenAt;
      }
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          // One line always: on a narrow phone the counts scale down a
          // little instead of wrapping and doubling the strip's height.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusCount(
                      color: AppColors.success, label: 'ATIVOS', count: online),
                  const SizedBox(width: 14),
                  _StatusCount(
                      color: context.textSecondary,
                      label: 'DORMINDO',
                      count: sleeping),
                  const SizedBox(width: 14),
                  _StatusCount(
                      color: AppColors.error, label: 'OFFLINE', count: offline),
                ],
              ),
            ),
          ),
          if (lastSeen != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  relativeTime(lastSeen),
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'ÚLTIMO QUADRO',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 7.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Limpar dispositivos',
            // M3 pads the tap target to 48 px, which alone made the strip
            // two lines tall; the strip stays one compact line.
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              fixedSize: const Size(30, 30),
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              foregroundColor: AppColors.error,
            ),
            icon: const Icon(Icons.delete_sweep_rounded, size: 20),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

class _StatusCount extends StatelessWidget {
  const _StatusCount({
    required this.color,
    required this.label,
    required this.count,
  });

  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: count > 0 ? color : color.withValues(alpha: 0.3),
            shape: BoxShape.circle,
            boxShadow: count > 0
                ? [
                    BoxShadow(
                        color: color.withValues(alpha: 0.5), blurRadius: 5)
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
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

class _TrafficDot {
  const _TrafficDot({
    required this.path,
    required this.color,
    required this.startedAt,
    required this.duration,
  });

  final List<String> path;
  final Color color;
  final DateTime startedAt;
  final Duration duration;

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
  }) : super(repaint: repaint);

  final List<TopologyNode> nodes;
  final _MeshLayout layout;
  final List<_TrafficDot> dots;
  final bool isDark;
  final String? boardMac;

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
      final color = healthy
          ? AppColors.secondary
          : AppColors.error.withValues(alpha: 0.8);

      final path = _linkPath(from, to);
      if (healthy) {
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

      // Link quality: the child's RSSI to this parent, printed on the line
      // (not for a stale device — that reading is long out of date).
      if (n.rssi != null && !n.stale) {
        _linkLabel(
            canvas, path, '${n.rssi} dBm', healthy ? color : AppColors.error);
      }
    }

    // Pulse rings on the central and the root.
    final phase = (nowMs % 2200) / 2200.0;
    _pulse(
        canvas, layout.positions[_centralKey], AppColors.secondary, phase, 30);
    for (final n in nodes) {
      if (n.role == SafrNodeRole.root && n.layer > 0 && n.online) {
        _pulse(canvas, layout.positions[n.mac], AppColors.warning,
            (phase + 0.5) % 1.0, 26);
      }
    }

    // Traveling dots with trails.
    dots.removeWhere((d) => d.progress >= 1.0);
    for (final dot in dots) {
      for (var k = 3; k >= 0; k--) {
        final t = dot.progress - k * 0.035;
        if (t < 0) continue;
        final pos = _positionAlong(dot.path, t);
        if (pos == null) continue;
        if (k == 0) {
          canvas.drawCircle(
            pos,
            6.5,
            Paint()
              ..color = dot.color.withValues(alpha: 0.30)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
          );
          canvas.drawCircle(pos, 3.4, Paint()..color = dot.color);
        } else {
          canvas.drawCircle(
            pos,
            3.4 - k * 0.7,
            Paint()..color = dot.color.withValues(alpha: 0.28 - k * 0.06),
          );
        }
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

  Offset? _positionAlong(List<String> keys, double progress) {
    final points = [
      for (final key in keys)
        if (layout.positions[key] != null) layout.positions[key]!,
    ];
    if (points.length < 2) return null;
    final segments = points.length - 1;
    final t = (progress * segments).clamp(0.0, segments.toDouble());
    final seg = t.floor().clamp(0, segments - 1);
    final local = t - seg;
    // Follow the same curve the link uses.
    final metrics =
        _linkPath(points[seg], points[seg + 1]).computeMetrics().toList();
    if (metrics.isEmpty) return null;
    final m = metrics.first;
    return m.getTangentForOffset(m.length * local)?.position;
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
  const _CentralChip({required this.position, this.board});
  final Offset position;
  final TopologyNode? board;

  static const _width = 120.0;
  static const _circle = 54.0;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - _CentralChip._width / 2,
      top: position.dy - _CentralChip._circle / 2,
      child: SizedBox(
        width: _CentralChip._width,
        child: Column(
          children: [
            Container(
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
              child: const Icon(Icons.tablet_mac_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(height: 5),
            Text(
              'CENTRAL',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
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
      ),
    );
  }
}

class _NodeChip extends StatelessWidget {
  const _NodeChip({
    required this.node,
    required this.position,
    required this.onTap,
  });

  final TopologyNode node;
  final Offset position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Only an online device shows as the root; a stale/offline ex-root does
    // not keep the ROOT marker.
    final isRoot = node.role == SafrNodeRole.root && node.online;
    final statusColor = !node.online
        ? AppColors.error
        : node.sleeping
            ? context.textSecondary
            : AppColors.success;
    final icon = switch (node.role) {
      SafrNodeRole.root => Icons.power_rounded,
      SafrNodeRole.node => Icons.cell_tower_rounded,
      _ => node.sleeping ? Icons.dark_mode_rounded : Icons.sensors_rounded,
    };
    final ringColor = isRoot
        ? AppColors.warning
        : node.online
            ? AppColors.secondary.withValues(alpha: 0.6)
            : AppColors.error.withValues(alpha: 0.65);

    return Positioned(
      left: position.dx - 52,
      top: position.dy - 26,
      child: Opacity(
        opacity: node.stale ? _staleOpacity : 1.0,
        child: _ArenaFreeTap(
          onTap: onTap,
          child: SizedBox(
            width: 104,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Outer ring + inner avatar (double-ring look)
                    Container(
                      width: 46,
                      height: 46,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: ringColor, width: isRoot ? 1.8 : 1.1),
                        boxShadow: [
                          BoxShadow(
                            color: (isRoot ? AppColors.warning : ringColor)
                                .withValues(alpha: node.online ? 0.28 : 0.10),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: node.online
                              ? Color.alphaBlend(
                                  ringColor.withValues(alpha: 0.10),
                                  context.surfaceColor)
                              : context.surfaceColor,
                        ),
                        child: Icon(
                          icon,
                          size: 19,
                          color: node.online
                              ? context.textPrimary
                              : context.textSecondary.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -1,
                      top: -1,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: context.bgColor, width: 1.8),
                          boxShadow: node.online && !node.sleeping
                              ? [
                                  BoxShadow(
                                    color: statusColor.withValues(alpha: 0.6),
                                    blurRadius: 5,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                    if (node.alarmLatched)
                      Positioned(
                        right: -10,
                        bottom: -7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.error,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.error.withValues(alpha: 0.4),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: const Text(
                            'ALARME',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    if (isRoot)
                      Positioned(
                        left: -8,
                        bottom: -7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.warning,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.warning.withValues(alpha: 0.4),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: const Text(
                            'ROOT',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Node detail sheet with downlink commands ─────────────────────────────────

class _NodeDetailSheet extends ConsumerStatefulWidget {
  const _NodeDetailSheet({required this.node});
  final TopologyNode node;

  @override
  ConsumerState<_NodeDetailSheet> createState() => _NodeDetailSheetState();
}

class _NodeDetailSheetState extends ConsumerState<_NodeDetailSheet> {
  SafrCommand? _sending;
  String? _feedback;
  bool _feedbackOk = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final roleLabel = node.layer == 0
        ? 'Placa (gateway para a central)'
        : switch (node.role) {
            SafrNodeRole.root => 'Root da malha (alimentado 24h)',
            SafrNodeRole.node => 'Repetidor',
            SafrNodeRole.leaf => 'Sensor (dorme entre envios)',
            _ => 'Desconhecido',
          };
    final hasName = node.name?.isNotEmpty == true;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  node.online
                      ? Icons.check_circle_rounded
                      : Icons.error_rounded,
                  color: node.online ? AppColors.success : AppColors.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasName ? node.name! : node.mac,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          fontFamily: hasName ? null : 'monospace',
                        ),
                      ),
                      if (hasName)
                        Text(
                          node.mac,
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Dar um nome a este dispositivo',
                  icon: Icon(Icons.edit_rounded,
                      size: 18, color: context.textSecondary),
                  onPressed: () => _rename(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _fact(context, 'Papel', roleLabel),
            _fact(context, 'Camada', 'L${node.layer}'),
            if (node.parentMac != null) _fact(context, 'Pai', node.parentMac!),
            if (node.rssi != null) _fact(context, 'Sinal', '${node.rssi} dBm'),
            if (node.batteryPct != null)
              _fact(context, 'Bateria', '${node.batteryPct}%'),
            _fact(context, 'Última comunicação', relativeTime(node.lastSeenAt)),
            if (node.alarmLatched)
              _fact(
                context,
                'Alarme retido',
                node.alarmLatchedAt != null
                    ? 'desde ${relativeTime(node.alarmLatchedAt!)}'
                    : 'sim',
                valueColor: AppColors.error,
              ),
            _fact(
                context,
                'Estado',
                node.online
                    ? (node.sleeping ? 'Dormindo' : 'Online')
                    : node.stale
                        ? 'Sem comunicação há muito tempo'
                        : 'Sem comunicação'),
            const SizedBox(height: 16),
            Text(
              'COMANDOS — CENTRAL → DISPOSITIVO',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              node.online
                  ? (node.sleeping
                      ? 'Este sensor está dormindo: o root confirma o '
                          'recebimento e entrega o comando no próximo despertar.'
                      : 'Enviados pela serial ao root, que encaminha ao '
                          'dispositivo e confirma com ACK.')
                  : 'Sem comunicação — comandos indisponíveis até o '
                      'dispositivo voltar.',
              style: TextStyle(color: context.textSecondary, fontSize: 11),
            ),
            const SizedBox(height: 8),
            _cmdRow(
              SafrCommand.identify,
              'Identificar',
              'Pisca o LED do dispositivo para localizá-lo fisicamente',
              Icons.lightbulb_outline_rounded,
              args: const [10],
            ),
            _cmdRow(
              SafrCommand.silence,
              'Silenciar',
              'Desliga a sirene/relé durante um alarme ativo',
              Icons.notifications_off_outlined,
            ),
            _cmdRow(
              SafrCommand.test,
              'Testar',
              'Solicita um autoteste — o resultado aparece em Logs seriais',
              Icons.quiz_outlined,
            ),
            if (node.alarmLatched)
              // The root's ACK is what clears the latch, so this stays
              // available even while the sensor itself is unreachable.
              _cmdRow(
                SafrCommand.reset,
                'Rearmar',
                'Libera o alarme retido deste dispositivo (só após o ACK do root)',
                Icons.restart_alt_rounded,
                requiresOnline: false,
              ),
            // Inline result: never a SnackBar fighting the sheet for space.
            if (_feedback != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: (_feedbackOk ? AppColors.success : AppColors.trouble)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_feedbackOk ? AppColors.success : AppColors.trouble)
                        .withValues(alpha: 0.45),
                    width: 0.7,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _feedbackOk
                          ? Icons.done_all_rounded
                          : Icons.error_outline_rounded,
                      size: 16,
                      color:
                          _feedbackOk ? AppColors.success : AppColors.trouble,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _feedback!,
                        style: TextStyle(
                          color: _feedbackOk
                              ? AppColors.success
                              : AppColors.trouble,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: widget.node.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: dialogContext.surfaceColor,
        title: const Text('Nome do dispositivo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: InputDecoration(
            hintText: 'ex.: Sala de máquinas',
            helperText: widget.node.mac,
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final db = ref.read(appDatabaseProvider);
    await (db.update(db.meshDevices)
          ..where((t) => t.mac.equals(widget.node.mac)))
        .write(MeshDevicesCompanion(name: Value(name.trim())));
    if (mounted) Navigator.pop(this.context);
  }

  Widget _fact(BuildContext context, String label, String value,
      {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label,
                style: TextStyle(color: context.textSecondary, fontSize: 12.5)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: valueColor ?? context.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _cmdRow(
      SafrCommand cmd, String label, String description, IconData icon,
      {List<int> args = const [], bool requiresOnline = true}) {
    final busy = _sending == cmd;
    final enabled = (widget.node.online || !requiresOnline) && _sending == null;
    final color = enabled
        ? AppColors.secondary
        : context.textSecondary.withValues(alpha: 0.5);

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled
              ? AppColors.secondary.withValues(alpha: 0.35)
              : context.borderColor.withValues(alpha: 0.5),
          width: 0.7,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: !enabled ? null : () => _send(cmd, label, args),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: enabled
                              ? context.textPrimary
                              : context.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        description,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.send_rounded, size: 15, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _send(SafrCommand cmd, String label, List<int> args) async {
    setState(() {
      _sending = cmd;
      _feedback = null;
    });
    final downlink = ref.read(safrDownlinkProvider);
    // RESET goes through sendReset so the latch clears only on the root's ACK.
    final confirmed = cmd == SafrCommand.reset
        ? await downlink.sendReset(widget.node.mac)
        : await downlink.sendCommand(widget.node.mac, cmd, args: args);
    if (!mounted) return;
    setState(() {
      _sending = null;
      _feedbackOk = confirmed;
      _feedback = confirmed
          ? '$label — confirmado pelo root (ACK ✓✓)'
          : '$label — sem confirmação do root, tente novamente';
    });
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
