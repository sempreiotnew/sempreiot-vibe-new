import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/signal_colors.dart';
import '../../../application/topology_provider.dart';
import 'force_graph_3d.dart';
import 'network_3d_math.dart';

/// Key of the tablet, beside the CENTRAL while a firmware push runs: the
/// image goes from it to the board over the USB cable (protocol §13.3).
const graphTabletKey = '@tablet';

/// `origin` of the packets of a firmware push (never a MAC).
const otaPacketOrigin = '@ota';

/// `origin` of the packets of a rollout (never a MAC): the image on its way
/// from the board to the unit that downloads it (protocol §13.4).
const rolloutPacketOrigin = '@rollout';

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
    this.lane = 0,
  });

  /// World units to the side of the link, to the left of the way the
  /// packet travels: packets that cross on one link keep to their side.
  final double lane;

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

/// Everything under the spheres: lane labels, the links as shaded 3D tubes
/// (a curve in world space, projected point by point — thick when near,
/// thin when far), dBm pills, pulse rings and the packets riding the same
/// curves. Colours and rules as the Rede map's `_MeshGraphPainter`.
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
    this.tablet,
  });

  /// Where the tablet is while a firmware push runs; null = no push. The
  /// USB cable to the CENTRAL is then drawn, in the app's accent colour (a
  /// cable, not a radio link: no signal colour, no dBm).
  final Vec3? tablet;

  Vec3? _posOf(String key) => key == graphTabletKey ? tablet : graph.pos[key];

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

  /// Tube radius in world units (a sphere is 23): thick enough to read as a
  /// cable, thin enough not to hide the spheres.
  static const _tubeRadius = 2.6;
  static const _samples = 26;

  final _pills = <Rect>[];

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    _pills.clear();
    _paintGrid(canvas, size);
    _paintLevels(canvas);

    // Far links first, so near tubes pass in front of far ones.
    final links = <(double, TopologyNode, String, List<Projected>)>[];
    for (final n in nodes.values) {
      final parentKey = graph.parentOf[n.mac];
      if (parentKey == null) continue;
      final curve = _curve(n.mac, parentKey);
      if (curve == null) continue;
      final depth =
          curve.map((p) => p.depth).reduce((a, b) => a + b) / curve.length;
      links.add((depth, n, parentKey, curve));
    }
    links.sort((a, b) => b.$1.compareTo(a.$1));

    for (final (depth, n, parentKey, curve) in links) {
      final parentOnline =
          parentKey == graphCentralKey || (nodes[parentKey]?.online ?? false);
      final healthy = n.online && parentOnline;
      final candidate = candidates.contains(n.mac);
      final color = candidate
          ? AppColors.warning
          : healthy
              ? (n.sleeping ? sleepingLinkColor(isDark) : signalColor(n.rssi))
              : AppColors.error;
      final fade =
          depthFade(depth) * (!healthy && n.stale ? _staleOpacity : 1.0);
      _tube(canvas, curve, color,
          alpha: (healthy ? 0.95 : 0.7) * fade, dashed: candidate || !healthy);

      // dBm pill at the middle of the tube, where it can be read.
      final a = curve.first.offset, b = curve.last.offset;
      if (n.rssi != null && !n.stale && (a - b).distance > 90 && fade > 0.78) {
        _pill(canvas, curve[curve.length ~/ 2].offset, '${n.rssi} dBm',
            healthy ? color : AppColors.error, fade);
      }
    }

    if (tablet != null) {
      final cable = _curve(graphTabletKey, graphCentralKey);
      if (cable != null) {
        _tube(canvas, cable, AppColors.secondary,
            alpha: 0.9 * depthFade(cable[cable.length ~/ 2].depth));
      }
    }

    // Pulse rings on the central and the settled root; candidates pulse
    // quicker and fainter while the mesh is electing.
    final nowMs = now.millisecondsSinceEpoch;
    final phase = (nowMs % 2200) / 2200.0;
    final fast = (nowMs % 1100) / 1100.0;
    _pulse(canvas, projected[graphCentralKey], AppColors.secondary, phase, 32);
    for (final n in nodes.values) {
      if (!n.online) continue;
      if (n.mac == rootMac) {
        _pulse(canvas, projected[n.mac], AppColors.warning, (phase + 0.5) % 1.0,
            28);
      } else if (candidates.contains(n.mac)) {
        _pulse(canvas, projected[n.mac],
            AppColors.warning.withValues(alpha: 0.6), fast, 24);
      }
    }

    for (final p in packets) {
      for (var k = 2; k >= 0; k--) {
        final t = p.progress(now) - k * 0.03;
        if (t < 0 || t >= 1) continue;
        final at = _along(p.path, t);
        if (at == null) continue;
        final s = (at.$3).clamp(0.5, 2.2);
        // `lane` to the left of the heading (the canvas' y grows downward).
        final pos = p.lane == 0
            ? at.$1
            : at.$1 +
                Offset(math.sin(at.$2), -math.cos(at.$2)) * (p.lane * at.$3);
        _drawPacket(
            canvas,
            pos,
            at.$2,
            p.color,
            (k == 0 ? 1.0 : 0.85 - k * 0.15) * s,
            k == 0 ? 1.0 : 0.30 - k * 0.10);
      }
    }
  }

  // ── 3D links ────────────────────────────────────────────────────────────

  /// The link from [from] to [to] as a curve in WORLD space — it leaves
  /// each device along the level axis (the Rede S-curve, but in 3D) — then
  /// projected sample by sample. Null if any part is behind the camera.
  List<Projected>? _curve(String from, String to) {
    final a = _posOf(from), b = _posOf(to);
    if (a == null || b == null) return null;
    final dir = graph.axis == GraphAxis.vertical
        ? const Vec3(0, 1, 0)
        : const Vec3(1, 0, 0);
    final along = (b - a).dot(dir);
    final p1 = a + dir * (along * 0.5);
    final p2 = b - dir * (along * 0.5);
    final out = <Projected>[];
    for (var i = 0; i <= _samples; i++) {
      final t = i / _samples, u = 1 - t;
      final p = a * (u * u * u) +
          p1 * (3 * u * u * t) +
          p2 * (3 * u * t * t) +
          b * (t * t * t);
      final pr = projector.project(p);
      if (pr == null) return null;
      out.add(pr);
    }
    return out;
  }

  /// A shaded tube along projected points: width follows each point's
  /// depth; dark edges, the colour, and a bright highlight toward the light
  /// (top-left), plus a soft glow. Dashed = drawn in pieces.
  void _tube(Canvas canvas, List<Projected> pts, Color color,
      {required double alpha, bool dashed = false}) {
    if (pts.length < 2) return;
    final ranges = <(int, int)>[];
    if (dashed) {
      for (var i = 0; i < pts.length - 1; i += 3) {
        ranges.add((i, math.min(i + 2, pts.length - 1)));
      }
    } else {
      ranges.add((0, pts.length - 1));
    }

    // Glow along the whole link.
    final glow = Path()..moveTo(pts.first.offset.dx, pts.first.offset.dy);
    for (final p in pts.skip(1)) {
      glow.lineTo(p.offset.dx, p.offset.dy);
    }
    final midScale = pts[pts.length ~/ 2].scale;
    canvas.drawPath(
      glow,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (_tubeRadius * 5 * midScale).clamp(2.0, 16.0)
        ..color = color.withValues(alpha: 0.10 * alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    for (final (from, to) in ranges) {
      // Body (dark edges), colour core, highlight — three strips.
      _strip(canvas, pts, from, to, 1.0, 0,
          Color.lerp(color, Colors.black, 0.55)!.withValues(alpha: alpha));
      _strip(
          canvas, pts, from, to, 0.68, -0.12, color.withValues(alpha: alpha));
      _strip(
          canvas,
          pts,
          from,
          to,
          0.24,
          -0.42,
          Color.lerp(color, Colors.white, 0.7)!
              .withValues(alpha: 0.85 * alpha));
    }
  }

  /// A filled strip of half-width `radius × k × scale` around the points,
  /// shifted by `shift` of the half-width toward the light.
  void _strip(Canvas canvas, List<Projected> pts, int from, int to, double k,
      double shift, Color color) {
    final left = <Offset>[], right = <Offset>[];
    for (var i = from; i <= to; i++) {
      final prev = pts[math.max(i - 1, 0)].offset;
      final next = pts[math.min(i + 1, pts.length - 1)].offset;
      var d = next - prev;
      if (d.distance < 1e-6) d = const Offset(1, 0);
      var n = Offset(-d.dy, d.dx) / d.distance;
      // Keep the normal pointing toward the light (up / left).
      if (n.dy > 0 || (n.dy == 0 && n.dx > 0)) n = -n;
      final w = (_tubeRadius * pts[i].scale).clamp(0.5, 7.0);
      final c = pts[i].offset + n * (w * shift);
      left.add(c + n * (w * k));
      right.add(c - n * (w * k));
    }
    final path = Path()..moveTo(left.first.dx, left.first.dy);
    for (final p in left.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    for (final p in right.reversed) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  /// Position, heading and scale at [progress] along a multi-hop path,
  /// riding the same 3D curves as the tubes.
  (Offset, double, double)? _along(List<String> keys, double progress) {
    if (keys.length < 2) return null;
    final hops = keys.length - 1;
    final t = (progress * hops).clamp(0.0, hops.toDouble());
    final hop = t.floor().clamp(0, hops - 1);
    final curve = _curve(keys[hop], keys[hop + 1]);
    if (curve == null) return null;
    final f = (t - hop) * (curve.length - 1);
    final i = f.floor().clamp(0, curve.length - 2);
    final k = f - i;
    final a = curve[i], b = curve[i + 1];
    final pos = Offset.lerp(a.offset, b.offset, k)!;
    final d = b.offset - a.offset;
    final angle = d.distance < 1e-6 ? 0.0 : math.atan2(d.dy, d.dx);
    final scale = a.scale + (b.scale - a.scale) * k;
    return (pos, angle, scale);
  }

  // ── Around ──────────────────────────────────────────────────────────────

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

  /// The Rede map's dBm pill; skipped where it would cover another.
  void _pill(Canvas canvas, Offset pos, String text, Color color, double fade) {
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
            .withValues(alpha: 0.88 * fade),
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

  void _pulse(Canvas canvas, Projected? at, Color color, double phase,
      double baseRadius) {
    if (at == null) return;
    final k = at.scale.clamp(0.2, 2.8); // same scale as the spheres
    canvas.drawCircle(
      at.offset,
      (baseRadius + phase * 16) * k,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: (1 - phase) * 0.30),
    );
  }

  /// The Rede map's data packet, scaled by depth.
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

  @override
  bool shouldRepaint(covariant Network3dPainter old) => true;
}
