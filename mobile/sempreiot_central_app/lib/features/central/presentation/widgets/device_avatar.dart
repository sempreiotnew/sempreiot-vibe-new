import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/device_led_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/led/led_language.dart';
import '../../domain/safr/safr_v2_payloads.dart';

/// Opacity of a device that has been silent for longer than
/// [topologyStaleAfter]: still shown, visibly faded.
const deviceStaleOpacity = 0.32;

/// The device's name when set, otherwise its full MAC — never a fragment.
String deviceDisplayName(TopologyNode node) =>
    node.name?.isNotEmpty == true ? node.name! : node.mac;

String deviceRoleLabel(TopologyNode node) => node.layer == 0
    ? 'Placa (gateway para a central)'
    : switch (node.role) {
        SafrNodeRole.root => 'Root da malha (alimentado 24h)',
        SafrNodeRole.node => 'Repetidor',
        SafrNodeRole.leaf => 'Sensor (dorme entre envios)',
        _ => 'Desconhecido',
      };

/// A unit that is being updated reads "Atualizando" — never "Sem
/// comunicação": it is silent while it restarts into its new firmware
/// (protocol §13.4).
String deviceStateLabel(TopologyNode node) => node.updating
    ? 'Atualizando'
    : _deviceStateLabel(node);

String _deviceStateLabel(TopologyNode node) => node.online
    ? (node.sleeping
        ? 'Dormindo'
        : node.isLeaf
            ? (node.alarmLatched ? 'Acordado — em alarme' : 'Acordado')
            : 'Online')
    : node.stale
        ? 'Sem comunicação há muito tempo'
        : 'Sem comunicação';

/// A device drawn as a circle: double ring, role icon (or the animated moon
/// of a sleeping leaf), status dot, and the ALARME / ROOT / CANDIDATO badges.
/// One widget for the Rede map and the Dispositivos screen, so a device
/// looks the same everywhere — and a product photo, when there is one, only
/// has to replace the inner icon here.
class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({
    super.key,
    required this.node,
    this.isRoot = false,
    this.isCandidate = false,
    this.diameter = 46,
  });

  final TopologyNode node;
  final bool isRoot;
  final bool isCandidate;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final k = diameter / 46;
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
        : isCandidate
            ? AppColors.warning.withValues(alpha: 0.55)
            : node.online
                ? AppColors.secondary.withValues(alpha: 0.6)
                : AppColors.error.withValues(alpha: 0.65);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Outer ring + inner avatar (double-ring look)
        Container(
          width: diameter,
          height: diameter,
          padding: EdgeInsets.all(3 * k),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ringColor, width: isRoot ? 1.8 : 1.1),
            boxShadow: [
              BoxShadow(
                color: (isRoot ? AppColors.warning : ringColor)
                    .withValues(alpha: node.online ? 0.28 : 0.10),
                blurRadius: 12 * k,
              ),
            ],
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: node.online
                  ? Color.alphaBlend(
                      ringColor.withValues(alpha: 0.10), context.surfaceColor)
                  : context.surfaceColor,
            ),
            child: node.sleeping
                ? FittedBox(
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: DeviceSleepingMoon(
                        color: context.textPrimary,
                        zColor: context.textSecondary,
                      ),
                    ),
                  )
                : Icon(
                    icon,
                    size: 19 * k,
                    color: node.online
                        ? context.textPrimary
                        : context.textSecondary.withValues(alpha: 0.7),
                  ),
          ),
        ),
        // The unit's RGB LED, where it sits on the real device: top centre.
        Positioned(
          top: -3 * k,
          left: (diameter - 10 * k) / 2,
          child: DeviceLedDot(node: node, size: 10 * k),
        ),
        Positioned(
          right: -1,
          top: -1,
          child: Container(
            width: 12 * k,
            height: 12 * k,
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
            right: -10,
            bottom: -7,
            child: _Badge(
              label: 'ALARME',
              background: AppColors.error,
              foreground: Colors.white,
              glow: AppColors.error,
            ),
          ),
        if (isRoot || isCandidate)
          Positioned(
            left: isCandidate ? -18 : -8,
            bottom: -7,
            child: isRoot
                ? const _Badge(
                    label: 'ROOT',
                    background: AppColors.warning,
                    foreground: Colors.black,
                    glow: AppColors.warning,
                  )
                : _Badge(
                    label: 'CANDIDATO',
                    background: AppColors.warning.withValues(alpha: 0.18),
                    foreground: AppColors.warning,
                    border: AppColors.warning.withValues(alpha: 0.7),
                  ),
          ),
      ],
    );
  }
}

/// Screen colour of each LED colour — the Rede packets use the same blue
/// and cyan (AppColors.ledBlue / ledCyan).
Color ledDisplayColor(LedColor c) => switch (c) {
      LedColor.red => const Color(0xFFEF4444),
      LedColor.green => const Color(0xFF22C55E),
      LedColor.blue => AppColors.ledBlue,
      LedColor.cyan => AppColors.ledCyan,
      LedColor.magenta => const Color(0xFFD946EF),
      LedColor.yellow => const Color(0xFFFACC15),
      LedColor.white => Colors.white,
    };

/// A small LED lens showing what [node]'s LED shows right now: dark when
/// off, its colour with a glow when lit (device_led_provider). Redraws every
/// frame only while that LED is changing — a pulse, IDENTIFY, the root /
/// board slow flash — and sits still otherwise.
class DeviceLedDot extends ConsumerStatefulWidget {
  const DeviceLedDot({super.key, required this.node, this.size = 10});

  final TopologyNode node;
  final double size;

  @override
  ConsumerState<DeviceLedDot> createState() => _DeviceLedDotState();
}

class _DeviceLedDotState extends ConsumerState<DeviceLedDot>
    with SingleTickerProviderStateMixin {
  // From the TickerProvider, so it pauses with the tab (TickerMode).
  late final Ticker _ticker = createTicker(_onFrame);
  LedColor? _shown;

  void _onFrame(Duration _) {
    if (!mounted) return;
    final engine = ref.read(deviceLedProvider);
    final now = engine.look(widget.node).color;
    if (now != _shown) setState(() => _shown = now);
    if (!engine.animating(widget.node)) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(deviceLedProvider);
    _shown = engine.look(widget.node).color;
    if (engine.animating(widget.node)) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
    final led = _shown == null ? null : ledDisplayColor(_shown!);
    final size = widget.size;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Unlit: a dark lens. Lit: the colour, a hot centre and a glow.
        gradient: led == null
            ? null
            : RadialGradient(
                center: const Alignment(-0.3, -0.3),
                colors: [Color.lerp(led, Colors.white, 0.55)!, led],
              ),
        color: led == null
            ? Color.alphaBlend(
                Colors.black.withValues(alpha: context.isDark ? 0.35 : 0.55),
                context.surfaceColor)
            : null,
        border: Border.all(
          color: led == null
              ? context.borderColor
              : Color.lerp(led, Colors.white, 0.3)!,
          width: 0.8,
        ),
        boxShadow: led == null
            ? null
            : [
                BoxShadow(
                  color: led.withValues(alpha: 0.9),
                  blurRadius: size * 0.9,
                  spreadRadius: size * 0.15,
                ),
              ],
      ),
    );
  }
}

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

/// The moon of a sleeping leaf with two small "z" drifting up and fading,
/// clipped to the avatar circle so the layout never changes. One controller
/// per sleeping leaf; the frame cost is two tiny texts.
class DeviceSleepingMoon extends StatefulWidget {
  const DeviceSleepingMoon({
    super.key,
    required this.color,
    required this.zColor,
  });

  final Color color;
  final Color zColor;

  @override
  State<DeviceSleepingMoon> createState() => _DeviceSleepingMoonState();
}

class _DeviceSleepingMoonState extends State<DeviceSleepingMoon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// One "z": rises 7 px and fades over its own third of the cycle, staggered
  /// by `delay` (0..1) so the two never move together.
  Widget _z(double t, double delay, double size, double right, double bottom) {
    final u = ((t - delay) % 1.0 + 1.0) % 1.0; // 0..1 within this z's cycle
    final visible = u < 0.55;
    final k = visible ? u / 0.55 : 0.0;
    final opacity =
        visible ? (k < 0.25 ? k / 0.25 : 1.0 - (k - 0.25) / 0.75) : 0.0;
    return Positioned(
      right: right - k * 1.5,
      bottom: bottom + k * 7,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Text(
          'z',
          style: TextStyle(
            color: widget.zColor,
            fontSize: size,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Stack(
            clipBehavior: Clip.hardEdge,
            alignment: Alignment.center,
            children: [
              // The moon breathes very slightly with the first z.
              Transform.translate(
                offset: Offset(-1.5, 1.5 - 1.0 * (0.5 - (t - 0.5).abs())),
                child: Icon(Icons.dark_mode_rounded,
                    size: 18, color: widget.color),
              ),
              _z(t, 0.0, 7.5, 7, 22),
              _z(t, 0.45, 6, 3, 20),
            ],
          );
        },
      ),
    );
  }
}
