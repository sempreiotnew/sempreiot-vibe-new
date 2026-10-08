import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/board_sync_provider.dart';

/// The line under the Rede strip while "Sincronizar com a placa" runs and
/// for a few seconds after: what the board sent, what left the map, who
/// still waits for a first signal. Nothing when idle.
class BoardSyncBanner extends StatelessWidget {
  const BoardSyncBanner({
    super.key,
    required this.sync,
    required this.awaiting,
  });

  final BoardSyncState sync;

  /// Units the board lists that this tablet has not heard yet.
  final int awaiting;

  @override
  Widget build(BuildContext context) {
    final Widget child = switch (sync.phase) {
      BoardSyncPhase.idle =>
        const SizedBox(width: double.infinity, key: ValueKey('idle')),
      BoardSyncPhase.syncing => const _Line(
          key: ValueKey('syncing'),
          color: AppColors.secondary,
          icon: Icons.sync_rounded,
          title: 'Sincronizando com a placa…',
          detail: 'O mapa continua como está; nada é apagado.',
          busy: true,
        ),
      BoardSyncPhase.done => _Line(
          key: const ValueKey('done'),
          color: AppColors.ledCyan,
          icon: Icons.done_all_rounded,
          title: 'Sincronizado · ${sync.listed} '
              '${sync.listed == 1 ? 'dispositivo' : 'dispositivos'} na placa',
          detail: [
            if (sync.removed > 0)
              '${sync.removed} fora da tabela e sem sinal '
                  '${sync.removed == 1 ? 'saiu' : 'saíram'} do mapa',
            if (awaiting > 0)
              '$awaiting aguardando o primeiro sinal '
                  '(detectores a bateria: até 1 min)',
            if (sync.removed == 0 && awaiting == 0) 'Tudo confere com a placa.',
          ].join(' · '),
        ),
      BoardSyncPhase.failed => const _Line(
          key: ValueKey('failed'),
          color: AppColors.error,
          icon: Icons.link_off_rounded,
          title: 'A placa não respondeu',
          detail: 'Verifique o cabo USB e tente de novo. O mapa não mudou.',
        ),
    };
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        child: child,
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.color,
    required this.icon,
    required this.title,
    required this.detail,
    this.busy = false,
  });
  final Color color;
  final IconData icon;
  final String title;
  final String detail;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            color.withValues(alpha: 0.10), context.surfaceColor),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: title,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      TextSpan(
                        text: '   $detail',
                        style: TextStyle(color: context.textSecondary),
                      ),
                    ]),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (busy)
            LinearProgressIndicator(
              minHeight: 2,
              color: color,
              backgroundColor: Colors.transparent,
            ),
        ],
      ),
    );
  }
}
