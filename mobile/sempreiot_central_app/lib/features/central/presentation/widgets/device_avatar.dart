import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/device_led_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/led/led_language.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import 'network_3d/device_model_painter.dart';
import 'network_3d/device_model_sprites.dart';

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

/// A device drawn as a circle: double ring in its status colour, role icon
/// (or the animated moon of a sleeping leaf), the LED, and the ALARME /
/// ROOT / CANDIDATO badges.
/// One widget for the Rede map and the Dispositivos screen, so a device
/// looks the same everywhere. A unit whose product has a 3D model is drawn
/// as that model on Dispositivos and Dispositivo ([DeviceModelAvatar]).
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

/// Opacity of a unit's LED dot when the LED is on the far side of its 3D
/// model: still clearly showing its status, a little dimmed for depth.
const deviceLedAwayOpacity = 0.75;

/// A device drawn as its product's 3D model (system reference §2.1.1 —
/// the same Blender renders as Rede 3D), as rendered (no outline), with
/// everything [DeviceAvatar] shows: the LED on the model's LED (always
/// visible), the sleeping moon and the ALARME / ROOT / CANDIDATO badges (no
/// status dot: Dispositivos says the state on the card). In ALARME a siren
/// lights up red and rings ([DeviceModelPainter]). A unit whose product has no model — or while its
/// model loads — is the [DeviceAvatar] circle, same size, so a list never
/// jumps.
///
/// [size] is the layout box (the circle's diameter); the model's largest
/// side fills it. [spin]: it turns on itself, one turn every [spinPeriod]
/// (Dispositivos); still otherwise, three-quarter from the front
/// (Dispositivo). [interactive]: a horizontal drag turns it, a double tap
/// puts it back. Spinning stops when the system asks for reduced motion.
class DeviceModelAvatar extends StatefulWidget {
  const DeviceModelAvatar({
    super.key,
    required this.node,
    this.isRoot = false,
    this.isCandidate = false,
    this.size = 46,
    this.spin = false,
    this.interactive = false,
  });

  final TopologyNode node;
  final bool isRoot;
  final bool isCandidate;
  final double size;
  final bool spin;
  final bool interactive;

  /// The resting view: turned 30° to show the unit's right side, seen from
  /// the spin tilt (15° above) — how it reads on a wall.
  static const restYaw = 30 * math.pi / 180;
  static const spinPeriod = Duration(seconds: 7);

  @override
  State<DeviceModelAvatar> createState() => _DeviceModelAvatarState();
}

class _DeviceModelAvatarState extends State<DeviceModelAvatar>
    with SingleTickerProviderStateMixin {
  double _yaw = DeviceModelAvatar.restYaw;
  DeviceModelSpec? _spec;
  Future<DeviceModelSprites>? _future;
  DeviceModelSprites? _sprites;

  /// Seconds since the clock started; drives the spin and the alarm.
  final _clock = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(
      (elapsed) => _clock.value = elapsed.inMicroseconds / 1e6);

  void _resolve() {
    final spec = deviceModelFor(widget.node.productCode,
        isLeaf: widget.node.isLeaf);
    if (spec?.slug == _spec?.slug && (_future != null || spec == null)) {
      return;
    }
    _spec = spec;
    _sprites = null;
    _future = spec == null ? null : DeviceModelSprites.load(spec);
    _future?.then((s) {
      if (!mounted || _spec?.slug != s.spec.slug) return;
      setState(() => _sprites = s);
    }, onError: (_) {});
  }

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// The clock runs only while something moves: a spinning model, or an
  /// alarm on a model that shows one.
  void _syncTicker() {
    final s = _sprites;
    final alarmFx = s != null &&
        widget.node.alarmLatched &&
        (s.hasAlarmLights || s.spec.alarmSound);
    final run = s != null && ((widget.spin && !_reduceMotion) || alarmFx);
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(DeviceModelAvatar old) {
    super.didUpdateWidget(old);
    _resolve();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sprites = _sprites;
    _syncTicker();
    if (sprites == null) {
      return DeviceAvatar(
        node: widget.node,
        isRoot: widget.isRoot,
        isCandidate: widget.isCandidate,
        diameter: widget.size,
      );
    }
    final model = ValueListenableBuilder<double>(
      valueListenable: _clock,
      builder: (context, t, _) => _model(context, sprites, t),
    );
    if (!widget.interactive) return model;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) =>
          setState(() => _yaw -= d.delta.dx * 0.018),
      onDoubleTap: () => setState(() => _yaw = DeviceModelAvatar.restYaw),
      child: model,
    );
  }

  Widget _model(BuildContext context, DeviceModelSprites sprites, double t) {
    final node = widget.node;
    final size = widget.size;
    final k = size / 46;
    final spinning = widget.spin && !_reduceMotion;
    final yaw = spinning
        ? DeviceModelAvatar.restYaw +
            t * 2 * math.pi * 1e6 / DeviceModelAvatar.spinPeriod.inMicroseconds
        : _yaw;
    final pose = sprites.spinPose(yaw);
    final box = size / sprites.frames.bodyFraction;
    final dst = Rect.fromCenter(
        center: Offset(size / 2, size / 2), width: box, height: box);
    final led = pose.led;
    final alarm = node.alarmLatched ? (_reduceMotion ? 0.06 : t) : null;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: DeviceModelPainter(
                pose: pose,
                dst: dst,
                bodyFraction: sprites.frames.bodyFraction,
                online: node.online,
                isDark: context.isDark,
                alarm: alarm,
                sound: sprites.spec.alarmSound,
              ),
            ),
          ),
          // The unit's LED where it is on the model — always shown, a little
          // dimmed on the far side. No LED marker: top centre, as on the
          // circle.
          Positioned(
            left: led == null
                ? (size - 10 * k) / 2
                : dst.left + led.at.dx * dst.width - 5 * k,
            top: led == null
                ? -3 * k
                : dst.top + led.at.dy * dst.height - 5 * k,
            child: Opacity(
              opacity: led == null || led.visible ? 1 : deviceLedAwayOpacity,
              child: DeviceLedDot(node: node, size: 10 * k),
            ),
          ),
          if (node.sleeping)
            Positioned(
              left: -2,
              top: -2,
              width: 20 * k,
              height: 20 * k,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.surfaceColor,
                  border: Border.all(color: context.borderColor, width: 0.8),
                ),
                child: DeviceSleepingMoon(
                  color: context.textPrimary,
                  zColor: context.textSecondary,
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
          if (widget.isRoot || widget.isCandidate)
            Positioned(
              left: widget.isCandidate ? -18 : -8,
              bottom: -7,
              child: widget.isRoot
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
          if (widget.interactive && !node.alarmLatched)
            Positioned(
              right: -4 * k,
              bottom: -4 * k,
              child: Tooltip(
                message: 'Arraste para girar',
                child: Icon(
                  Icons.threesixty_rounded,
                  size: 13 * k,
                  color: context.textSecondary.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
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
