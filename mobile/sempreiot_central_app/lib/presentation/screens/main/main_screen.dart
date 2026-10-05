import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_ext.dart';
import '../../../features/access/application/user_access_provider.dart';
import '../../../features/access/domain/entities/saved_central.dart';
import '../../../features/auth/application/auth_provider.dart';
import '../../../features/central/application/central_auth_provider.dart';
import '../../../features/central/application/central_mirror_publisher.dart';
import '../../../features/central/application/firmware_release_provider.dart';
import '../../../features/central/application/central_mirror_viewer.dart';
import '../../../features/central/application/central_status_publisher.dart';
import '../../../features/central/application/device_led_provider.dart';
import '../../../features/central/application/central_storage_publisher.dart';
import '../../../features/iot/application/presence_provider.dart';
import '../../../features/centrais/presentation/screens/centrais_list_screen.dart';
import '../../../core/connectivity/network_status_provider.dart';
import '../../widgets/iot_network_animation.dart';
import '../auth/login_screen.dart';
import '../../../features/central/presentation/screens/devices_screen.dart';
import '../../../features/central/presentation/screens/topology_screen.dart';
import '../../../features/central/presentation/widgets/latched_alarm_banner.dart';
import '../../../features/central/presentation/widgets/mirror_status_strip.dart';
import '../../../features/central/presentation/widgets/remote_alarm_banner.dart';
import 'main_tab.dart';
import 'status_panel_style_provider.dart';
import 'widgets/comm_status_gadget.dart';
import 'widgets/dot_matrix_display.dart';
import 'widgets/main_app_bar.dart';
import 'widgets/main_bottom_nav.dart';
import 'widgets/main_drawer.dart';
import '../../../features/central/application/safr_ingest_provider.dart';
import '../../../features/central/application/central_installation_provider.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key, this.centralId});

  /// When non-null (USER mode only), identifies the central being viewed.
  /// The principal tab will show that central's dashboard.
  final String? centralId;

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  MainTab _currentTab = MainTab.principal;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _pinOverlayVisible = AppConfig.isCentral;
  bool _kickedOut = false;

  /// USER mode inside a central: which central the mirror follows. Held
  /// here because `ref` is gone by the time [dispose] runs.
  StateController<String?>? _viewed;

  @override
  void initState() {
    super.initState();
    final id = widget.centralId;
    if (AppConfig.isCentral || id == null) return;
    final viewed = ref.read(viewedCentralProvider.notifier);
    _viewed = viewed;
    // Deferred: a provider cannot change while widgets build.
    Future.microtask(() {
      if (mounted) viewed.state = id;
    });
  }

  @override
  void dispose() {
    final viewed = _viewed;
    final id = widget.centralId;
    if (viewed != null) {
      // Leaving the central: the mirror stops pinging and unsubscribes, and
      // the central stops streaming once nobody else watches.
      Future.microtask(() {
        if (viewed.state == id) viewed.state = null;
      });
    }
    super.dispose();
  }

  void _handleTabChange(MainTab tab) {
    // In USER mode, "Centrais" tab opens the list screen instead of switching tabs.
    if (!AppConfig.isCentral && tab == MainTab.centrais) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CentralsListScreen()),
      );
      return;
    }
    setState(() => _currentTab = tab);
  }

  @override
  Widget build(BuildContext context) {
    final isLocked = AppConfig.isCentral &&
        ref.watch(centralAuthProvider) is! CentralAuthenticated;

    // Keeps the retained presence and storage payloads fresh so users
    // viewing this central see its real status. No-op in USER mode.
    if (AppConfig.isCentral) {
      ref.watch(centralStatusPublisherProvider);
      ref.watch(centralStoragePublisherProvider);
      // The mirror: the held alarms always, the live map while a user's
      // phone is watching (docs/cloud/central-mirror.md).
      ref.watch(centralMirrorPublisherProvider);
      // Firmware published on the Internet: the catalogs, and the newest
      // images downloaded into "Firmwares no tablet" (ota-internet-plan.md).
      ref.watch(firmwareReleaseSyncProvider);
      // The on-screen LEDs must hear every frame from the start, whatever
      // tab is open (read, not watch: its ticks must not rebuild this screen).
      ref.read(deviceLedProvider);
    }

    ref.listen(centralAuthProvider, (prev, next) {
      if (next is CentralAuthenticated && _pinOverlayVisible) {
        setState(() => _pinOverlayVisible = false);
      }
      // Only hide the PIN overlay on explicit lock (prev was Authenticated),
      // not after a failed attempt (prev was CentralPinError → reset()).
      if (next is CentralUnauthenticated && prev is! CentralPinError) {
        setState(() {
          _pinOverlayVisible = false;
          _currentTab = MainTab.principal;
        });
      }
    });

    // USER mode viewing a central: the moment access stops being ACCEPTED
    // (BLOCKED arrives over MQTT, or a backend sync flips the status), kick
    // the user out of the central's screens immediately. The backend has
    // already detached the IoT policy at that point — this closes the UI.
    if (!AppConfig.isCentral && widget.centralId != null) {
      ref.listen(savedCentralsProvider, (_, centrals) {
        if (_kickedOut || !mounted) return;
        SavedCentral? entry;
        for (final c in centrals) {
          if (c.identityId == widget.centralId) {
            entry = c;
            break;
          }
        }
        if (entry != null && entry.status == 'ACCEPTED') return;
        _kickedOut = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Seu acesso a esta central foi revogado.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
        // Pops the central dashboard and anything pushed above it.
        Navigator.of(context).popUntil((route) => route.isFirst);
      });
    }

    if (!AppConfig.isCentral) {
      // Keeps the mirror alive and following [viewedCentralProvider]: it
      // starts watching the moment a central is opened, whatever the tab,
      // and stops the moment the user leaves it (see centralMirrorProvider).
      ref.listen(centralMirrorProvider.select((v) => v.connected), (_, __) {});
      ref.listen(authNotifierProvider, (_, next) {
        if (next is AsyncData && next.value == null) {
          Navigator.of(context).pushAndRemoveUntil(
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => const LoginScreen(),
              transitionsBuilder: (_, animation, __, child) =>
                  FadeTransition(opacity: animation, child: child),
              transitionDuration: const Duration(milliseconds: 350),
            ),
            (_) => false,
          );
        }
      });
    }

    return Builder(
      builder: (context) {
        final isCentralDetail = widget.centralId != null;

        final scaffold = Scaffold(
          key: _scaffoldKey,
          backgroundColor: context.bgColor,
          appBar: MainAppBar(
            isLocked: isLocked,
            centralId: widget.centralId,
            onMenuTap: () => _scaffoldKey.currentState?.openDrawer(),
            // Show back arrow when drilling into a specific central.
            onBack: isCentralDetail ? () => Navigator.of(context).pop() : null,
          ),
          drawer: isLocked
              ? null
              : MainDrawer(
                  currentTab: _currentTab,
                  onTabSelected: _handleTabChange,
                  centralId: widget.centralId,
                ),
          body: _TabBody(currentTab: _currentTab, centralId: widget.centralId),
          bottomNavigationBar: AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeInOutCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: SizeTransition(
                  sizeFactor: curved,
                  axisAlignment: -1,
                  child: child,
                ),
              );
            },
            // Hidden while locked. Inside a central (USER mode) it is the
            // tablet's own bar: Principal · Dispositivos · Rede.
            child: isLocked
                ? const SizedBox.shrink(key: ValueKey('nav_hidden'))
                : MainBottomNav(
                    key: const ValueKey('nav_unlocked'),
                    tabs: isCentralDetail ? MainTab.centralDetailTabs : null,
                    currentTab: _currentTab,
                    onTabChanged: _handleTabChange,
                  ),
          ),
        );

        return Stack(
          children: [
            scaffold,
            // Touch capture overlay — when locked, any tap shows the PIN
            if (isLocked)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _pinOverlayVisible = true),
                  child: const SizedBox.expand(),
                ),
              ),
            // PIN overlay with fade-in/out
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child,
              ),
              child: _pinOverlayVisible
                  ? _PinOverlay(
                      key: const ValueKey('pin_overlay'),
                      onDismiss: () =>
                          setState(() => _pinOverlayVisible = false),
                    )
                  : const SizedBox.shrink(key: ValueKey('pin_empty')),
            ),
          ],
        );
      },
    );
  }
}

// ── Tab body with fade transitions ───────────────────────────────────────────

class _TabBody extends StatelessWidget {
  const _TabBody({required this.currentTab, this.centralId});

  final MainTab currentTab;
  final String? centralId;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: KeyedSubtree(
        key: ValueKey(currentTab),
        child: switch (currentTab) {
          MainTab.principal => _PrincipalTab(centralId: centralId),
          MainTab.central => const _PlaceholderTab(
              icon: Icons.sensors_rounded,
              title: 'Central',
              subtitle: 'Configurações e detalhes da central.',
            ),
          MainTab.centrais => const _PlaceholderTab(
              icon: Icons.hub_rounded,
              title: 'Centrais',
              subtitle: 'Lista de centrais cadastradas.',
            ),
          // On the tablet: its own registry. On a user's phone inside a
          // central: the same screens, fed by that central's mirror.
          MainTab.devices => AppConfig.isCentral
              ? const DevicesScreen()
              : centralId != null
                  ? _Mirrored(
                      centralId: centralId!, child: const DevicesScreen())
                  : const _PlaceholderTab(
                      icon: Icons.devices_rounded,
                      title: 'Dispositivos',
                      subtitle: 'Nenhum dispositivo conectado ainda.',
                    ),
          MainTab.rede => AppConfig.isCentral || centralId == null
              ? const TopologyScreen(embedded: true)
              : _Mirrored(
                  centralId: centralId!,
                  child: const TopologyScreen(embedded: true),
                ),
        },
      ),
    );
  }
}

/// A tablet screen on a user's phone, drawn from the viewed central's
/// mirror. Nothing is built until the mirror follows this central, so the
/// screen never reads this phone's own (empty) registry or serial port.
class _Mirrored extends ConsumerWidget {
  const _Mirrored({required this.centralId, required this.child});

  final String centralId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(viewedCentralProvider) != centralId) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        const MirrorStatusStrip(),
        Expanded(child: child),
      ],
    );
  }
}

// ── Principal tab — Dashboard ────────────────────────────────────────────────

class _PrincipalTab extends ConsumerWidget {
  const _PrincipalTab({this.centralId});

  final String? centralId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Show the central dashboard when in CENTRAL mode OR when a specific
    // central has been selected from the centrais list in USER mode.
    if (AppConfig.isCentral || centralId != null) {
      return _CentralDashboard(centralId: centralId);
    }
    return _AppDashboard(networkStatus: ref.watch(networkStatusProvider));
  }
}

// ── Central dashboard ────────────────────────────────────────────────────────

class _CentralDashboard extends ConsumerWidget {
  const _CentralDashboard({this.centralId});

  /// Non-null only in USER mode: the central being viewed. All status shown
  /// then comes from what that central publishes over MQTT — never from the
  /// phone's own connectivity.
  final String? centralId;

  // Placeholder counts — wire to real providers when backend is ready.
  static const _totalDevices = 0;
  static const _totalOnline = 0;
  static const _totalOffline = 0;
  static const _totalAlertas = 0;
  static const _totalOk = 0;
  static const _totalAlarme = 0;

  (Color, String) _centralStatus(WidgetRef ref) {
    if (centralId == null) {
      return switch (ref.watch(networkStatusProvider)) {
        NetworkStatus.online => (AppColors.success, 'Operacional'),
        NetworkStatus.limited => (AppColors.warning, 'Acesso limitado'),
        NetworkStatus.offline => (AppColors.error, 'Sem conexão'),
      };
    }
    return switch (ref.watch(presenceStatusProvider(centralId!))) {
      PresenceStatus.online => (AppColors.success, 'Operacional'),
      PresenceStatus.offline => (AppColors.error, 'Sem conexão'),
      PresenceStatus.unknown => (AppColors.warning, 'Verificando…'),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (statusColor, statusLabel) = _centralStatus(ref);
    // USER mode with the central offline: the dashboard stays visible but
    // greyed out and untouchable — there is nothing to act on remotely.
    final offline = centralId != null &&
        ref.watch(presenceStatusProvider(centralId!)) == PresenceStatus.offline;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The tablet reads its own latches; a user's phone reads the
          // central's retained alarm list (no reset from a phone).
          if (centralId == null)
            const LatchedAlarmBanner()
          else
            RemoteAlarmBanner(identityId: centralId!),
          if (centralId == null) const _ForeignSystemBanner(),
          _CentralStatusSection(color: statusColor, label: statusLabel),
          const SizedBox(height: 10),
          _OfflineDim(
            dimmed: offline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel('DISPOSITIVOS'),
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.devices_rounded,
                        label: 'Total Dispositivos',
                        value: _totalDevices,
                        accent: AppColors.secondary,
                        compact: true,
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.sensors_rounded,
                        label: 'Dispositivos Online',
                        value: _totalOnline,
                        accent: AppColors.success,
                        compact: true,
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.sensors_off_rounded,
                        label: 'Dispositivos Offline',
                        value: _totalOffline,
                        accent: AppColors.error,
                        compact: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const _SectionLabel('EVENTOS'),
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.check_circle_rounded,
                        label: 'OK',
                        value: _totalOk,
                        accent: AppColors.success,
                        compact: true,
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.notifications_rounded,
                        label: 'Alertas',
                        value: _totalAlertas,
                        accent: AppColors.warning,
                        compact: true,
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.local_fire_department_rounded,
                        label: 'Alarmes',
                        value: _totalAlarme,
                        accent: AppColors.error,
                        compact: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const _SectionLabel('COMUNICAÇÃO'),
                const SizedBox(height: 6),
                centralId == null
                    ? const CentralCommGadget()
                    : UserCentralCommGadget(identityId: centralId!),
                const SizedBox(height: 6),
                const _SectionLabel('BATERIA / TEMPERATURA'),
                const SizedBox(height: 6),
                const _GadgetRow(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Greys out and disables a subtree — used in USER mode when the viewed
/// central is offline: everything stays readable but desaturated, slightly
/// faded and non-interactive.
/// "A placa pertence a outra instalação": frames arrive with a SYSTEM_ID that
/// is not the imported one (lifecycle §7). Either the board was provisioned
/// for another site or the wrong share was imported on this tablet.
class _ForeignSystemBanner extends ConsumerWidget {
  const _ForeignSystemBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foreign = ref.watch(foreignSystemIdProvider);
    if (foreign == null) return const SizedBox.shrink();
    final ours = ref.watch(safrIdentityProvider);
    String hex(int v) =>
        '0x${v.toRadixString(16).padLeft(4, '0').toUpperCase()}';
    final oursLabel = ours.isDev ? 'nenhuma (bancada)' : hex(ours.systemId);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.hub_outlined, color: AppColors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'A placa pertence a outra instalação (${hex(foreign)}); a '
              'vinculada nesta central é $oursLabel. Vincule a instalação '
              'certa em Instalação, ou reconfigure a placa.',
              style: TextStyle(color: context.textPrimary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _OfflineDim extends StatelessWidget {
  const _OfflineDim({required this.dimmed, required this.child});

  final bool dimmed;
  final Widget child;

  static const _grayscale = ColorFilter.matrix(<double>[
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: dimmed,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: dimmed ? 0.45 : 1.0,
        child: dimmed
            ? ColorFiltered(colorFilter: _grayscale, child: child)
            : child,
      ),
    );
  }
}

// ── App dashboard (non-Central) ──────────────────────────────────────────────

class _AppDashboard extends StatelessWidget {
  const _AppDashboard({required this.networkStatus});

  final NetworkStatus networkStatus;

  // Placeholder counts — wire to real providers when backend is ready.
  static const _totalCentrals = 0;
  static const _totalDevices = 0;
  static const _totalAlertas = 0;
  static const _totalOk = 0;
  static const _totalAlarme = 0;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AppStatusCard(networkStatus: networkStatus),
          const SizedBox(height: 12),
          const _SectionLabel('REDE'),
          const SizedBox(height: 8),
          _MetricCard(
            icon: Icons.sensors_rounded,
            label: 'Total Centrais',
            value: _totalCentrals,
            accent: AppColors.secondary,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CentralsListScreen()),
            ),
          ),
          const SizedBox(height: 8),
          const _MetricCard(
            icon: Icons.devices_rounded,
            label: 'Total Dispositivos',
            value: _totalDevices,
            accent: AppColors.secondary,
          ),
          const SizedBox(height: 8),
          const _SectionLabel('EVENTOS'),
          const SizedBox(height: 8),
          const Row(
            children: [
              Expanded(
                child: _MetricCard(
                  icon: Icons.check_circle_rounded,
                  label: 'OK',
                  value: _totalOk,
                  accent: AppColors.success,
                  compact: true,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  icon: Icons.notifications_rounded,
                  label: 'Alertas',
                  value: _totalAlertas,
                  accent: AppColors.warning,
                  compact: true,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _MetricCard(
                  icon: Icons.local_fire_department_rounded,
                  label: 'Alarmes',
                  value: _totalAlarme,
                  accent: AppColors.error,
                  compact: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppStatusCard extends StatelessWidget {
  const _AppStatusCard({required this.networkStatus});

  final NetworkStatus networkStatus;

  @override
  Widget build(BuildContext context) {
    final (statusColor, statusLabel) = switch (networkStatus) {
      NetworkStatus.online => (AppColors.success, 'Conectado'),
      NetworkStatus.limited => (AppColors.warning, 'Acesso limitado'),
      NetworkStatus.offline => (AppColors.error, 'Sem conexão'),
    };

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.primary, AppColors.secondary],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.sensors_rounded,
              color: AppColors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SempreIoT',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          _PulsingStatusDot(
              color: statusColor,
              active: networkStatus == NetworkStatus.online),
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
      padding: const EdgeInsets.only(left: 2),
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

/// "Status da Central" with a persisted style switch: the default card or a
/// retro digital panel like the segment displays on old fire alarm centrals.
class _CentralStatusSection extends ConsumerWidget {
  const _CentralStatusSection({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arcade = ref.watch(statusPanelArcadeProvider);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1,
          child: child,
        ),
      ),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: arcade
          ? _ArcadeStatusPanel(
              key: const ValueKey('status_arcade'),
              color: color,
              label: label,
            )
          : _CentralStatusCard(
              key: const ValueKey('status_card'),
              color: color,
              label: label,
            ),
    );
  }
}

/// Compact switch that flips the status panel style. Sized down so it fits
/// inside both card variants without stretching them.
class _PanelStyleSwitch extends ConsumerWidget {
  const _PanelStyleSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arcade = ref.watch(statusPanelArcadeProvider);

    return Tooltip(
      message: arcade ? 'Painel clássico' : 'Painel digital',
      child: SizedBox(
        width: 38,
        height: 24,
        child: FittedBox(
          fit: BoxFit.contain,
          child: Switch(
            value: arcade,
            activeTrackColor: AppColors.success.withValues(alpha: 0.4),
            thumbColor: WidgetStatePropertyAll(
              arcade ? AppColors.success : null,
            ),
            onChanged: (_) =>
                ref.read(statusPanelArcadeProvider.notifier).toggle(),
          ),
        ),
      ),
    );
  }
}

/// Retro digital panel: dark bezel, glowing segment-style readout and the
/// classic three-LED column (OK / alerta / falha) of old alarm centrals.
class _ArcadeStatusPanel extends StatelessWidget {
  const _ArcadeStatusPanel(
      {super.key, required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        // A physical device bezel — intentionally dark in both themes.
        color: const Color(0xFF15181D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2F38), width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF060B07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: color.withValues(alpha: 0.25),
                  width: 0.8,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'STATUS DA CENTRAL',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Courier'],
                      fontSize: 9,
                      letterSpacing: 2.5,
                      color: color.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 7),
                  DotMatrixDisplay(
                    text: label,
                    color: color,
                    height: 25,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ArcadeLed(
                  color: AppColors.success, active: color == AppColors.success),
              const SizedBox(height: 4),
              _ArcadeLed(
                  color: AppColors.warning, active: color == AppColors.warning),
              const SizedBox(height: 4),
              _ArcadeLed(
                  color: AppColors.error, active: color == AppColors.error),
            ],
          ),
          const SizedBox(width: 8),
          const _PanelStyleSwitch(),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

class _ArcadeLed extends StatelessWidget {
  const _ArcadeLed({required this.color, required this.active});

  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    if (active) return _PulsingStatusDot(color: color, active: true);
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.15),
            border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
          ),
        ),
      ),
    );
  }
}

class _CentralStatusCard extends StatelessWidget {
  const _CentralStatusCard(
      {super.key, required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final statusColor = color;
    final statusLabel = label;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              Icons.sensors_rounded,
              color: statusColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Status da Central',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  statusLabel,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          _PulsingStatusDot(
              color: statusColor, active: statusColor == AppColors.success),
          const SizedBox(width: 8),
          const _PanelStyleSwitch(),
        ],
      ),
    );
  }
}

class _PulsingStatusDot extends StatefulWidget {
  const _PulsingStatusDot({required this.color, required this.active});

  final Color color;
  final bool active;

  @override
  State<_PulsingStatusDot> createState() => _PulsingStatusDotState();
}

class _PulsingStatusDotState extends State<_PulsingStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _scale = Tween<double>(begin: 0.9, end: 1.35).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    if (widget.active) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PulsingStatusDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.active)
            ScaleTransition(
              scale: _scale,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.25),
                ),
              ),
            ),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.5),
                  blurRadius: 4,
                  spreadRadius: 0.5,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    this.compact = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final int value;
  final Color accent;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: EdgeInsets.all(compact ? 11 : 18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: compact ? _compactContent(context) : _fullContent(context),
    );

    if (onTap == null) return card;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: card,
      ),
    );
  }

  Widget _fullContent(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: accent, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value.toString(),
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _compactContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: accent, size: 15),
        ),
        const SizedBox(height: 7),
        Text(
          value.toString(),
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 21,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            height: 1,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}

// ── Gadget row ───────────────────────────────────────────────────────────────

class _GadgetRow extends StatelessWidget {
  const _GadgetRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _BatteryGadget(percent: 78)),
        SizedBox(width: 8),
        Expanded(child: _TemperatureGadget(celsius: 32)),
      ],
    );
  }
}

class _BatteryGadget extends StatefulWidget {
  const _BatteryGadget({this.percent = 78});
  final int percent;

  @override
  State<_BatteryGadget> createState() => _BatteryGadgetState();
}

class _BatteryGadgetState extends State<_BatteryGadget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _anim = Tween<double>(begin: 0, end: widget.percent / 100).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.percent > 50
        ? AppColors.success
        : widget.percent > 20
            ? AppColors.warning
            : AppColors.error;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.battery_charging_full_rounded, size: 11, color: color),
              const SizedBox(width: 5),
              Text(
                'BATERIA',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 84,
            width: double.infinity,
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: 112,
                      height: 40,
                      child: CustomPaint(
                        painter: _BatteryIconPainter(
                          progress: _anim.value,
                          color: color,
                          track: context.textSecondary.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${(widget.percent * _anim.value).round()}%',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'carga',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal battery icon: outlined body + terminal cap, with the charge
/// level filled left-to-right in the status color.
class _BatteryIconPainter extends CustomPainter {
  const _BatteryIconPainter({
    required this.progress,
    required this.color,
    required this.track,
  });

  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final capW = size.width * 0.06;
    final bodyW = size.width - capW - 2;
    final radius = size.height * 0.22;

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(1.25, 1.25, bodyW - 2.5, size.height - 2.5),
      Radius.circular(radius),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bodyW + 2, size.height * 0.32, capW, size.height * 0.36),
        const Radius.circular(2.5),
      ),
      Paint()..color = track,
    );

    if (progress <= 0) return;
    const inset = 4.5;
    final fill = Rect.fromLTWH(
      1.25 + inset,
      1.25 + inset,
      (bodyW - 2.5 - inset * 2) * progress.clamp(0.0, 1.0),
      size.height - 2.5 - inset * 2,
    );
    final rr = RRect.fromRectAndRadius(fill, Radius.circular(radius * 0.55));
    canvas.drawRRect(
      rr,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawRRect(rr, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BatteryIconPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

/// Vertical thermometer: bulb at the bottom, mercury column rising with the
/// temperature, plus scale ticks beside the tube.
class _ThermometerPainter extends CustomPainter {
  const _ThermometerPainter({
    required this.progress,
    required this.color,
    required this.track,
  });

  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final bulbR = size.width * 0.32;
    final bulbC = Offset(cx, size.height - bulbR - 1.5);
    final tubeW = size.width * 0.42;
    final tubeTop = tubeW / 2 + 1.5;

    final tube = RRect.fromRectAndRadius(
      Rect.fromLTRB(cx - tubeW / 2, tubeTop, cx + tubeW / 2, bulbC.dy),
      Radius.circular(tubeW / 2),
    );

    final trackFill = Paint()..color = track.withValues(alpha: 0.15);
    canvas.drawRRect(tube, trackFill);
    canvas.drawCircle(bulbC, bulbR, trackFill);

    final outline = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawRRect(tube, outline);
    canvas.drawCircle(bulbC, bulbR, outline);

    final tick = Paint()
      ..color = track
      ..strokeWidth = 1.4;
    final tickX = cx + tubeW / 2 + 2.5;
    for (var i = 1; i <= 3; i++) {
      final y = tubeTop + (bulbC.dy - tubeTop) * i / 4;
      canvas.drawLine(Offset(tickX, y), Offset(tickX + 3.5, y), tick);
    }

    final glow = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawCircle(bulbC, bulbR - 2.2, glow);
    canvas.drawCircle(bulbC, bulbR - 2.2, Paint()..color = color);

    if (progress > 0) {
      final innerW = tubeW * 0.5;
      final maxTop = tubeTop + innerW / 2 + 1.5;
      final level = bulbC.dy - (bulbC.dy - maxTop) * progress.clamp(0.0, 1.0);
      final mercury = RRect.fromRectAndRadius(
        Rect.fromLTRB(cx - innerW / 2, level, cx + innerW / 2, bulbC.dy),
        Radius.circular(innerW / 2),
      );
      canvas.drawRRect(mercury, glow);
      canvas.drawRRect(mercury, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_ThermometerPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

class _TemperatureGadget extends StatefulWidget {
  const _TemperatureGadget({this.celsius = 32});
  final double celsius;

  @override
  State<_TemperatureGadget> createState() => _TemperatureGadgetState();
}

class _TemperatureGadgetState extends State<_TemperatureGadget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _anim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Maps 0–80°C range to a 0..1 progress value for the arc.
  double get _progress => (widget.celsius / 80).clamp(0.0, 1.0);

  Color get _color {
    if (widget.celsius < 30) return AppColors.success;
    if (widget.celsius < 50) return AppColors.warning;
    return AppColors.error;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.thermostat_rounded, size: 11, color: color),
              const SizedBox(width: 5),
              Text(
                'TEMPERATURA',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 84,
            width: double.infinity,
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 30,
                    height: 76,
                    child: CustomPaint(
                      painter: _ThermometerPainter(
                        progress: _progress * _anim.value,
                        color: color,
                        track: context.textSecondary.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${(widget.celsius * _anim.value).toStringAsFixed(0)}°',
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'celsius',
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Generic placeholder tab ──────────────────────────────────────────────────

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: context.borderColor.withValues(alpha: 0.6),
                  width: 0.5,
                ),
              ),
              child: Icon(
                icon,
                size: 32,
                color: context.textSecondary.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Central PIN overlay ──────────────────────────────────────────────────────

class _PinOverlay extends ConsumerStatefulWidget {
  const _PinOverlay({super.key, required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  ConsumerState<_PinOverlay> createState() => _PinOverlayState();
}

class _PinOverlayState extends ConsumerState<_PinOverlay> {
  final List<String> _digits = [];
  bool _escapeVisible = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _escapeVisible = true);
    });
  }

  void _onDigit(String d) {
    if (_digits.length >= 6) return;
    setState(() => _digits.add(d));
    if (_digits.length == 6) {
      ref.read(centralAuthProvider.notifier).verify(_digits.join());
    }
  }

  void _onDelete() {
    if (_digits.isEmpty) return;
    setState(() => _digits.removeLast());
    final authState = ref.read(centralAuthProvider);
    if (authState is CentralPinError) {
      ref.read(centralAuthProvider.notifier).reset();
    }
  }

  void _clear() {
    setState(() => _digits.clear());
    ref.read(centralAuthProvider.notifier).reset();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(centralAuthProvider);
    final hasError = authState is CentralPinError;
    final errorMessage =
        authState is CentralPinError ? authState.message : null;
    final networkStatus = ref.watch(networkStatusProvider);

    ref.listen(centralAuthProvider, (_, next) {
      if (next is CentralPinError) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _clear();
        });
      }
    });

    final dots = _PinDots(filledCount: _digits.length, hasError: hasError);
    final numpad = _Numpad(onDigit: _onDigit, onDelete: _onDelete);
    final errorLabel = _ErrorLabel(message: errorMessage);
    final escapeBtn = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: _escapeVisible ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - value)),
          child: child,
        ),
      ),
      child: _EscapeButton(onTap: widget.onDismiss),
    );

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      body: Stack(
        children: [
          const Positioned.fill(child: IoTNetworkAnimation()),
          SafeArea(
            child: Column(
              children: [
                _ConnectivityBanner(networkStatus: networkStatus),
                Expanded(
                  child: OrientationBuilder(
                    builder: (context, orientation) {
                      if (orientation == Orientation.landscape) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 45,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const _PinHeader(showIcon: false),
                                  const SizedBox(height: 10),
                                  dots,
                                  const SizedBox(height: 6),
                                  errorLabel,
                                  const SizedBox(height: 10),
                                  escapeBtn,
                                ],
                              ),
                            ),
                            Container(
                              width: 1,
                              margin: const EdgeInsets.symmetric(vertical: 24),
                              color: AppColors.divider.withValues(alpha: 0.25),
                            ),
                            Expanded(
                              flex: 55,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final availH = constraints.maxHeight;
                                  final availW = constraints.maxWidth;
                                  // Fill ~85% of height across 4 rows
                                  final rowGap =
                                      (availH * 0.03).clamp(6.0, 16.0);
                                  final keyH =
                                      ((availH * 0.85) - rowGap * 4) / 4;
                                  // Each slot = keyW + 2*hPad; hPad = keyW*0.13
                                  // 3 slots fill ~88% of width => keyW = availW*0.88 / (3*1.26)
                                  final keyW = (availW * 0.88) / (3 * 1.26);
                                  return Center(
                                    child: _Numpad(
                                      onDigit: _onDigit,
                                      onDelete: _onDelete,
                                      keyWidth: keyW.clamp(44.0, 96.0),
                                      keyHeight: keyH.clamp(40.0, 82.0),
                                      rowGap: rowGap,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      }
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 32, vertical: 24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const _PinHeader(),
                                const SizedBox(height: 48),
                                dots,
                                const SizedBox(height: 12),
                                errorLabel,
                                const SizedBox(height: 40),
                                numpad,
                                const SizedBox(height: 28),
                                escapeBtn,
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PinHeader extends StatelessWidget {
  const _PinHeader({this.showIcon = true});

  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showIcon) ...[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppColors.secondary.withValues(alpha: 0.3),
              ),
            ),
            child: const Icon(
              Icons.lock_outline_rounded,
              color: AppColors.secondary,
              size: 30,
            ),
          ),
          const SizedBox(height: 20),
        ],
        Text(
          'Central SempreIoT',
          style: TextStyle(
            fontSize: showIcon ? 22 : 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimaryDark,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Digite o código de acesso',
          style: TextStyle(
            fontSize: 14,
            color: AppColors.textSecondaryDark,
          ),
        ),
      ],
    );
  }
}

class _PinDots extends StatelessWidget {
  const _PinDots({required this.filledCount, required this.hasError});

  final int filledCount;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        final filled = i < filledCount;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hasError
                ? AppColors.error
                : filled
                    ? AppColors.secondary
                    : Colors.transparent,
            border: Border.all(
              color: hasError
                  ? AppColors.error
                  : filled
                      ? AppColors.secondary
                      : AppColors.divider,
              width: 2,
            ),
          ),
        );
      }),
    );
  }
}

class _ErrorLabel extends StatelessWidget {
  const _ErrorLabel({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: message != null ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: Text(
        message ?? '',
        style: const TextStyle(fontSize: 13, color: AppColors.error),
      ),
    );
  }
}

class _Numpad extends StatelessWidget {
  const _Numpad({
    required this.onDigit,
    required this.onDelete,
    this.keyWidth = 72,
    this.keyHeight = 64,
    this.rowGap = 12,
  });

  final void Function(String) onDigit;
  final VoidCallback onDelete;
  final double keyWidth;
  final double keyHeight;
  final double rowGap;

  static const _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', 'del'],
  ];

  @override
  Widget build(BuildContext context) {
    final hPad = (keyWidth * 0.13).clamp(6.0, 12.0);
    final slotW = keyWidth + hPad * 2;
    final fontSize = (keyHeight * 0.38).clamp(16.0, 28.0);
    final iconSize = (keyHeight * 0.30).clamp(14.0, 22.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _keys.map((row) {
        return Padding(
          padding: EdgeInsets.only(bottom: rowGap),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map((key) {
              if (key.isEmpty) return SizedBox(width: slotW, height: keyHeight);
              if (key == 'del') {
                return _NumpadKey(
                  onTap: onDelete,
                  width: keyWidth,
                  height: keyHeight,
                  child: Icon(
                    Icons.backspace_outlined,
                    color: AppColors.textSecondaryDark,
                    size: iconSize,
                  ),
                );
              }
              return _NumpadKey(
                onTap: () => onDigit(key),
                width: keyWidth,
                height: keyHeight,
                child: Text(
                  key,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textPrimaryDark,
                  ),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}

class _NumpadKey extends StatelessWidget {
  const _NumpadKey({
    required this.child,
    required this.onTap,
    this.width = 72,
    this.height = 64,
  });

  final Widget child;
  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final hPad = (width * 0.13).clamp(6.0, 12.0);
    final radius = (height * 0.22).clamp(10.0, 18.0);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Material(
        color: AppColors.surfaceDark.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: AppColors.divider),
            ),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}

// ── Escape button ────────────────────────────────────────────────────────────

class _EscapeButton extends StatelessWidget {
  const _EscapeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(50),
      child: InkWell(
        borderRadius: BorderRadius.circular(50),
        splashColor: AppColors.textSecondaryDark.withValues(alpha: 0.08),
        highlightColor: AppColors.textSecondaryDark.withValues(alpha: 0.05),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(50),
            color: AppColors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: AppColors.white.withValues(alpha: 0.10),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_rounded,
                size: 13,
                color: AppColors.textSecondaryDark.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 8),
              Text(
                'Continuar bloqueado',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryDark.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Connectivity banner ──────────────────────────────────────────────────────

class _ConnectivityBanner extends StatelessWidget {
  const _ConnectivityBanner({required this.networkStatus});

  final NetworkStatus networkStatus;

  @override
  Widget build(BuildContext context) {
    final (bgColor, iconData, iconColor, label) = switch (networkStatus) {
      NetworkStatus.online => (
          const Color(0xFF1A3A28),
          Icons.wifi_rounded,
          AppColors.success,
          'Online',
        ),
      NetworkStatus.limited => (
          const Color(0xFF3A2D0A),
          Icons.wifi_rounded,
          AppColors.warning,
          'Wi-Fi conectado — servidor inacessível',
        ),
      NetworkStatus.offline => (
          const Color(0xFF3A1A1A),
          Icons.wifi_off_rounded,
          AppColors.error,
          'Sem conexão — modo offline',
        ),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: 28,
      color: bgColor,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(iconData, size: 14, color: iconColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: iconColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
