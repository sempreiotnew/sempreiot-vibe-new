import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import 'device_model_sprites.dart';

/// Draws one view of a product's 3D model (Rede 3D, Dispositivos,
/// Dispositivo) as it is — the raw Blender render, no outline — on a soft
/// contact shadow; offline = a little faded, as the flat chips.
///
/// In ALARME ([alarm] = seconds on a running clock, null = no alarm) a model
/// with alarm lights (the siren's lens) lights up red with a double strobe
/// flash every second and a red bloom around it, and a model that rings
/// ([sound]) sends sound waves out of both sides. This is the siren's own
/// sounder and strobe, never its status LED: the LED is drawn on top by the
/// widget, in the LED language, untouched.
class DeviceModelPainter extends CustomPainter {
  DeviceModelPainter({
    required this.pose,
    required this.dst,
    required this.bodyFraction,
    required this.online,
    required this.isDark,
    this.alarm,
    this.sound = false,
  });

  final ModelPose pose;

  /// The whole frame; the model's largest side fills [bodyFraction] of it.
  final Rect dst;
  final double bodyFraction;
  final bool online, isDark;
  final double? alarm;
  final bool sound;

  static const _red = AppColors.error;

  /// 0..1: the strobe — two short flashes at the start of every second.
  static double strobe(double seconds) {
    final t = seconds % 1.0;
    double pulse(double c) {
      final d = (t - c) / 0.045;
      return math.exp(-d * d);
    }

    return math.max(pulse(0.06), pulse(0.24));
  }

  Rect get body => dst.deflate(dst.width * (1 - bodyFraction) / 2);

  @override
  void paint(Canvas canvas, Size size) {
    final b = body;
    // Contact shadow under the model.
    canvas.drawOval(
      Rect.fromCenter(
          center: b.bottomCenter, width: b.width * 0.8, height: b.height * 0.18),
      Paint()
        ..color = Colors.black.withValues(alpha: isDark ? 0.5 : 0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // The model: frame a, and while it turns frame b blended over it.
    final fade = online ? 1.0 : 0.7;
    _frames(canvas, pose.image, (w) => Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Colors.white.withValues(alpha: fade * w), blendOver: true);

    final s = alarm;
    if (s == null) return;
    final glow = pose.glow;
    if (glow != null) {
      final flash = strobe(s);
      final lit = 0.5 + 0.5 * flash; // the lights are on; the strobe peaks
      // Red bloom around the lights.
      final sigma = dst.width * 0.045;
      canvas.saveLayer(
        dst.inflate(dst.width * 0.35),
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      _frames(canvas, glow, (w) => Paint()
        ..colorFilter = ColorFilter.mode(
            _red.withValues(alpha: (0.55 + 0.45 * flash) * w), BlendMode.srcIn));
      canvas.restore();
      // The lens itself: red light, white-hot at the flash.
      _frames(canvas, glow, (w) => Paint()
        ..filterQuality = FilterQuality.medium
        ..blendMode = BlendMode.screen
        ..colorFilter = ColorFilter.mode(
            Color.lerp(_red, Colors.white, 0.45 * flash)!
                .withValues(alpha: lit * w),
            BlendMode.srcIn));
    }
    if (sound) _waves(canvas, b, s);
  }

  /// Draws [image] at frame a, and frame b weighted by t. [blendOver]: a
  /// solid model — b goes over a fully drawn a (no see-through mid-turn);
  /// otherwise light layers split the weight between the two.
  void _frames(Canvas canvas, ui.Image image, Paint Function(double w) paint,
      {bool blendOver = false}) {
    final t = pose.b == null ? 0.0 : pose.t;
    canvas.drawImageRect(image, pose.a, dst, paint(blendOver ? 1 : 1 - t));
    if (pose.b != null && t > 0) {
      canvas.drawImageRect(image, pose.b!, dst, paint(t));
    }
  }

  /// Three arcs per side, travelling out and fading, one every 0.4 s.
  void _waves(Canvas canvas, Rect b, double seconds) {
    final c = b.center;
    final r0 = b.width * 0.42;
    for (var k = 0; k < 3; k++) {
      final p = (seconds / 1.2 + k / 3) % 1.0;
      final r = r0 + b.width * 0.42 * p;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1.2, b.width * 0.035)
        ..color = _red.withValues(alpha: (1 - p) * (online ? 0.85 : 0.5));
      final rect = Rect.fromCircle(center: c, radius: r);
      canvas.drawArc(rect, -0.42, 0.84, false, paint); // right
      canvas.drawArc(rect, math.pi - 0.42, 0.84, false, paint); // left
    }
  }

  @override
  bool shouldRepaint(DeviceModelPainter o) =>
      o.pose != pose ||
      o.dst != dst ||
      o.online != online ||
      o.isDark != isDark ||
      o.alarm != alarm ||
      o.sound != sound;
}
