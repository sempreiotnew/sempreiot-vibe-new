import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../central/domain/led/led_language.dart';
import '../../../central/domain/safr/safr_product.dart';
import '../../../central/presentation/widgets/device_avatar.dart'
    show DeviceModelAvatar, LedLens, deviceFamilyIcon, deviceLedAwayOpacity;
import '../../../central/presentation/widgets/network_3d/device_model_painter.dart';
import '../../../central/presentation/widgets/network_3d/device_model_sprites.dart';

/// The unit being set up, as it really looks: its product's 3D model (the
/// same sprites Rede and Dispositivos draw, `deviceModelFor`) with its LED
/// showing what the real unit's LED shows at this step of the wizard
/// (`ledSetupLook`: white blink in setup mode, white breathe once the code
/// is stored and it looks for the network). The central is drawn as the
/// tablet (`deviceCentralModel`, the Rede hub's model). A product without a
/// model yet is drawn as its type's placeholder — the LED still blinks on it.
///
/// The picture is centred in whatever width it is given: the result step's
/// column stretches its children, and a stretched 112 px box drew the model
/// and its LED 56 px from the left edge (fixed 2026-10-30).
///
/// [product] and [family] come from the sticker until `GET /info` answers,
/// then from the unit (`ProvisioningWizardState.product`).
class SetupDevicePreview extends StatefulWidget {
  const SetupDevicePreview({
    super.key,
    required this.product,
    required this.family,
    required this.pattern,
    this.size = 120,
    this.labels = true,
    this.badge,
  });

  final SafrProduct? product;
  final SafrProductFamily family;

  /// What the unit's LED is doing; null = dark (the unit joined the
  /// installation network: its base pattern is off until a frame).
  final LedSetupPattern? pattern;

  /// The picture's box (the model's largest side fills it).
  final double size;

  /// Product name, model string and type under the picture.
  final bool labels;

  /// A small icon over the picture's corner (the result's check mark).
  final Widget? badge;

  /// The installer's text for what the LED does, in the LED language's
  /// words (root CLAUDE.md: texts that name a colour follow the table).
  static String ledCaption(LedSetupPattern? pattern) => switch (pattern) {
        LedSetupPattern.whiteBlink =>
          'LED branco piscando: modo de configuração',
        LedSetupPattern.whiteBreathe =>
          'LED branco respirando: procurando a rede da instalação',
        null => 'LED apagado: na rede da instalação',
      };

  /// The code a model is looked up by: the product's, else its type alone
  /// (`family << 8`, so a type's fallback model draws a product this app
  /// does not know, or a sticker that prints only the type).
  static int? modelCode(SafrProduct? product, SafrProductFamily family) {
    if (product != null) return product.code;
    if (family == SafrProductFamily.unknown) return null;
    return family.wire << 8;
  }

  @override
  State<SetupDevicePreview> createState() => _SetupDevicePreviewState();
}

class _SetupDevicePreviewState extends State<SetupDevicePreview>
    with SingleTickerProviderStateMixin {
  DeviceModelSpec? _spec;
  DeviceModelSprites? _sprites;

  /// Milliseconds since the pattern started, as the unit's phase counter.
  final _ms = ValueNotifier<int>(0);
  late final Ticker _ticker =
      createTicker((elapsed) => _ms.value = elapsed.inMilliseconds);

  void _resolve() {
    final code = SetupDevicePreview.modelCode(widget.product, widget.family);
    // The central's model is not a product's: deviceModelFor never returns it.
    final spec = widget.family == SafrProductFamily.board
        ? deviceCentralModel
        : deviceModelFor(code, isLeaf: widget.family == SafrProductFamily.leaf);
    if (spec?.slug == _spec?.slug && (_sprites != null || spec == null)) {
      return;
    }
    _spec = spec;
    _sprites = spec == null ? null : DeviceModelSprites.cached(spec);
    if (spec == null || _sprites != null) return;
    DeviceModelSprites.load(spec).then((s) {
      if (!mounted || _spec?.slug != s.spec.slug) return;
      setState(() => _sprites = s);
    }, onError: (_) {});
  }

  void _syncTicker() {
    final run = widget.pattern != null;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
      _ms.value = 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(SetupDevicePreview old) {
    super.didUpdateWidget(old);
    _resolve();
    if (old.pattern != widget.pattern) _ms.value = 0;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _ms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncTicker();
    final size = widget.size;
    // Center: a parent that stretches (the result step's column) must not
    // widen this box — the model and its LED are placed from its centre.
    final picture = Center(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: _picture(context)),
            if (widget.badge != null)
              Positioned(right: -4, bottom: -4, child: widget.badge!),
          ],
        ),
      ),
    );
    if (!widget.labels) return picture;

    final product = widget.product;
    final family = widget.family;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        picture,
        const SizedBox(height: 14),
        Text(
          product?.label ?? family.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (product?.model != null) ...[
          const SizedBox(height: 2),
          Text(
            product!.model!,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
        if (family != SafrProductFamily.unknown) ...[
          const SizedBox(height: 8),
          _TypeChip(family: family),
        ],
      ],
    );
  }

  /// The model with its LED where it is, or the type's placeholder with the
  /// LED at the top — never nothing: the LED is the installer's cue.
  Widget _picture(BuildContext context) {
    final sprites = _sprites;
    final size = widget.size;
    final k = size / 46;
    final ledSize = 10 * k;
    if (sprites == null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: _Placeholder(family: widget.family)),
          Positioned(
            left: (size - ledSize) / 2,
            top: -3 * k,
            child: _led(ledSize),
          ),
        ],
      );
    }
    final pose = sprites.spinPose(DeviceModelAvatar.restYaw);
    final box = sprites.frameBox(size);
    final dst = Rect.fromCenter(
        center: Offset(size / 2, size / 2), width: box, height: box);
    final led = pose.led;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: DeviceModelPainter(
              pose: pose,
              dst: dst,
              bodyFraction: sprites.frames.bodyFraction,
              online: true,
              isDark: context.isDark,
            ),
          ),
        ),
        Positioned(
          left: led == null
              ? (size - ledSize) / 2
              : dst.left + led.at.dx * dst.width - ledSize / 2,
          top: led == null
              ? -3 * k
              : dst.top + led.at.dy * dst.height - ledSize / 2,
          child: Opacity(
            opacity: led == null || led.visible ? 1 : deviceLedAwayOpacity,
            child: _led(ledSize),
          ),
        ),
      ],
    );
  }

  Widget _led(double ledSize) => ValueListenableBuilder<int>(
        valueListenable: _ms,
        builder: (context, ms, _) {
          final pattern = widget.pattern;
          final look =
              pattern == null ? LedLook.dark : ledSetupLook(pattern, ms);
          return LedLens(
            key: setupLedLensKey,
            color: look.color,
            intensity: look.intensity,
            size: ledSize,
          );
        },
      );
}

/// The LED lens on the preview (tests).
const setupLedLensKey = ValueKey('setup-led');

/// A product with no 3D model yet (the generic bench units): its type's
/// icon in a soft disc, same box as a model, so the step does not jump when
/// the model arrives. The central has its model (the tablet) since 2026-10-30.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.family});
  final SafrProductFamily family;

  @override
  Widget build(BuildContext context) {
    final icon = deviceFamilyIcon(family);
    return LayoutBuilder(
      builder: (context, c) => Center(
        child: Container(
          width: c.maxWidth * 0.8,
          height: c.maxWidth * 0.8,
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.08),
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.25),
            ),
          ),
          child:
              Icon(icon, size: c.maxWidth * 0.36, color: AppColors.secondary),
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.family});
  final SafrProductFamily family;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
      ),
      child: Text(
        family.title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.secondary,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}
