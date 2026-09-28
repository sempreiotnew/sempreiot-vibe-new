import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/connectivity/network_status_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../presentation/widgets/iot_network_animation.dart';
import '../../application/central_auth_provider.dart';

class CentralPinScreen extends ConsumerStatefulWidget {
  const CentralPinScreen({super.key});

  @override
  ConsumerState<CentralPinScreen> createState() => _CentralPinScreenState();
}

class _CentralPinScreenState extends ConsumerState<CentralPinScreen> {
  final List<String> _digits = [];

  void _onDigit(String d) {
    if (_digits.length >= 4) return;
    setState(() => _digits.add(d));
    if (_digits.length == 4) {
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
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _Header(),
                            const SizedBox(height: 48),
                            _PinDots(
                                filledCount: _digits.length,
                                hasError: hasError),
                            const SizedBox(height: 12),
                            _ErrorLabel(message: errorMessage),
                            const SizedBox(height: 40),
                            _Numpad(onDigit: _onDigit, onDelete: _onDelete),
                          ],
                        ),
                      ),
                    ),
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
          const Color(0xFF52B788),
          'Online',
        ),
      NetworkStatus.limited => (
          const Color(0xFF3A2D0A),
          Icons.wifi_rounded,
          const Color(0xFFF59E0B),
          'Wi-Fi conectado — servidor inacessível',
        ),
      NetworkStatus.offline => (
          const Color(0xFF3A1A1A),
          Icons.wifi_off_rounded,
          Colors.red,
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

// ── Header ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
        const Text(
          'Central SempreIoT',
          style: TextStyle(
            fontSize: 22,
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

// ── PIN dots ─────────────────────────────────────────────────────────────────

class _PinDots extends StatelessWidget {
  const _PinDots({required this.filledCount, required this.hasError});
  final int filledCount;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (i) {
        final filled = i < filledCount;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hasError
                ? Colors.red.shade400
                : filled
                    ? AppColors.secondary
                    : Colors.transparent,
            border: Border.all(
              color: hasError
                  ? Colors.red.shade400
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

// ── Error label ───────────────────────────────────────────────────────────────

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
        style: TextStyle(fontSize: 13, color: Colors.red.shade400),
      ),
    );
  }
}

// ── Numpad ────────────────────────────────────────────────────────────────────

class _Numpad extends StatelessWidget {
  const _Numpad({required this.onDigit, required this.onDelete});
  final void Function(String) onDigit;
  final VoidCallback onDelete;

  static const _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', 'del'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: _keys.map((row) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map((key) {
              if (key.isEmpty) return const SizedBox(width: 80, height: 64);
              if (key == 'del') {
                return _NumpadKey(
                  onTap: onDelete,
                  child: const Icon(
                    Icons.backspace_outlined,
                    color: AppColors.textSecondaryDark,
                    size: 20,
                  ),
                );
              }
              return _NumpadKey(
                child: Text(
                  key,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textPrimaryDark,
                  ),
                ),
                onTap: () => onDigit(key),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}

class _NumpadKey extends StatelessWidget {
  const _NumpadKey({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Material(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 72,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
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
