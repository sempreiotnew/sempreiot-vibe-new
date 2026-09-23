import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/safr_downlink_provider.dart';
import '../../application/safr_traffic_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import 'events_screen.dart' show relativeTime;

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

class _TopologyScreenState extends ConsumerState<TopologyScreen>
    with SingleTickerProviderStateMixin {
  static const _minZoom = 0.5;
  static const _maxZoom = 4.0;

  late final AnimationController _ticker;
  final _dots = <_TrafficDot>[];
  final _transform = TransformationController();
  Size _viewSize = Size.zero;
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

  /// Button zoom: scales around the viewport center, clamped to the same
  /// limits the pinch gesture obeys.
  void _zoomBy(double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(_minZoom, _maxZoom);
    final applied = target / current;
    if (applied == 1.0) return;
    final center = _viewSize.center(Offset.zero);
    _transform.value = _transform.value.clone()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(applied, applied, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  void _resetZoom() => _transform.value = Matrix4.identity();

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
        _MeshStatusBar(nodes: nodes),
        Expanded(
          child: nodes.isEmpty
              ? const _EmptyMesh()
              : LayoutBuilder(builder: (context, constraints) {
                  final size =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  _viewSize = size;
                  final layout = _computeLayout(nodes, size);
                  return Stack(
                    children: [
                      // Pinch to zoom, drag to pan (standard gestures);
                      // buttons below mirror the same transform.
                      Positioned.fill(
                        child: InteractiveViewer(
                          transformationController: _transform,
                          minScale: _minZoom,
                          maxScale: _maxZoom,
                          boundaryMargin: const EdgeInsets.all(320),
                          child: SizedBox(
                            width: size.width,
                            height: size.height,
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
                                    position: layout[_centralKey]!,
                                    board: board),
                                for (final node in nodes)
                                  if (layout.containsKey(node.mac))
                                    _NodeChip(
                                      node: node,
                                      position: layout[node.mac]!,
                                      onTap: () => _showNodeSheet(node),
                                    ),
                              ],
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
                          onReset: _resetZoom,
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: Material(
                          color: context.bgColor.withValues(alpha: 0.85),
                          shape: const CircleBorder(),
                          elevation: 2,
                          child: IconButton(
                            tooltip: 'Limpar dispositivos',
                            icon: const Icon(Icons.delete_sweep_rounded,
                                size: 20),
                            color: AppColors.error,
                            onPressed: _clearRegistry,
                          ),
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
            'Remove todos os dispositivos do mapa da rede. Os que estiverem '
            'ativos reaparecem no próximo heartbeat; o histórico de eventos é '
            'mantido.'),
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

  /// Layered tree: central on top, then layer 0 (root), 1, 2… scaled to the
  /// available area; a left gutter hosts the layer labels drawn by the
  /// painter.
  Map<String, Offset> _computeLayout(List<TopologyNode> nodes, Size size) {
    final layers = <int, List<TopologyNode>>{};
    for (final n in nodes) {
      layers.putIfAbsent(n.layer, () => []).add(n);
    }
    final layerKeys = layers.keys.toList()..sort();
    final rowCount = layerKeys.length + 1; // + central row
    final rowH = (size.height - 24) / rowCount;
    final usableW = size.width - 36; // gutter for layer labels
    final map = <String, Offset>{
      _centralKey: Offset(36 + usableW / 2, rowH * 0.52 + 12),
    };
    for (var i = 0; i < layerKeys.length; i++) {
      final row = layers[layerKeys[i]]!;
      for (var j = 0; j < row.length; j++) {
        map[row[j].mac] = Offset(
          36 + usableW * (j + 1) / (row.length + 1),
          rowH * (i + 1) + rowH * 0.52 + 12,
        );
      }
    }
    return map;
  }

  void _showNodeSheet(TopologyNode node) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => _NodeDetailSheet(node: node),
    );
  }
}

// ── Status bar ───────────────────────────────────────────────────────────────

class _MeshStatusBar extends StatelessWidget {
  const _MeshStatusBar({required this.nodes});
  final List<TopologyNode> nodes;

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
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          _StatusCount(
              color: AppColors.success, label: 'ATIVOS', count: online),
          const SizedBox(width: 14),
          _StatusCount(
              color: context.textSecondary, label: 'DORMINDO', count: sleeping),
          const SizedBox(width: 14),
          _StatusCount(
              color: AppColors.error, label: 'OFFLINE', count: offline),
          const Spacer(),
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
                ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 5)]
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
  final Map<String, Offset> layout;
  final List<_TrafficDot> dots;
  final bool isDark;
  final String? boardMac;

  @override
  void paint(Canvas canvas, Size size) {
    final byMac = {for (final n in nodes) n.mac: n};
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    _paintGrid(canvas, size);
    _paintLayerLabels(canvas, size);

    // Links: curved, two-pass (glow + core).
    for (final n in nodes) {
      final from = layout[n.mac];
      if (from == null) continue;
      final parentKey = (n.parentMac != null && byMac.containsKey(n.parentMac))
          ? n.parentMac!
          : (n.layer <= 1 || n.parentMac == boardMac ? _centralKey : null);
      final to = parentKey != null ? layout[parentKey] : null;
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
            ..color = color.withValues(alpha: 0.55),
        );
      }

      // Link quality: the child's RSSI to this parent, printed on the line.
      if (n.rssi != null) {
        _linkLabel(canvas, path, '${n.rssi} dBm',
            healthy ? color : AppColors.error);
      }
    }

    // Pulse rings on the central and the root.
    final phase = (nowMs % 2200) / 2200.0;
    _pulse(canvas, layout[_centralKey], AppColors.secondary, phase, 30);
    for (final n in nodes) {
      if (n.role == SafrNodeRole.root && n.layer > 0 && n.online) {
        _pulse(canvas, layout[n.mac], AppColors.warning,
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
        ..color =
            (isDark ? const Color(0xFF0B0F1A) : Colors.white).withValues(alpha: 0.85),
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
        if (layout[key] != null) layout[key]!,
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

  void _paintLayerLabels(Canvas canvas, Size size) {
    final layers = <int>{for (final n in nodes) n.layer}.toList()..sort();
    final rowCount = layers.length + 1;
    final rowH = (size.height - 24) / rowCount;

    void label(String text, double y) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: (isDark ? Colors.white : Colors.black)
                .withValues(alpha: 0.18),
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

    label('CENTRAL', rowH * 0.52 + 12);
    for (var i = 0; i < layers.length; i++) {
      final ly = layers[i];
      label(ly == 1 ? 'ROOT' : 'CAMADA ${ly - 1}',
          rowH * (i + 1) + rowH * 0.52 + 12);
    }
  }

  @override
  bool shouldRepaint(_MeshGraphPainter old) => true;
}

// ── Chips ────────────────────────────────────────────────────────────────────

class _CentralChip extends StatelessWidget {
  const _CentralChip({required this.position, this.board});
  final Offset position;
  final TopologyNode? board;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - 30,
      top: position.dy - 30,
      child: Column(
        children: [
          Container(
            width: 54,
            height: 54,
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
      child: GestureDetector(
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
                      border:
                          Border.all(color: ringColor, width: isRoot ? 1.8 : 1.1),
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
                        border: Border.all(color: context.bgColor, width: 1.8),
                        boxShadow: node.online && !node.sleeping
                            ? [
                                BoxShadow(
                                  color:
                                      statusColor.withValues(alpha: 0.6),
                                  blurRadius: 5,
                                ),
                              ]
                            : null,
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
            _fact(
                context,
                'Estado',
                node.online
                    ? (node.sleeping ? 'Dormindo' : 'Online')
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
              'Solicita um autoteste — o resultado chega em Eventos',
              Icons.quiz_outlined,
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
                    color:
                        (_feedbackOk ? AppColors.success : AppColors.trouble)
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

  Widget _fact(BuildContext context, String label, String value) {
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
                    color: context.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _cmdRow(SafrCommand cmd, String label, String description,
      IconData icon,
      {List<int> args = const []}) {
    final busy = _sending == cmd;
    final enabled = widget.node.online && _sending == null;
    final color =
        enabled ? AppColors.secondary : context.textSecondary.withValues(alpha: 0.5);

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
    final confirmed = await ref
        .read(safrDownlinkProvider)
        .sendCommand(widget.node.mac, cmd, args: args);
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
