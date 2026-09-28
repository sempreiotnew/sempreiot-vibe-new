import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../features/access/application/user_access_provider.dart';
import '../../../../features/access/domain/entities/saved_central.dart';
import '../../../../features/access/presentation/sheets/rename_central_sheet.dart';
import '../../../../features/auth/application/auth_provider.dart';
import '../../../../features/central/application/central_auth_provider.dart';
import '../../../../features/central/application/device_info_provider.dart';

class MainAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const MainAppBar({
    super.key,
    required this.onMenuTap,
    this.isLocked = false,
    this.onBack,
    this.centralId,
  });

  final VoidCallback? onMenuTap;
  final bool isLocked;

  /// When non-null, replaces the hamburger menu with a back arrow.
  final VoidCallback? onBack;

  /// USER mode only: the central being viewed — its name replaces the
  /// app branding in the title.
  final String? centralId;

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topPad = MediaQuery.of(context).padding.top;

    return Container(
      height: preferredSize.height + topPad,
      padding: EdgeInsets.only(top: topPad),
      decoration: BoxDecoration(
        color: context.bgColor,
        border: Border(
          bottom: BorderSide(
            color: context.borderColor.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            AnimatedOpacity(
              opacity: isLocked ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              child: IgnorePointer(
                ignoring: isLocked,
                child: onBack != null
                    ? _BarIconButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        onTap: onBack!,
                        tooltip: 'Voltar',
                      )
                    : _BarIconButton(
                        icon: Icons.menu_rounded,
                        onTap: onMenuTap ?? () {},
                        tooltip: 'Menu',
                      ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: _Branding(centralId: centralId)),
            if (AppConfig.isCentral) ...[
              const SizedBox(width: 2),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) {
                  final scale = Tween<double>(begin: 0.65, end: 1.0).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutBack,
                    ),
                  );
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: scale, child: child),
                  );
                },
                child: isLocked
                    ? Tooltip(
                        key: const ValueKey('lk_ind'),
                        message: 'Toque na tela para desbloquear',
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            Icons.lock_rounded,
                            color:
                                context.textSecondary.withValues(alpha: 0.5),
                            size: 18,
                          ),
                        ),
                      )
                    : _LockButton(
                        key: const ValueKey('lk_btn'),
                        onTap: () =>
                            ref.read(centralAuthProvider.notifier).reset(),
                      ),
              ),
            ],
            // Central-detail view: back arrow owns the left slot, so the
            // restricted drawer's menu button lives on the right instead.
            if (centralId != null)
              _BarIconButton(
                icon: Icons.menu_rounded,
                onTap: onMenuTap ?? () {},
                tooltip: 'Menu',
              ),
            const SizedBox(width: 10),
            AnimatedOpacity(
              opacity: isLocked ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              child: IgnorePointer(
                ignoring: isLocked,
                child: const _UserAvatar(),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class _Branding extends ConsumerWidget {
  const _Branding({this.centralId});

  final String? centralId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (title, subtitle) = _resolveTitle(ref);
    // USER mode viewing a central: tapping the name opens the (local)
    // rename sheet — the nickname belongs to this user only.
    final renameTarget = _renameTarget(ref);

    return GestureDetector(
      onTap: renameTarget != null
          ? () => showRenameCentralSheet(context, renameTarget)
          : null,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.primary, AppColors.secondary],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.sensors_rounded,
              color: AppColors.white,
              size: 15,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    if (renameTarget != null) ...[
                      const SizedBox(width: 5),
                      Icon(
                        Icons.edit_rounded,
                        size: 11,
                        color: context.textSecondary.withValues(alpha: 0.6),
                      ),
                    ],
                  ],
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  SavedCentral? _renameTarget(WidgetRef ref) {
    if (AppConfig.isCentral || centralId == null) return null;
    final matches = ref
        .watch(savedCentralsProvider)
        .where((c) => c.identityId == centralId)
        .toList();
    return matches.isNotEmpty ? matches.first : null;
  }

  /// CENTRAL mode: the device's own name from the "info" metadata (set via
  /// FACTORY JSON). USER mode viewing a central: the saved central's name.
  /// USER mode home: app branding.
  (String, String) _resolveTitle(WidgetRef ref) {
    if (AppConfig.isCentral) {
      final name =
          ref.watch(deviceInfoProvider).valueOrNull?['name'] as String? ?? '';
      return (name.isNotEmpty ? name : 'Central', 'Modo Central');
    }
    if (centralId != null) {
      final centrals = ref.watch(savedCentralsProvider);
      final matches =
          centrals.where((c) => c.identityId == centralId).toList();
      final name = matches.isNotEmpty ? matches.first.name : '';
      // Subtitle shows the subId — the central's real identity — so the
      // user's personal nickname above it can never cause ambiguity.
      final subId = matches.isNotEmpty ? matches.first.subId : '';
      return (
        name.isNotEmpty ? name : 'Central',
        subId.isNotEmpty ? subId : 'Central conectada',
      );
    }
    return ('SempreIoT', 'Painel de controle');
  }
}

class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Icon(icon, color: context.textSecondary, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockButton extends StatelessWidget {
  const _LockButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Bloquear Central',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Icon(
                Icons.lock_outline_rounded,
                color: context.textSecondary,
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UserAvatar extends ConsumerWidget {
  const _UserAvatar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initials = AppConfig.isCentral
        ? 'CT'
        : _initials(ref.watch(authNotifierProvider).valueOrNull?.userId ?? '');

    return GestureDetector(
      onTap: () => _showProfile(context, ref, initials),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, Color(0xFF2E6DA4)],
          ),
          border: Border.all(
            color: AppColors.secondary.withValues(alpha: 0.35),
            width: 1.5,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          initials,
          style: const TextStyle(
            color: AppColors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ),
      ),
    );
  }

  String _initials(String userId) {
    final clean = userId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (clean.isEmpty) return '?';
    return clean.substring(0, clean.length.clamp(0, 2)).toUpperCase();
  }

  void _showProfile(BuildContext context, WidgetRef ref, String initials) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => UncontrolledProviderScope(
        container: ProviderScope.containerOf(context),
        child: _ProfileSheet(initials: initials),
      ),
    );
  }
}

class _ProfileSheet extends ConsumerWidget {
  const _ProfileSheet({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = AppConfig.isCentral
        ? 'Modo Central'
        : (ref.watch(authNotifierProvider).valueOrNull?.userId ?? '—');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 24),
            decoration: BoxDecoration(
              color: context.borderColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          _AvatarCircle(initials: initials, size: 64, fontSize: 22),
          const SizedBox(height: 16),
          Text(
            AppConfig.isCentral ? 'Central SempreIoT' : 'Minha conta',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            userId,
            style: TextStyle(color: context.textSecondary, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 28),
          if (!AppConfig.isCentral)
            _ActionButton(
              icon: Icons.logout_rounded,
              label: 'Sair da conta',
              color: AppColors.error,
              onTap: () {
                Navigator.pop(context);
                ref.read(authNotifierProvider.notifier).signOut();
              },
            ),
        ],
      ),
    );
  }
}

class _AvatarCircle extends StatelessWidget {
  const _AvatarCircle({
    required this.initials,
    required this.size,
    required this.fontSize,
  });

  final String initials;
  final double size;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, Color(0xFF2E6DA4)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: AppColors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
            child: Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
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
