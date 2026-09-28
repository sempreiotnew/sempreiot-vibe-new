import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../features/access/application/central_access_provider.dart';
import '../../../../features/access/application/user_access_provider.dart';
import '../../../../features/access/domain/entities/saved_central.dart';
import '../../../../features/auth/application/auth_provider.dart';
import '../../../../features/central/application/central_auth_provider.dart';
import '../../../../features/central/application/device_info_provider.dart';
import '../../../../features/central/presentation/screens/device_access_screen.dart';
import '../../../../features/central/presentation/screens/central_installation_screen.dart';
import '../../../../features/central/presentation/screens/device_info_screen.dart';
import '../../../../features/central/presentation/screens/serial_logs_screen.dart';
import '../../../../features/installation/presentation/screens/installations_screen.dart';
import '../../../../features/storage/presentation/screens/storage_screen.dart';
import '../main_tab.dart';

class MainDrawer extends ConsumerWidget {
  const MainDrawer({
    super.key,
    required this.currentTab,
    required this.onTabSelected,
    this.centralId,
  });

  final MainTab currentTab;
  final ValueChanged<MainTab> onTabSelected;

  /// USER mode only: when non-null, the drawer is the restricted menu shown
  /// while viewing that central — reduced navigation, Armazenamento only,
  /// no admin items and no footer.
  final String? centralId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restricted = centralId != null;
    final width = (MediaQuery.of(context).size.width * 0.82).clamp(0.0, 320.0);

    // Restricted mode: header shows the viewed central — the user's local
    // nickname on top, the central's real subId below (mirrors the app bar).
    SavedCentral? saved;
    if (restricted) {
      final matches = ref
          .watch(savedCentralsProvider)
          .where((c) => c.identityId == centralId)
          .toList();
      saved = matches.isNotEmpty ? matches.first : null;
    }

    // Central mode: header shows the central's own name from the "info"
    // metadata (set via FACTORY), not a fixed label.
    final centralName = AppConfig.isCentral
        ? ((ref.watch(deviceInfoProvider).valueOrNull?['name'] as String?) ?? '')
        : '';
    final headerTitle = restricted
        ? ((saved?.name.isNotEmpty ?? false) ? saved!.name : 'Central')
        : AppConfig.isCentral
            ? (centralName.isNotEmpty ? centralName : 'Central SempreIoT')
            : 'Minha conta';
    final userId = restricted
        ? ((saved?.subId.isNotEmpty ?? false) ? saved!.subId : centralId!)
        : AppConfig.isCentral
            ? 'Modo Central'
            : (ref.watch(authNotifierProvider).valueOrNull?.userId ?? '—');
    final initials = restricted
        ? _initials(headerTitle)
        : AppConfig.isCentral
            ? 'CT'
            : _initials(userId);

    return SizedBox(
      width: width,
      child: Drawer(
        backgroundColor: context.bgColor,
        shape: const RoundedRectangleBorder(),
        child: Column(
          children: [
            _DrawerHeader(initials: initials, userId: userId, title: headerTitle),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  const _SectionLabel('NAVEGAÇÃO'),
                  const SizedBox(height: 4),
                  ...(restricted ? MainTab.centralDetailTabs : MainTab.tabs)
                      .map(
                        (tab) => _NavItem(
                          tab: tab,
                          active: tab == currentTab,
                          onTap: () {
                            Navigator.pop(context);
                            onTabSelected(tab);
                          },
                        ),
                      ),
                  const SizedBox(height: 16),
                  const _SectionLabel('SISTEMA'),
                  const SizedBox(height: 4),
                  if (restricted)
                    _DrawerItem(
                      icon: Icons.storage_rounded,
                      label: 'Armazenamento',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder: (_, __, ___) =>
                                StorageScreen(centralId: centralId),
                            transitionsBuilder: (_, anim, __, child) =>
                                FadeTransition(opacity: anim, child: child),
                            transitionDuration:
                                const Duration(milliseconds: 300),
                          ),
                        );
                      },
                    )
                  else ...[
                    if (AppConfig.isCentral) ...[
                      // Which installation this central belongs to: imports
                      // SYSTEM_ID + SAFR key from the installer phone's QR.
                      _DrawerItem(
                        icon: Icons.hub_rounded,
                        label: 'Instalação',
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const CentralInstallationScreen(),
                            ),
                          );
                        },
                      ),
                      _DrawerItem(
                        icon: Icons.storage_rounded,
                        label: 'Armazenamento',
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.of(context).push(
                            PageRouteBuilder(
                              pageBuilder: (_, __, ___) =>
                                  const StorageScreen(),
                              transitionsBuilder: (_, anim, __, child) =>
                                  FadeTransition(opacity: anim, child: child),
                              transitionDuration:
                                  const Duration(milliseconds: 300),
                            ),
                          );
                        },
                      ),
                      _DrawerItem(
                        icon: Icons.info_outline_rounded,
                        label: 'Informações',
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const DeviceInfoScreen(),
                            ),
                          );
                        },
                      ),
                      _AcessosDrawerItem(onTap: () {
                        Navigator.pop(context);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DeviceAccessScreen(),
                          ),
                        );
                      }),
                      // Technical/debug view of the raw SAFR packet stream.
                      _DrawerItem(
                        icon: Icons.receipt_long_rounded,
                        label: 'Logs seriais',
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.of(context).push(
                            PageRouteBuilder(
                              pageBuilder: (_, __, ___) =>
                                  const SerialLogsScreen(),
                              transitionsBuilder: (_, anim, __, child) =>
                                  FadeTransition(opacity: anim, child: child),
                              transitionDuration:
                                  const Duration(milliseconds: 300),
                            ),
                          );
                        },
                      ),
                    ] else if (!kIsWeb)
                      // SoftAP provisioning can't work from a browser: https
                      // pages can't call http://192.168.4.1 (mixed content)
                      // and the laptop loses internet on the device's AP.
                      _DrawerItem(
                        icon: Icons.settings_input_antenna_rounded,
                        label: 'Configurar Dispositivo',
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const InstallationsScreen(),
                            ),
                          );
                        },
                      ),
                    const _ThemeToggleItem(),
                    const _DrawerItem(
                      icon: Icons.info_outline_rounded,
                      label: 'Sobre',
                    ),
                  ],
                ],
              ),
            ),
            if (!restricted) const _DrawerFooter(),
          ],
        ),
      ),
    );
  }

  String _initials(String userId) {
    final clean = userId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (clean.isEmpty) return '?';
    return clean.substring(0, clean.length.clamp(0, 2)).toUpperCase();
  }
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    required this.initials,
    required this.userId,
    required this.title,
  });

  final String initials;
  final String userId;
  final String title;

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, topPad + 24, 20, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF152F55), Color(0xFF0D1B2E)],
        ),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1F2937), width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.primary, Color(0xFF2E6DA4)],
              ),
              border: Border.all(
                color: AppColors.secondary.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: const TextStyle(
                color: AppColors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimaryDark,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            userId,
            style: const TextStyle(
              color: AppColors.textSecondaryDark,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          color: context.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final MainTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.secondary : context.textSecondary;

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: active
            ? AppColors.secondary.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(tab.icon, size: 19, color: color),
                const SizedBox(width: 14),
                Text(
                  tab.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (active) ...[
                  const Spacer(),
                  const SizedBox(
                    width: 6,
                    height: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.secondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeToggleItem extends ConsumerWidget {
  const _ThemeToggleItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(themeProvider) == ThemeMode.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => ref.read(themeProvider.notifier).toggle(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  size: 19,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    isDark ? 'Tema Claro' : 'Tema Escuro',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  width: 40,
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    color: isDark
                        ? context.borderColor
                        : AppColors.secondary.withValues(alpha: 0.85),
                  ),
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    alignment:
                        isDark ? Alignment.centerLeft : Alignment.centerRight,
                    child: Container(
                      width: 18,
                      height: 18,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: const BoxDecoration(
                        color: AppColors.white,
                        shape: BoxShape.circle,
                      ),
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

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(icon, size: 19, color: context.textSecondary),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 14,
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

/// Acessos item with a live pending-request badge for central mode.
class _AcessosDrawerItem extends ConsumerWidget {
  const _AcessosDrawerItem({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingRequestCountProvider);

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(
                  Icons.manage_accounts_rounded,
                  size: 19,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Acessos',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (count > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.warning,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
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

class _DrawerFooter extends ConsumerWidget {
  const _DrawerFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: context.borderColor, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: AppColors.error.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                Navigator.pop(context);
                if (AppConfig.isCentral) {
                  ref.read(centralAuthProvider.notifier).reset();
                } else {
                  ref.read(authNotifierProvider.notifier).signOut();
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      AppConfig.isCentral
                          ? Icons.lock_outline_rounded
                          : Icons.logout_rounded,
                      size: 18,
                      color: AppColors.error,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      AppConfig.isCentral
                          ? 'Bloquear Central'
                          : 'Sair da conta',
                      style: const TextStyle(
                        color: AppColors.error,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'v0.1.4',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
