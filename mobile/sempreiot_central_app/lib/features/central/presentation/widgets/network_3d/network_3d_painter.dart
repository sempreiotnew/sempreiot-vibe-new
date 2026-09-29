import 'dart:ui' show Tangent;

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/signal_colors.dart';
import '../../../application/topology_provider.dart';
import 'force_graph_3d.dart';
import 'network_3d_math.dart';

/// A frame travelling the tree (same rules as the Rede map's packets).
class Packet3d {
  Packet3d({
    required this.origin,
    required this.uplink,
    required this.path,
    required this.color,
    required this.severity,
    required this.startedAt,
    required this.duration,
  });

  final String origin;
  final bool uplink;
  final List<String> path;
  Color color;
  int severity;
  final DateTime startedAt;
  final Duration duration;

  double progress(DateTime now) =>
      now.difference(startedAt).inMicroseconds / duration.inMicroseconds;
}

/// Time per hop, as on the Rede map: a leaf's packet a little slower so the
/// eye can follow it.
const packetHopMs = (node: 550, leaf: 700);

/// Packet colours = the units' LED language, as on the Rede map.
Color packetColor(int severity, bool ackDown) => switch (severity) {
      3 => AppColors.error,
      1 => AppColors.trouble,
      _ => ackDown ? AppColors.ledCyan : AppColors.ledBlue,
    };

/// Everything under the chips: lane labels, links, pulse rings and the
/// travelling packets — drawn like the Rede map's `_MeshGraphPainter`,
/// between projected 3D points.
class Network3dPainter extends CustomPainter {
  Network3dPainter({
    required this.projector,
    required this.graph,
    required this.projected,
    required this.nodes,
    required this.packets,
    required this.isDark,
    required this.depthFade,
    this.rootMac,
    this.candidates = const {},
  });

  final Projector projector;
  final ForceGraph3d graph;
  final Map<String, Projected> projected;
  final Map<String, TopologyNode> nodes;
  final List<Packet3d> packets;
  final bool isDark;
  final double Function(double depth) depthFade;
  final String? rootMac;
  final Set<String> candidates;

  static const _staleOpacity = 0.32;

  /// dBm pills already drawn this frame: a pill that would cover one is
  /// skipped (the fan of links under a busy parent).
  final _pills = <Rect>[];

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    _paintGrid(canvas, size);
    _paintLevels(canvas);
    _pills.clear();

    for (final n in nodes.values) {
      final parentKey = graph.parentOf[n.mac];
      if (parentKey == null) continue;
      final from = projected[n.mac], to = projected[parentKey];
      if (from == null || to == null) continue;
      final parentOnline =
          parentKey == graphCentralKey || (nodes[parentKey]?.online ?? false);
      final healthy = n.online && parentOnline;
      final candidate = candidates.contains(n.mac);
      final color = candidate
          ? AppColors.warning
          : healthy
              ? (n.sleeping ? sleepingLinkColor(isDark) : signalColor(n.rssi))
              : AppColors.error.withValues(alpha: 0.8);
      final fade = depthFade((from.depth + to.depth) / 2);
      final path = _linkPath(from.offset, to.offset);
      if (candidate) {
        _drawDashedPath(
            canvas,
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.3
              ..color = color.withValues(alpha: 0.7 * fade));
      } else if (healthy) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..color = color.withValues(alpha: 0.10 * fade)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = color.withValues(alpha: 0.55 * fade),
        );
      } else {
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color = color.withValues(
                alpha: (n.stale ? 0.55 * _staleOpacity : 0.55) * fade),
        );
      }
      // dBm pill as on the 2D map, but only where it can be read: on links
      // long enough on screen and on the front half of the tree (behind,
      // the pills would pile up over each other).
      final onScreen = (from.offset - to.offset).distance;
      if (n.rssi != null && !n.stale && onScreen > 90 && fade > 0.78) {
        _linkLabel(canvas, path, '${n.rssi} dBm',
            healthy ? color : AppColors.error, fade);
      }
    }

    // Pulse rings on the central and the settled root; candidates pulse
    // quicker and fainter while the mesh is electing.
    final nowMs = now.millisecondsSinceEpoch;
    final phase = (nowMs % 2200) / 2200.0;
    final fast = (nowMs % 1100) / 1100.0;
    _pulse(canvas, projected[graphCentralKey], AppColors.secondary, phase, 30);
    for (final n in nodes.values) {
      if (!n.online) continue;
      if (n.mac == rootMac) {
        _pulse(canvas, projected[n.mac], AppColors.warning, (phase + 0.5) % 1.0,
            26);
      } else if (candidates.contains(n.mac)) {
        _pulse(canvas, projected[n.mac],
            AppColors.warning.withValues(alpha: 0.6), fast, 22);
      }
    }

    for (final p in packets) {
      for (var k = 2; k >= 0; k--) {
        final t = p.progress(now) - k * 0.03;
        if (t < 0 || t >= 1) continue;
        final tan = _tangentAlong(p.path, t);
        if (tan == null) continue;
        _drawPacket(canvas, tan.position, tan.angle, p.color,
            k == 0 ? 1.0 : 0.85 - k * 0.15, k == 0 ? 1.0 : 0.30 - k * 0.10);
      }
    }
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

  /// Lane labels as on the 2D map — CENTRAL, ROOT, CAMADA n — beside each
  /// level (left of a row; above a column in the wide view).
  void _paintLevels(Canvas canvas) {
    final ink = isDark ? Colors.white : Colors.black;
    for (var lvl = 0; lvl < graph.levels; lvl++) {
      final anchor = graph.laneAnchor(lvl);
      if (anchor == null) continue;
      final pr = projector.project(anchor);
      if (pr == null) continue;
      final layer = graph.layerOfLevel[lvl] ?? lvl;
      final text = lvl == 0
          ? 'CENTRAL'
          : layer == 1
              ? 'ROOT'
              : 'CAMADA ${layer - 1}';
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: ink.withValues(alpha: 0.30),
            fontSize: 8.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final at = graph.axis == GraphAxis.vertical
          ? pr.offset - Offset(tp.width, tp.height / 2)
          : pr.offset - Offset(tp.width / 2, tp.height);
      tp.paint(canvas, at);
    }
  }

  // ── Same drawing helpers as the Rede map ─────────────────────────────────

  Path _linkPath(Offset from, Offset to) {
    if (graph.axis == GraphAxis.wide) {
      // The Rede S-curve turned sideways: levels run left → right.
      final mid = Offset.lerp(from, to, 0.5)!;
      final bend = (to.dy - from.dy).abs() * 0.001 + 0.22;
      final c1 = Offset(from.dx - (from.dx - mid.dx) * bend * 2, from.dy);
      final c2 = Offset(to.dx + (mid.dx - to.dx) * bend * 2, to.dy);
      return Path()
        ..moveTo(from.dx, from.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
    }
    // Gentle vertical S-curve: fans siblings out from their shared parent.
    final mid = Offset.lerp(from, to, 0.5)!;
    final bend = (to.dx - from.dx).abs() * 0.001 + 0.22;
    final c1 = Offset(from.dx, from.dy - (from.dy - mid.dy) * bend * 2);
    final c2 = Offset(to.dx, to.dy + (mid.dy - to.dy) * bend * 2);
    return Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
  }

  void _linkLabel(
      Canvas canvas, Path path, String text, Color color, double fade) {
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final m = metrics.first;
    final pos = m.getTangentForOffset(m.length * 0.5)?.position;
    if (pos == null) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color.withValues(alpha: 0.95 * fade),
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
        center: pos, width: tp.width + 10, height: tp.height + 4);
    if (_pills.any((r) => r.inflate(2).overlaps(rect))) return;
    _pills.add(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()
        ..color = (isDark ? const Color(0xFF0B0F1A) : Colors.white)
            .withValues(alpha: 0.85 * fade),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = color.withValues(alpha: 0.35 * fade),
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

  void _pulse(Canvas canvas, Projected? at, Color color, double phase,
      double baseRadius) {
    if (at == null) return;
    final k = at.scale / projector.referenceScale;
    canvas.drawCircle(
      at.offset,
      (baseRadius + phase * 16) * k,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: (1 - phase) * 0.30),
    );
  }

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

  Tangent? _tangentAlong(List<String> keys, double progress) {
    final points = [
      for (final key in keys)
        if (projected[key] != null) projected[key]!.offset,
    ];
    if (points.length < 2) return null;
    final segments = points.length - 1;
    final t = (progress * segments).clamp(0.0, segments.toDouble());
    final seg = t.floor().clamp(0, segments - 1);
    final metrics =
        _linkPath(points[seg], points[seg + 1]).computeMetrics().toList();
    if (metrics.isEmpty) return null;
    final m = metrics.first;
    final tan = m.getTangentForOffset(m.length * (t - seg));
    if (tan == null) return null;
    return Tangent.fromAngle(tan.position, -tan.angle);
  }

  @override
  bool shouldRepaint(covariant Network3dPainter old) => true;
}
