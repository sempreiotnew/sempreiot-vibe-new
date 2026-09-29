import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_push_state.dart';
import '../screens/firmware_update_screen.dart';
import 'firmware_update_widgets.dart';

// What the Rede screens (map and 3D) show of a firmware push. They draw
// what `otaPushProvider` says; nothing here decides anything about the push.
//
// None of this is a unit's LED. The LED mirror (device_led_provider.dart)
// keeps its own colours and patterns; the ring, the caption and the banner
// are drawings of the tablet, in the app's accent colour.

/// The strip at the top of the Rede screens: while a push runs, what is
/// going where and how far; after it, the outcome in one line until the
/// operator closes it or starts another push. A tap opens "Atualização de
/// firmware". Takes no room when there is nothing to say.
class OtaRedeBanner extends ConsumerWidget {
  const OtaRedeBanner({super.key});

  static DateTime _keyOf(OtaPushState s) =>
      s.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(otaPushViewProvider);
    final dismissed = ref.watch(otaBannerDismissedProvider);
    final report = otaPushReport(state);
    if (report == null) return const SizedBox.shrink();
    if (!report.running && dismissed == _keyOf(state)) {
      return const SizedBox.shrink();
    }

    final color = otaToneColor(context, report.tone);
    final sending = state.phase == OtaPushPhase.sending;
    final tail = report.lineTail;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        key: const ValueKey('ota-rede-banner'),
        color: Color.alphaBlend(
            color.withValues(alpha: 0.10), context.surfaceColor),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withValues(alpha: 0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const FirmwareUpdateScreen()),
          ),
          child: Semantics(
            container: true,
            label: report.fullLine,
            hint: 'Abrir a atualização de firmware',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                  child: Row(
                    children: [
                      Icon(otaReportIcon(report.kind), size: 18, color: color),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Text(
                            report.line,
                            // A phone is narrow: a third line rather
                            // than a sentence without its end.
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                          ),
                        ),
                      ),
                      // How far it is: on its own, never cut off.
                      if (tail != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          tail,
                          maxLines: 1,
                          style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                      if (report.running)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.chevron_right_rounded,
                              size: 20, color: context.textSecondary),
                        )
                      else
                        IconButton(
                          tooltip: 'Fechar aviso',
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            fixedSize: const Size(32, 32),
                            minimumSize: const Size(32, 32),
                            padding: EdgeInsets.zero,
                          ),
                          icon: Icon(Icons.close_rounded,
                              size: 18, color: context.textSecondary),
                          onPressed: () => ref
                              .read(otaBannerDismissedProvider.notifier)
                              .state = _keyOf(state),
                        ),
                    ],
                  ),
                ),
                if (sending)
                  LinearProgressIndicator(
                    value: state.progress,
                    minHeight: 2.5,
                    backgroundColor: context.borderColor.withValues(alpha: 0.5),
                    color: AppColors.secondary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
