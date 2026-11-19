import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_ext.dart';

/// What a notice says, which gives it its accent colour and its icon.
enum AppNoticeKind {
  /// Something was done ("Nome atualizado.").
  success(AppColors.success, Icons.check_rounded),

  /// Something worth knowing, neither good nor bad.
  info(AppColors.secondary, Icons.info_outline_rounded),

  /// Something went to the clipboard.
  copied(AppColors.secondary, Icons.copy_rounded),

  /// It was done, with a catch — or not done, and nothing is broken.
  warning(AppColors.warning, Icons.priority_high_rounded),

  /// It failed.
  error(AppColors.error, Icons.close_rounded);

  const AppNoticeKind(this.color, this.icon);
  final Color color;
  final IconData icon;
}

/// The app's one notice (2026-11-19): the short message that answers an
/// action — saved, copied, refused. A small card that floats over the
/// bottom of the screen in the theme's own surface, with the accent of what
/// it says (green done, blue information, amber attention, red failure) on
/// its icon, its edge and its glow. It replaces the plain Material snackbar
/// everywhere; never build a `SnackBar` by hand.
///
/// It still travels as a [SnackBar] — one at a time, queued, swiped away,
/// announced to a screen reader, outliving the sheet that showed it — but
/// nothing of the Material bar is drawn.
SnackBar appNotice(
  String message, {
  AppNoticeKind kind = AppNoticeKind.info,
  Duration? duration,
}) {
  return SnackBar(
    content: _AppNoticeCard(message: message, kind: kind),
    behavior: SnackBarBehavior.floating,
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    dismissDirection: DismissDirection.horizontal,
    // The card's shadow and glow reach past its box.
    clipBehavior: Clip.none,
    // A failure or a catch is read, not glanced at.
    duration: duration ??
        switch (kind) {
          AppNoticeKind.copied => const Duration(seconds: 2),
          AppNoticeKind.success ||
          AppNoticeKind.info =>
            const Duration(seconds: 3),
          AppNoticeKind.warning ||
          AppNoticeKind.error =>
            const Duration(seconds: 6),
        },
  );
}

/// Shows [message] now, in place of any notice still on screen.
void showAppNotice(
  BuildContext context,
  String message, {
  AppNoticeKind kind = AppNoticeKind.info,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(appNotice(message, kind: kind, duration: duration));
}

class _AppNoticeCard extends StatelessWidget {
  const _AppNoticeCard({required this.message, required this.kind});

  final String message;
  final AppNoticeKind kind;

  /// On a tablet or the web the card keeps a phone's width, centred.
  static const _maxWidth = 460.0;

  @override
  Widget build(BuildContext context) {
    final accent = kind.color;
    final dark = context.isDark;
    final base = dark ? AppColors.surfaceDark : AppColors.white;
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color.alphaBlend(
                accent.withValues(alpha: dark ? 0.10 : 0.06), base),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.45 : 0.14),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: accent.withValues(alpha: dark ? 0.22 : 0.16),
                blurRadius: 18,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 16, 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.18),
                    border: Border.all(color: accent.withValues(alpha: 0.55)),
                  ),
                  child: Icon(kind.icon, size: 16, color: accent),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    message,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
