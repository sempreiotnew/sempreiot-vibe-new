import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/device_command_provider.dart';
import '../../application/device_update_controller.dart';
import '../../application/device_update_source.dart';
import '../../application/root_advisor_provider.dart';
import '../../application/system_test_provider.dart';
import '../../application/topology_provider.dart';
import 'device_avatar.dart';
import 'device_command_widgets.dart';

/// The line under the Rede strip when another unit hears the central
/// clearly better than the root does (root_advisor_provider): which unit,
/// by how much, and **Tornar root** — the central found it, a person says
/// yes. Two taps, no dialog. While the change is on its way the same line
/// says where it is (the command's own steps). Nothing at all otherwise.
///
/// The tablet, and the phone of an Administrador of the central (asked to
/// the central: central-mirror.md §4.12); everyone else sees it with the
/// button disabled, and why. "Agora não" is the tablet's only.
class RootAdviceBanner extends ConsumerStatefulWidget {
  const RootAdviceBanner({super.key, required this.nodes});
  final List<TopologyNode> nodes;

  static const bannerKey = ValueKey('root-advice-banner');
  static const takeKey = ValueKey('root-advice-take');
  static const laterKey = ValueKey('root-advice-later');

  @override
  ConsumerState<RootAdviceBanner> createState() => _RootAdviceBannerState();
}

class _RootAdviceBannerState extends ConsumerState<RootAdviceBanner> {
  static const _armedFor = Duration(seconds: 4);
  bool _armed = false;
  Timer? _disarm;

  @override
  void dispose() {
    _disarm?.cancel();
    super.dispose();
  }

  String _name(String mac) {
    for (final n in widget.nodes) {
      if (n.mac == mac) return deviceDisplayName(n);
    }
    return mac;
  }

  void _tap(RootAdvice advice) {
    if (!_armed) {
      setState(() => _armed = true);
      _disarm = Timer(_armedFor, () {
        if (mounted) setState(() => _armed = false);
      });
      return;
    }
    _disarm?.cancel();
    setState(() => _armed = false);
    // The tablet stops suggesting while the change is tried; a phone's
    // request makes the central do the same.
    if (!ref.read(mirrorViewOnlyProvider)) {
      ref.read(rootAdvisorProvider.notifier).noteAttempt();
    }
    ref
        .read(deviceCommandProvider.notifier)
        .run(advice.mac, DeviceCommandKind.takeRoot);
  }

  @override
  Widget build(BuildContext context) {
    final advice = ref.watch(rootAdviceProvider);
    final viewOnly = ref.watch(mirrorViewOnlyProvider);
    final canAct = !viewOnly || ref.watch(mirrorCanUpdateProvider);
    final commands = ref.watch(deviceCommandProvider);
    final change = commands.values
        .where((c) => c.kind == DeviceCommandKind.takeRoot)
        .firstOrNull;
    final whyNot = !canAct
        ? 'Só um Administrador desta central pode trocar o root.'
        : ref.watch(deviceUpdateRunProvider)?.running == true
            ? 'Aguarde o fim da atualização.'
            : ref.watch(systemTestsViewProvider).running != null
                ? 'Aguarde o fim do teste.'
                : null;

    final Widget child;
    if (change != null) {
      child = _Frame(
        key: const ValueKey('root-advice-change'),
        child: Row(
          children: [
            CommandTicks(status: change, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${_name(change.mac)} — ${commandStepText(change)}',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    } else if (advice != null) {
      final armed = _armed && whyNot == null;
      child = _Frame(
        key: RootAdviceBanner.bannerKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.router_outlined,
                      size: 20, color: AppColors.secondary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_name(advice.mac)} ouve a central melhor que o '
                        'root atual',
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${advice.rssi} dBm, contra ${advice.rootRssi} dBm de '
                        '${_name(advice.rootMac)} (${advice.gainDb} dB '
                        'melhor). ${whyNot ?? 'Trocar o root reorganiza a rede por alguns '
                            'segundos.'}',
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 11.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  if (!viewOnly)
                    TextButton(
                      key: RootAdviceBanner.laterKey,
                      onPressed: () => ref
                          .read(rootAdvisorProvider.notifier)
                          .dismiss(advice.mac),
                      child: const Text('Agora não'),
                    ),
                  FilledButton.tonalIcon(
                    key: RootAdviceBanner.takeKey,
                    onPressed: whyNot == null ? () => _tap(advice) : null,
                    style: armed
                        ? FilledButton.styleFrom(
                            backgroundColor:
                                AppColors.error.withValues(alpha: 0.16),
                            foregroundColor: AppColors.error,
                          )
                        : null,
                    icon: const Icon(Icons.swap_vert_rounded, size: 18),
                    label: Text(
                      armed ? 'Toque de novo para trocar' : 'Tornar root',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      child = const SizedBox(width: double.infinity, key: ValueKey('none'));
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        child: child,
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const color = AppColors.secondary;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: child,
    );
  }
}
