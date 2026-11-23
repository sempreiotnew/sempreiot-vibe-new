import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';

/// The objects of Principal (2026-11-19): the central's four links, its
/// battery and its thermometer, drawn as small solid things instead of
/// flat icons. Stand-ins, drawn in code, for the 3D renders to come from
/// Blender: same boxes, so a render replaces a painter and nothing moves.
///
/// Still pictures: painted once and again only when what they show
/// changes (never per frame), each in its own repaint layer.
enum PanelObjectKind { wifi, usb, mesh, cloud, battery, thermometer }

class PanelObject extends StatelessWidget {
  const PanelObject({
    super.key,
    required this.kind,
    required this.accent,
    required this.width,
    this.ok = true,
    this.level = 1,
    this.semanticLabel,
  });

  final PanelObjectKind kind;

  /// The colour of what the object says: its lights, its level.
  final Color accent;

  /// The box's width; its height follows the object's own proportions.
  final double width;

  /// A link that is up (its check, its waves); false draws it without.
  final bool ok;

  /// 0..1: how full the battery is, how high the thermometer reads.
  final double level;

  final String? semanticLabel;

  /// Width : height of each object's box.
  static double aspectOf(PanelObjectKind kind) => switch (kind) {
        PanelObjectKind.battery => 84 / 120,
        PanelObjectKind.thermometer => 64 / 120,
        _ => 112 / 100,
      };

  @override
  Widget build(BuildContext context) {
    final height = width / aspectOf(kind);
    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(width, height),
          painter: _PanelObjectPainter(
            kind: kind,
            accent: accent,
            ok: ok,
            level: level.clamp(0.0, 1.0),
            dark: context.isDark,
          ),
        ),
      ),
    );
  }
}

class _PanelObjectPainter extends CustomPainter {
  _PanelObjectPainter({
    required this.kind,
    required this.accent,
    required this.ok,
    required this.level,
    required this.dark,
  });

  final PanelObjectKind kind;
  final Color accent;
  final bool ok;
  final double level;
  final bool dark;

  // The solid's faces, lit from the top left: top, front, side, details.
  Color get _top => dark ? const Color(0xFF2B3F63) : const Color(0xFFDDE5F0);
  Color get _front => dark ? const Color(0xFF1C2A44) : const Color(0xFFC3CFE0);
  Color get _side => dark ? const Color(0xFF16233A) : const Color(0xFFAAB8CE);
  Color get _detail => dark ? const Color(0xFF3A5180) : const Color(0xFF8395B3);
  Color get _shine => dark ? const Color(0xFF4C6A9C) : const Color(0xFFF4F7FB);
  Color get _metal => dark ? const Color(0xFF8B98AD) : const Color(0xFF7C8AA0);
  Color get _metalTop =>
      dark ? const Color(0xFFB8C2D1) : const Color(0xFFA9B4C6);
  Color get _floor =>
      dark ? const Color(0xFF05070D) : AppColors.black.withValues(alpha: 0.10);

  Paint _fill(Color c) => Paint()..color = c;

  Paint _line(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Path _poly(List<double> xy) {
    final p = Path()..moveTo(xy[0], xy[1]);
    for (var i = 2; i < xy.length; i += 2) {
      p.lineTo(xy[i], xy[i + 1]);
    }
    return p..close();
  }

  void _floorShadow(Canvas c, double cx, double cy, double rx, double ry) {
    c.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2),
        _fill(_floor));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final tall =
        kind == PanelObjectKind.battery || kind == PanelObjectKind.thermometer;
    final unit = switch (kind) {
      PanelObjectKind.battery => 84.0,
      PanelObjectKind.thermometer => 64.0,
      _ => 112.0,
    };
    canvas.save();
    canvas.scale(size.width / unit, size.height / (tall ? 120 : 100));
    switch (kind) {
      case PanelObjectKind.wifi:
        _wifi(canvas);
      case PanelObjectKind.usb:
        _usb(canvas);
      case PanelObjectKind.mesh:
        _mesh(canvas);
      case PanelObjectKind.cloud:
        _cloud(canvas);
      case PanelObjectKind.battery:
        _battery(canvas);
      case PanelObjectKind.thermometer:
        _thermometer(canvas);
    }
    canvas.restore();
  }

  /// A router: a low box, two antennas, its waves above when it is up.
  void _wifi(Canvas c) {
    _floorShadow(c, 56, 86, 38, 7);
    c.drawPath(
        _poly([20, 62, 56, 52, 92, 62, 92, 74, 56, 84, 20, 74]), _fill(_front));
    c.drawPath(_poly([20, 62, 56, 52, 92, 62, 56, 72]), _fill(_top));
    c.drawPath(_poly([56, 72, 56, 84, 20, 74, 20, 62]), _fill(_side));
    final antenna = _fill(_detail);
    c.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(30, 34, 4, 30), const Radius.circular(2)),
        antenna);
    c.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(78, 34, 4, 30), const Radius.circular(2)),
        antenna);
    c.drawCircle(const Offset(44, 75), 2.2, _fill(accent));
    c.drawCircle(const Offset(52, 77), 2.2, _fill(accent));
    if (ok) {
      c.drawPath(
          Path()
            ..moveTo(40, 28)
            ..arcToPoint(const Offset(72, 28),
                radius: const Radius.circular(22)),
          _line(accent, 3.5));
      c.drawPath(
          Path()
            ..moveTo(46, 36)
            ..arcToPoint(const Offset(66, 36),
                radius: const Radius.circular(13)),
          _line(accent, 3.5));
    }
    c.drawCircle(const Offset(56, 43), 3, _fill(accent));
  }

  /// The board's cable: a plug standing up, its metal end on top.
  void _usb(Canvas c) {
    _floorShadow(c, 56, 86, 34, 7);
    c.drawPath(
        Path()
          ..moveTo(62, 78)
          ..quadraticBezierTo(62, 86, 52, 90),
        _line(_top, 5));
    c.drawPath(
        _poly([38, 40, 62, 32, 76, 38, 76, 68, 52, 78, 38, 71]), _fill(_front));
    c.drawPath(_poly([38, 40, 62, 32, 76, 38, 52, 47]), _fill(_top));
    c.drawPath(_poly([52, 47, 52, 78, 38, 71, 38, 40]), _fill(_side));
    c.drawPath(_poly([46, 22, 60, 17, 68, 20.5, 68, 34.5, 54, 40, 46, 36]),
        _fill(_metal));
    c.drawPath(_poly([46, 22, 60, 17, 68, 20.5, 54, 26]), _fill(_metalTop));
    c.drawCircle(const Offset(66, 56), 3.2, _fill(accent));
  }

  /// The units' own network: a hub and three units, linked.
  void _mesh(Canvas c) {
    _floorShadow(c, 56, 86, 40, 7);
    final link = _line(_detail, 3);
    c.drawLine(const Offset(56, 30), const Offset(26, 64), link);
    c.drawLine(const Offset(56, 30), const Offset(86, 64), link);
    c.drawLine(const Offset(26, 64), const Offset(86, 64), link);
    c.drawLine(const Offset(56, 30), const Offset(56, 68), link);
    void ball(double x, double y, double r, Color body) {
      c.drawCircle(Offset(x, y), r, _fill(body));
      c.drawCircle(Offset(x - r * 0.3, y - r * 0.3), r * 0.38, _fill(_shine));
    }

    ball(26, 64, 10, _front);
    ball(86, 64, 10, _front);
    ball(56, 68, 8, _front);
    ball(56, 28, 13, _top);
    c.drawCircle(const Offset(56, 28), 3.2, _fill(accent));
  }

  /// The cloud, with its check when the central reaches it.
  void _cloud(Canvas c) {
    _floorShadow(c, 56, 86, 36, 7);
    final shape = Path()
      ..moveTo(30, 66)
      ..arcToPoint(const Offset(32, 38), radius: const Radius.circular(14))
      ..arcToPoint(const Offset(70, 33), radius: const Radius.circular(20))
      ..arcToPoint(const Offset(82, 66), radius: const Radius.circular(16))
      ..close();
    c.drawPath(shape, _fill(_top));
    c.save();
    c.clipRect(const Rect.fromLTWH(10, 58, 92, 12));
    c.drawPath(shape, _fill(_side));
    c.restore();
    c.drawPath(
        Path()
          ..moveTo(38, 36)
          ..arcToPoint(const Offset(60, 30), radius: const Radius.circular(14)),
        _line(_shine, 4));
    if (ok) {
      c.drawPath(
          Path()
            ..moveTo(46, 50)
            ..lineTo(53, 57)
            ..lineTo(66, 43),
          _line(accent, 4));
    } else {
      c.drawLine(const Offset(47, 50), const Offset(65, 50), _line(accent, 4));
    }
  }

  /// A cell standing up, filled to [level] in [accent].
  void _battery(Canvas c) {
    _floorShadow(c, 42, 108, 30, 6);
    c.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(32, 8, 20, 10), const Radius.circular(3)),
        _fill(_metal));
    final shell = RRect.fromRectAndRadius(
        const Rect.fromLTWH(18, 16, 48, 88), const Radius.circular(12));
    c.drawRRect(shell, _fill(_side));
    c.drawRRect(shell, _line(_detail, 2));
    c.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(24, 22, 8, 26), const Radius.circular(4)),
        _fill(_top));
    // The charge: from the bottom of the shell's inside (y 99) up.
    const insideTop = 21.0, insideBottom = 99.0;
    final h = (insideBottom - insideTop) * level;
    if (h > 1) {
      final r = Radius.circular(h < 16 ? h / 2 : 8);
      c.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(23, insideBottom - h, 38, h), r),
          _fill(accent));
      c.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(23, insideBottom - h, 12, h), r),
          _fill(Color.lerp(accent, Colors.white, 0.28)!));
    }
  }

  /// A thermometer: the column rises with [level].
  void _thermometer(Canvas c) {
    _floorShadow(c, 32, 110, 22, 5);
    final tube = RRect.fromRectAndRadius(
        const Rect.fromLTWH(22, 8, 20, 78), const Radius.circular(10));
    c.drawRRect(tube, _fill(_side));
    c.drawRRect(tube, _line(_detail, 2));
    c.drawCircle(const Offset(32, 88), 17, _fill(_side));
    c.drawCircle(const Offset(32, 88), 17, _line(_detail, 2));
    c.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(25, 14, 4, 22), const Radius.circular(2)),
        _fill(_top));
    // The column: from the bulb (y 86) up to y 14 at the most.
    final h = 6 + 66 * level;
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(28, 86 - h, 8, h + 4), const Radius.circular(4)),
        _fill(accent));
    c.drawCircle(const Offset(32, 88), 11, _fill(accent));
    c.drawCircle(const Offset(28, 84), 3.5,
        _fill(Color.lerp(accent, Colors.white, 0.35)!));
  }

  @override
  bool shouldRepaint(_PanelObjectPainter old) =>
      old.kind != kind ||
      old.accent != accent ||
      old.ok != ok ||
      old.level != level ||
      old.dark != dark;
}
