import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/theme_ext.dart';
import '../../../application/ota_push_report.dart';
import '../../../application/ota_rollout_report.dart';
import '../../../application/topology_provider.dart';
import '../../../domain/safr/safr_v2_payloads.dart';
import '../device_avatar.dart';
import '../ota_rede_widgets.dart';
import 'device_model_painter.dart';
import 'device_model_sprites.dart';

/// Where the sphere's centre sits inside the chip (the anchor the graph
/// places on the device's point) — same as the flat 2D chips.
const device3dAnchorY = 26.0;
const central3dAnchorY = 27.0;

/// Where the light hits the spheres, from the camera's turn and tilt: the
/// light is fixed in the world, so turning the graph moves the highlight
/// across every sphere and they read as solid balls.
Alignment sphereLightFor(double yaw, double pitch) => Alignment(
      (-0.38 + 0.25 * _wrap(yaw)).clamp(-0.7, 0.2),
      (-0.45 + 0.35 * pitch).clamp(-0.75, 0.1),
    );

double _wrap(double a) {
  // −π..π → −1..1, smooth.
  final t = (a + 3.141592653589793) % (2 * 3.141592653589793);
  return (t / 3.141592653589793) - 1;
}

/// A mesh device as a shaded sphere with every feature of the flat
/// [DeviceAvatar]: status colour (rim light and tint), role icon, status
/// dot, the LED lens, the sleeping moon, ROOT / CANDIDATO / ALARME badges
/// and the name.
class Device3dChip extends StatelessWidget {
  const Device3dChip({
    super.key,
    required this.node,
    required this.light,
    this.isRoot = false,
    this.isCandidate = false,
    this.pending,
    this.activity,
  });

  final TopologyNode node;
  final Alignment light;
  final bool isRoot;
  final bool isCandidate;

  /// A rollout has this unit in it: a progress ring goes around the sphere
  /// while it is being updated and the line under its name says where it
  /// is. The LED lens on top is untouched: it is the unit's LED, the ring
  /// is not.
  final OtaUnitActivity? activity;

  /// The version of an image of this unit's family that is stored on the
  /// board and was not delivered; null = none.
  final String? pending;

  static const width = 104.0;
  static const _d = 46.0; // sphere diameter (the flat avatar's)

  @override
  Widget build(BuildContext context) {
    // Same colour rules as DeviceAvatar's ring.
    final rim = isRoot
        ? AppColors.warning
        : isCandidate
            ? AppColors.warning.withValues(alpha: 0.7)
            : node.online
                ? AppColors.secondary
                : AppColors.error;
    final statusColor = !node.online
        ? AppColors.error
        : node.sleeping
            ? context.textSecondary
            : AppColors.success;
    final icon = switch (node.role) {
      SafrNodeRole.root => Icons.power_rounded,
      SafrNodeRole.node => Icons.cell_tower_rounded,
      _ => Icons.sensors_rounded,
    };
    const cx = width / 2, cy = device3dAnchorY, r = _d / 2;
    final hasName = node.name?.isNotEmpty == true;

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 58,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: SpherePainter(
                      center: const Offset(cx, cy),
                      radius: r,
                      tint: rim,
                      online: node.online,
                      goldRing: isRoot,
                      light: light,
                      isDark: context.isDark,
                    ),
                  ),
                ),
                Positioned(
                  left: cx - r,
                  top: cy - r,
                  width: _d,
                  height: _d,
                  child: Center(
                    child: node.sleeping
                        ? SizedBox(
                            width: 34,
                            height: 34,
                            child: DeviceSleepingMoon(
                              color: context.textPrimary,
                              zColor: context.textSecondary,
                            ),
                          )
                        : Icon(
                            icon,
                            size: 19,
                            color: node.online
                                ? Colors.white.withValues(alpha: 0.95)
                                : Colors.white.withValues(alpha: 0.55),
                            shadows: const [
                              Shadow(color: Colors.black54, blurRadius: 4),
                            ],
                          ),
                  ),
                ),
                if (activity?.updating == true)
                  Positioned(
                    left: cx - OtaProgressRing.sizeFor(_d) / 2,
                    top: cy - OtaProgressRing.sizeFor(_d) / 2,
                    child: OtaUnitRing(activity: activity!, diameter: _d),
                  ),
                // The unit's LED: a lens on top of the sphere.
                Positioned(
                  left: cx - 5,
                  top: cy - r - 3,
                  child: DeviceLedDot(node: node, size: 10),
                ),
                Positioned(
                  left: cx + r * 0.62,
                  top: cy - r * 0.95,
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
                                color: statusColor.withValues(alpha: 0.6),
                                blurRadius: 5,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
                if (node.alarmLatched)
                  const Positioned(
                    left: cx + r - 14,
                    top: cy + r - 6,
                    child: _Badge(
                      label: 'ALARME',
                      background: AppColors.error,
                      foreground: Colors.white,
                      glow: AppColors.error,
                    ),
                  ),
                if (isRoot || isCandidate)
                  Positioned(
                    right: cx + r - (isCandidate ? 4 : 14),
                    top: cy + r - 6,
                    child: isRoot
                        ? const _Badge(
                            label: 'ROOT',
                            background: AppColors.warning,
                            foreground: Colors.black,
                            glow: AppColors.warning,
                          )
                        : _Badge(
                            label: 'CANDIDATO',
                            background:
                                AppColors.warning.withValues(alpha: 0.18),
                            foreground: AppColors.warning,
                            border: AppColors.warning.withValues(alpha: 0.7),
                          ),
                  ),
              ],
            ),
          ),
          Text(
            deviceDisplayName(node),
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: hasName ? context.textPrimary : context.textSecondary,
              fontSize: hasName ? 9.5 : 8,
              fontWeight: FontWeight.w600,
              fontFamily: hasName ? null : 'monospace',
              letterSpacing: hasName ? 0 : -0.2,
            ),
          ),
          // The firmware it runs, and whether another waits on the board.
          // In a rollout: where the unit is in it.
          if (activity != null)
            OtaUnitTag(activity: activity!, version: node.fwVersion)
          else
            FirmwareTag(version: node.fwVersion, pending: pending),
        ],
      ),
    );
  }
}

/// The CENTRAL as a larger blue sphere with the tablet icon, the board's
/// LED on top, and the CENTRAL / MAC labels.
class Central3dChip extends StatelessWidget {
  const Central3dChip({
    super.key,
    required this.light,
    this.board,
    this.activity,
  });

  final Alignment light;
  final TopologyNode? board;

  /// A firmware push runs: what the board is doing with it. The sphere
  /// then shows the board (the tablet is drawn beside it), a progress ring
  /// goes around it and the caption says the phase. The LED lens on top is
  /// untouched: it is the board's LED, the ring is not.
  final OtaBoardActivity? activity;

  static const width = 120.0;
  static const _d = 54.0;

  @override
  Widget build(BuildContext context) {
    const cx = width / 2, cy = central3dAnchorY, r = _d / 2;
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 64,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: SpherePainter(
                      center: const Offset(cx, cy),
                      radius: r,
                      tint: AppColors.primary,
                      online: true,
                      light: light,
                      isDark: context.isDark,
                      solid: true,
                    ),
                  ),
                ),
                Positioned(
                  left: cx - r,
                  top: cy - r,
                  width: _d,
                  height: _d,
                  child: Center(
                    child: Icon(
                        activity == null
                            ? Icons.tablet_mac_rounded
                            : Icons.developer_board_rounded,
                        color: Colors.white,
                        size: 24,
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 4),
                        ]),
                  ),
                ),
                if (activity != null)
                  Positioned(
                    left: cx - OtaProgressRing.sizeFor(_d) / 2,
                    top: cy - OtaProgressRing.sizeFor(_d) / 2,
                    child: OtaProgressRing(activity: activity!, diameter: _d),
                  ),
                if (board != null)
                  Positioned(
                    left: cx - 5.5,
                    top: cy - r - 3,
                    child: DeviceLedDot(node: board!, size: 11),
                  ),
              ],
            ),
          ),
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
          if (board != null)
            Text(
              board!.mac,
              style: TextStyle(
                color: context.textSecondary.withValues(alpha: 0.8),
                fontSize: 8,
                fontFamily: 'monospace',
              ),
            ),
        ],
      ),
    );
  }
}

/// A unit drawn as its product's 3D model (system reference §2.1.1): the
/// atlas frame for the camera's turn and tilt, as rendered (no outline), the
/// LED lens on the model's LED, the siren's lights and sound waves in
/// ALARME, and the same status dot, sleeping moon, ALARME / ROOT / CANDIDATO
/// badges, name and firmware line as every chip.
class Model3dChip extends StatelessWidget {
  const Model3dChip({
    super.key,
    required this.node,
    required this.sprites,
    required this.yaw,
    required this.pitch,
    this.isRoot = false,
    this.isCandidate = false,
    this.pending,
    this.activity,
  });

  final TopologyNode node;
  final DeviceModelSprites sprites;
  final double yaw, pitch;
  final bool isRoot;
  final bool isCandidate;

  /// The version of an image of this unit's family that is stored on the
  /// board and was not delivered; null = none.
  final String? pending;

  /// A rollout has this unit in it (see [Device3dChip.activity]).
  final OtaUnitActivity? activity;

  static const width = 104.0;

  @override
  Widget build(BuildContext context) {
    final frames = sprites.frames;
    final pose = sprites.mapPose(yaw, pitch);
    final body = sprites.spec.displaySize;
    final box = body / frames.bodyFraction;
    const cx = width / 2, cy = device3dAnchorY;
    final dst =
        Rect.fromCenter(center: const Offset(cx, cy), width: box, height: box);
    final led = pose.led;
    // The screen redraws every frame: in ALARME the siren's lights and sound
    // waves run off the clock.
    final alarm = node.alarmLatched
        ? DateTime.now().microsecondsSinceEpoch / 1e6
        : null;
    final statusColor = !node.online
        ? AppColors.error
        : node.sleeping
            ? context.textSecondary
            : AppColors.success;
    final hasName = node.name?.isNotEmpty == true;

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 58,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: DeviceModelPainter(
                      pose: pose,
                      dst: dst,
                      bodyFraction: frames.bodyFraction,
                      online: node.online,
                      isDark: context.isDark,
                      alarm: alarm,
                      sound: sprites.spec.alarmSound,
                    ),
                  ),
                ),
                if (activity?.updating == true)
                  Positioned(
                    left: cx - OtaProgressRing.sizeFor(body) / 2,
                    top: cy - OtaProgressRing.sizeFor(body) / 2,
                    child: OtaUnitRing(activity: activity!, diameter: body),
                  ),
                // The LED lens on the model's LED — always shown, a little
                // dimmed when it faces away. A model without an LED marker
                // gets it on top.
                Positioned(
                  left: led == null ? cx - 5 : dst.left + led.at.dx * dst.width - 5,
                  top: led == null
                      ? cy - body * 0.5 - 3
                      : dst.top + led.at.dy * dst.height - 5,
                  child: Opacity(
                    opacity: led == null || led.visible ? 1 : deviceLedAwayOpacity,
                    child: DeviceLedDot(node: node, size: 10),
                  ),
                ),
                Positioned(
                  left: cx + body * 0.34,
                  top: cy - body * 0.48,
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
                                color: statusColor.withValues(alpha: 0.6),
                                blurRadius: 5,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
                if (node.sleeping)
                  Positioned(
                    left: cx - body * 0.5 - 4,
                    top: cy - body * 0.5 - 4,
                    width: 20,
                    height: 20,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.surfaceColor,
                        border:
                            Border.all(color: context.borderColor, width: 0.8),
                      ),
                      child: DeviceSleepingMoon(
                        color: context.textPrimary,
                        zColor: context.textSecondary,
                      ),
                    ),
                  ),
                if (node.alarmLatched)
                  Positioned(
                    left: cx + 6,
                    top: cy + body * 0.38,
                    child: const _Badge(
                      label: 'ALARME',
                      background: AppColors.error,
                      foreground: Colors.white,
                      glow: AppColors.error,
                    ),
                  ),
                if (isRoot || isCandidate)
                  Positioned(
                    right: cx + body * 0.5 - (isCandidate ? 4 : 14),
                    top: cy + body * 0.38,
                    child: isRoot
                        ? const _Badge(
                            label: 'ROOT',
                            background: AppColors.warning,
                            foreground: Colors.black,
                            glow: AppColors.warning,
                          )
                        : _Badge(
                            label: 'CANDIDATO',
                            background:
                                AppColors.warning.withValues(alpha: 0.18),
                            foreground: AppColors.warning,
                            border: AppColors.warning.withValues(alpha: 0.7),
                          ),
                  ),
              ],
            ),
          ),
          Text(
            deviceDisplayName(node),
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: hasName ? context.textPrimary : context.textSecondary,
              fontSize: hasName ? 9.5 : 8,
              fontWeight: FontWeight.w600,
              fontFamily: hasName ? null : 'monospace',
              letterSpacing: hasName ? 0 : -0.2,
            ),
          ),
          // The firmware it runs, and whether another waits on the board.
          // In a rollout: where the unit is in it.
          if (activity != null)
            OtaUnitTag(activity: activity!, version: node.fwVersion)
          else
            FirmwareTag(version: node.fwVersion, pending: pending),
        ],
      ),
    );
  }
}

/// A lit sphere: contact shadow, status glow, body shaded from [light],
/// rim light in the status colour, a specular highlight and a gold ring
/// for the root.
class SpherePainter extends CustomPainter {
  SpherePainter({
    required this.center,
    required this.radius,
    required this.tint,
    required this.online,
    required this.light,
    required this.isDark,
    this.goldRing = false,
    this.solid = false,
  });

  final Offset center;
  final double radius;
  final Color tint;
  final bool online, isDark, goldRing;

  /// A solid coloured ball (CENTRAL) instead of the tinted glass devices.
  final bool solid;
  final Alignment light;

  @override
  void paint(Canvas canvas, Size size) {
    final c = center, r = radius;
    final ball = Rect.fromCircle(center: c, radius: r);

    // Contact shadow, a little below the ball.
    canvas.drawOval(
      Rect.fromCenter(
          center: c + Offset(0, r * 0.95), width: r * 1.7, height: r * 0.45),
      Paint()
        ..color = Colors.black.withValues(alpha: isDark ? 0.55 : 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // Status glow around it.
    canvas.drawCircle(
      c,
      r * 1.12,
      Paint()
        ..color = tint.withValues(alpha: online ? 0.35 : 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );

    // Body: lit side → base → shadowed side.
    final base = solid
        ? tint
        : Color.lerp(
            isDark ? const Color(0xFF1E2A3B) : const Color(0xFF64748B),
            tint,
            online ? 0.45 : 0.30,
          )!;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: light,
          radius: 1.25,
          colors: [
            Color.lerp(base, Colors.white, 0.55)!,
            base,
            Color.lerp(base, Colors.black, 0.65)!,
          ],
          stops: const [0, 0.45, 1],
        ).createShader(ball),
    );
    // Rim light on the far side from the light, in the status colour.
    canvas.drawCircle(
      c,
      r - 0.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = RadialGradient(
          center: Alignment(-light.x, -light.y),
          radius: 1.1,
          colors: [
            tint.withValues(alpha: 0.95),
            tint.withValues(alpha: 0.15),
          ],
        ).createShader(ball),
    );
    // Specular highlight.
    final hl = c + Offset(light.x * r * 0.55, light.y * r * 0.55);
    canvas.drawOval(
      Rect.fromCenter(center: hl, width: r * 0.62, height: r * 0.42),
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.75),
          Colors.white.withValues(alpha: 0),
        ]).createShader(
            Rect.fromCenter(center: hl, width: r * 0.62, height: r * 0.42)),
    );
    if (goldRing) {
      canvas.drawCircle(
        c,
        r + 3.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = AppColors.warning.withValues(alpha: 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(SpherePainter o) =>
      o.light != light ||
      o.tint != tint ||
      o.online != online ||
      o.isDark != isDark ||
      o.goldRing != goldRing;
}

/// Same badge as the flat chips (device_avatar.dart).
class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.background,
    required this.foreground,
    this.glow,
    this.border,
  });

  final String label;
  final Color background;
  final Color foreground;
  final Color? glow;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: border == null ? null : Border.all(color: border!),
        boxShadow: glow == null
            ? null
            : [BoxShadow(color: glow!.withValues(alpha: 0.4), blurRadius: 6)],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 7.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
