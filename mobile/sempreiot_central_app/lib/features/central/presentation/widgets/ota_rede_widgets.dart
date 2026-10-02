import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_rollout_report.dart';
import '../../domain/safr/safr_v2_payloads.dart';

// What the map of "Atualizar dispositivos" (MeshMap with showOta) draws of
// a firmware push and of a rollout. They draw what they are given; nothing
// here decides anything about either.
//
// None of this is a unit's LED. The LED mirror (device_led_provider.dart)
// keeps its own colours and patterns; the ring and the caption are drawings
// of the tablet, in the app's accent colour.

/// The ring around the board's avatar while it receives an image: how far
/// the image is, or turning while the board verifies, restarts or tests
/// itself. [diameter] is the avatar's; the ring sits just outside it.
class OtaProgressRing extends StatelessWidget {
  const OtaProgressRing({
    super.key,
    required this.activity,
    required this.diameter,
  });

  final OtaBoardActivity activity;
  final double diameter;

  /// How far the ring sits outside the avatar.
  static const gap = 5.0;
  static const stroke = 3.0;

  /// The ring's own box: the avatar plus the gap and the line, all around.
  static double sizeFor(double diameter) => diameter + 2 * (gap + stroke);

  @override
  Widget build(BuildContext context) {
    final size = sizeFor(diameter);
    return IgnorePointer(
      child: SizedBox(
        key: const ValueKey('ota-board-ring'),
        width: size,
        height: size,
        child: Padding(
          padding: const EdgeInsets.all(stroke / 2),
          child: CircularProgressIndicator(
            value: activity.progress,
            strokeWidth: stroke,
            strokeCap: StrokeCap.round,
            color: AppColors.secondary,
            backgroundColor: context.borderColor.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

/// "Placa: recebendo 43 %" — takes the place of the CENTRAL caption while a
/// push runs, so the chip keeps its height.
class OtaBoardCaption extends StatelessWidget {
  const OtaBoardCaption({super.key, required this.activity});

  final OtaBoardActivity activity;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        activity.caption,
        maxLines: 1,
        style: const TextStyle(
          color: AppColors.secondary,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The tablet, drawn beside the CENTRAL while a push runs: the image leaves
/// it and goes to the board over the USB cable. It is on the map only then.
class OtaTabletChip extends StatelessWidget {
  const OtaTabletChip({super.key});

  static const width = 64.0;
  static const circle = 34.0;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        key: const ValueKey('ota-tablet-chip'),
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: circle,
              height: circle,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.surfaceColor,
                border: Border.all(
                  color: AppColors.secondary.withValues(alpha: 0.7),
                  width: 1.2,
                ),
              ),
              child: Icon(Icons.tablet_mac_rounded,
                  size: 17, color: context.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              'TABLET',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
            Text(
              'cabo USB',
              style: TextStyle(
                color: context.textSecondary.withValues(alpha: 0.8),
                fontSize: 7.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `v0.1.0-dev`.
String firmwareTagText(String version) =>
    version.startsWith('v') || version.startsWith('V') ? version : 'v$version';

/// The firmware a unit runs, small, under its name on a Rede map. Nothing
/// at all when the unit never reported one and nothing waits for it. The
/// marker beside it says an image of the unit's family is stored on the
/// board and was NOT delivered: the unit still runs the version shown.
class FirmwareTag extends StatelessWidget {
  const FirmwareTag({super.key, required this.version, this.pending});

  /// What the unit runs; null or empty = never reported.
  final String? version;

  /// The version that waits on the board; null = none.
  final String? pending;

  @override
  Widget build(BuildContext context) {
    final runs = version == null || version!.isEmpty ? null : version!;
    final waits = pending;
    if (runs == null && waits == null) return const SizedBox.shrink();

    return Semantics(
      label: [
        if (runs != null) 'Firmware $runs',
        if (waits != null) otaPendingText(waits),
      ].join(', '),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (runs != null)
            Flexible(
              child: Text(
                firmwareTagText(runs),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          if (waits != null) ...[
            if (runs != null) const SizedBox(width: 3),
            const Icon(
              Icons.inventory_2_outlined,
              key: ValueKey('fw-pending'),
              size: 9,
              color: AppColors.warning,
            ),
          ],
        ],
      ),
    );
  }
}

// ── A unit of a rollout ──────────────────────────────────────────────────────

/// The ring around a unit's avatar while it is being updated: how far its
/// download is, or turning while it verifies, restarts or tests itself.
/// Like the board's ring during a push, it is a drawing of the tablet, in
/// the app's accent colour — never the unit's LED.
class OtaUnitRing extends StatelessWidget {
  const OtaUnitRing({
    super.key,
    required this.activity,
    required this.diameter,
  });

  final OtaUnitActivity activity;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final size = OtaProgressRing.sizeFor(diameter);
    return IgnorePointer(
      child: SizedBox(
        key: const ValueKey('ota-unit-ring'),
        width: size,
        height: size,
        child: Padding(
          padding: const EdgeInsets.all(OtaProgressRing.stroke / 2),
          child: CircularProgressIndicator(
            value: activity.progress,
            strokeWidth: OtaProgressRing.stroke,
            strokeCap: StrokeCap.round,
            color: AppColors.secondary,
            backgroundColor: context.borderColor.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

/// Under the name of a unit of a rollout, in the place of [FirmwareTag] so
/// the chip keeps its height: the phase while it is being updated
/// ("baixando 40 %"), a small "aguardando" marker while it waits ("por
/// último" on the mesh root), the new version once it runs it, a failure
/// marker when it does not.
class OtaUnitTag extends StatelessWidget {
  const OtaUnitTag({super.key, required this.activity, this.version});

  final OtaUnitActivity activity;

  /// What the registry says the unit runs; the rollout's word wins when it
  /// has one.
  final String? version;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final runs = a.version.isNotEmpty ? a.version : (version ?? '');
    final tag = runs.isEmpty ? null : firmwareTagText(runs);

    if (a.updating) {
      return Semantics(
        label: 'Atualizando: ${a.caption}',
        excludeSemantics: true,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            a.caption,
            key: const ValueKey('ota-unit-caption'),
            maxLines: 1,
            style: const TextStyle(
              color: AppColors.secondary,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
    }

    final (IconData icon, Color color, String word, String key) =
        switch (a.state) {
      SafrOtaUnitState.done => (
          Icons.check_circle_rounded,
          AppColors.success,
          '',
          'ota-unit-done',
        ),
      SafrOtaUnitState.failed => (
          Icons.error_rounded,
          AppColors.error,
          'falhou',
          'ota-unit-failed',
        ),
      SafrOtaUnitState.skipped => (
          Icons.remove_circle_outline_rounded,
          context.textSecondary,
          'ignorado',
          'ota-unit-skipped',
        ),
      _ => (
          Icons.hourglass_empty_rounded,
          context.textSecondary,
          a.caption,
          'ota-unit-waiting',
        ),
    };

    return Semantics(
      label: [
        if (tag != null) 'Firmware $runs',
        if (a.state == SafrOtaUnitState.done) 'atualizado' else word,
      ].join(', '),
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tag != null) ...[
              Text(
                tag,
                maxLines: 1,
                style: TextStyle(
                  color: a.state == SafrOtaUnitState.done
                      ? context.textPrimary
                      : context.textSecondary,
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 3),
            ],
            Icon(icon, key: ValueKey(key), size: 9, color: color),
            if (word.isNotEmpty) ...[
              const SizedBox(width: 2),
              Text(
                word,
                maxLines: 1,
                style: TextStyle(
                  color: color,
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
