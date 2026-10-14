import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/database/app_database.dart' show safrBroadcastMac;
import '../../application/device_command_provider.dart';

/// The colour of a command's step: the LED language where it speaks (blue
/// = a frame on its way, cyan = confirmed — never green), red for nothing
/// came back.
Color commandStepColor(DeviceCommandStep step) => switch (step) {
      DeviceCommandStep.sending => AppColors.ledBlue,
      DeviceCommandStep.boardAck => AppColors.ledCyan,
      DeviceCommandStep.delivered => AppColors.ledCyan,
      DeviceCommandStep.answered => AppColors.ledCyan,
      DeviceCommandStep.failed => AppColors.error,
    };

/// What the step says, short enough for a pill under a unit.
String commandStepText(DeviceCommandStatus s) {
  final verb = s.mac == safrBroadcastMac
      ? (s.kind == DeviceCommandKind.test ? 'Teste do sistema' : 'Rearmar tudo')
      : s.kind.label;
  if (s.mac == safrBroadcastMac) {
    return switch (s.step) {
      DeviceCommandStep.sending => '$verb · enviando',
      DeviceCommandStep.boardAck => '$verb · ${s.note ?? 'placa recebeu'}',
      DeviceCommandStep.delivered ||
      DeviceCommandStep.answered =>
        '$verb · todos confirmaram',
      DeviceCommandStep.failed => '$verb · ${s.note ?? 'sem confirmação'}',
    };
  }
  if (s.kind.fromUnit) {
    return switch (s.step) {
      DeviceCommandStep.boardAck => '$verb · a central recebeu',
      DeviceCommandStep.delivered ||
      DeviceCommandStep.answered =>
        '$verb · a central confirmou',
      _ => verb,
    };
  }
  return switch (s.step) {
    DeviceCommandStep.sending => '$verb · enviando',
    DeviceCommandStep.boardAck =>
      s.waitsForWake ? '$verb · aguarda o despertar' : '$verb · placa recebeu',
    DeviceCommandStep.delivered => s.kind == DeviceCommandKind.test
        ? 'Testar · aguardando o teste'
        : '$verb · confirmado',
    DeviceCommandStep.answered => 'Teste recebido',
    DeviceCommandStep.failed => s.note == null
        ? '$verb · sem confirmação'
        : '$verb · ${s.note!.toLowerCase()}',
  };
}

/// The step as WhatsApp's ticks, nothing written: a clock while it is on
/// its way, one grey ✓ when the board took it, ✓✓ in cyan (the confirmed
/// colour) when the unit itself confirmed it — and for TESTAR, when its
/// test came back — a red mark when nothing came back. The words live in
/// the tooltip and the semantics.
class CommandTicks extends StatelessWidget {
  const CommandTicks({
    super.key,
    required this.status,
    this.size = 16,
    this.onRetry,
  });

  final DeviceCommandStatus status;
  final double size;

  /// A failed command: a tap tries again. Null: nothing to tap.
  final VoidCallback? onRetry;

  static const keySending = ValueKey('cmd-tick-sending');
  static const keyOne = ValueKey('cmd-tick-one');
  static const keyTwo = ValueKey('cmd-tick-two');
  static const keyFailed = ValueKey('cmd-tick-failed');

  @override
  Widget build(BuildContext context) {
    final step = status.step;
    final grey = context.textSecondary;
    final icon = switch (step) {
      DeviceCommandStep.sending =>
        Icon(Icons.schedule_rounded, key: keySending, size: size, color: grey),
      DeviceCommandStep.boardAck =>
        Icon(Icons.done_rounded, key: keyOne, size: size, color: grey),
      DeviceCommandStep.delivered || DeviceCommandStep.answered => Icon(
          Icons.done_all_rounded,
          key: keyTwo,
          size: size,
          color: AppColors.ledCyan),
      DeviceCommandStep.failed => Icon(Icons.error_rounded,
          key: keyFailed, size: size, color: AppColors.error),
    };
    final text = commandStepText(status) +
        (step == DeviceCommandStep.failed && onRetry != null
            ? ' — toque para tentar de novo'
            : '');
    final ticks = Tooltip(
      message: text,
      child: Semantics(
        label: text,
        button: step == DeviceCommandStep.failed && onRetry != null,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, a) => ScaleTransition(
            scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
            child: child,
          ),
          child: icon,
        ),
      ),
    );
    if (step != DeviceCommandStep.failed || onRetry == null) return ticks;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onRetry,
      child: ticks,
    );
  }
}

/// Rings that spread from a unit once, when a command reached it (cyan,
/// the confirmed colour) or when nothing came back (red). Give it a new key
/// for every step so each one plays once.
class CommandRipple extends StatefulWidget {
  const CommandRipple({super.key, required this.color, this.diameter = 46});
  final Color color;
  final double diameter;

  /// The rings' reach: the widget is this much wider than [diameter].
  static double extentFor(double diameter) => diameter * 2.2;

  @override
  State<CommandRipple> createState() => _CommandRippleState();
}

class _CommandRippleState extends State<CommandRipple>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extent = CommandRipple.extentFor(widget.diameter);
    return IgnorePointer(
      child: SizedBox.square(
        dimension: extent,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
            painter: _RipplePainter(
              t: _c.value,
              color: widget.color,
              inner: widget.diameter / 2,
            ),
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.t, required this.color, required this.inner});
  final double t;
  final Color color;
  final double inner;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.width / 2;
    for (final lag in const [0.0, 0.28]) {
      final k = ((t - lag) / (1 - lag)).clamp(0.0, 1.0);
      if (k <= 0 || k >= 1) continue;
      final eased = Curves.easeOutCubic.transform(k);
      final r = inner + (outer - inner) * eased;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4 * (1 - k) + 0.6
          ..color = color.withValues(alpha: 0.85 * (1 - k)),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t;
}

/// A unit's outcome in a system test, in a word, for the Central's grid.
String commandOutcomeLabel(DeviceCommandStatus s) => switch (s.step) {
      DeviceCommandStep.sending ||
      DeviceCommandStep.boardAck =>
        s.waitsForWake ? 'Próximo despertar' : 'Pendente',
      DeviceCommandStep.delivered || DeviceCommandStep.answered => 'Confirmado',
      DeviceCommandStep.failed => s.note == DeviceCommandTracker.missingNote
          ? 'Sem comunicação'
          : s.note == DeviceCommandTracker.cancelledNote
              ? 'Cancelado'
              : 'Sem resposta',
    };
