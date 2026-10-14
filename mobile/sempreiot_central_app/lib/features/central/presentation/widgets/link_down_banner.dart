import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/root_election_provider.dart';
import '../../application/serial_link_provider.dart';

/// Under the Rede strip whenever the board's link is down: the map then
/// shows the last state known, and nothing on it is live — said in words,
/// as Principal says it on its COMUNICAÇÃO tile, so an operator on Rede
/// never reads a silent map as a healthy one. Nothing while the link is
/// up. On a phone viewing a central: which link is missing — the phone's
/// own cloud session, the central's presence, the first picture — and
/// "sem a placa" only when the central itself reports its cable down.
class LinkDownBanner extends ConsumerWidget {
  const LinkDownBanner({super.key});

  static const bannerKey = ValueKey('link-down-banner');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final up = ref.watch(boardLinkUpProvider);
    final mirrored = ref.watch(viewedCentralProvider) != null;
    final Widget child;
    if (up) {
      child = const SizedBox(width: double.infinity, key: ValueKey('up'));
    } else if (mirrored) {
      // A phone: say which link is missing — its own cloud session, the
      // central's presence, the first picture still on its way — and only
      // when the central itself reports its cable down, say that.
      final view = ref.watch(centralMirrorProvider);
      if (!view.connected) {
        child = const _Line(
          key: bannerKey,
          color: AppColors.warning,
          icon: Icons.cloud_off_rounded,
          title: 'Sem conexão com a nuvem',
          detail: 'Este aparelho está sem ligação: o mapa mostra o que a '
              'central disse por último.',
          busy: true,
        );
      } else if (!view.centralOnline) {
        child = const _Line(
          key: bannerKey,
          color: AppColors.error,
          icon: Icons.power_off_rounded,
          title: 'Central offline',
          detail: 'A central não está ligada à nuvem: o mapa mostra o que '
              'ela disse por último.',
        );
      } else if (view.snapshotAt == null) {
        child = const _Line(
          key: bannerKey,
          color: AppColors.warning,
          icon: Icons.sync_rounded,
          title: 'Aguardando a central…',
          detail: 'A primeira imagem da rede está a caminho.',
          busy: true,
        );
      } else {
        child = _Line(
          key: bannerKey,
          color: AppColors.error,
          icon: Icons.usb_off_rounded,
          title: view.link == 'stalled'
              ? 'Placa sem resposta na central'
              : 'Central sem a placa',
          detail: 'A central informa que a placa não está no cabo USB: '
              'nada do que está no mapa é atual.',
        );
      }
    } else {
      child = switch (ref.watch(serialLinkProvider)) {
        SerialLinkStatus.connecting => const _Line(
            key: bannerKey,
            color: AppColors.warning,
            icon: Icons.usb_rounded,
            title: 'Conectando à placa…',
            detail: 'Porta USB aberta, aguardando o primeiro quadro.',
            busy: true,
          ),
        SerialLinkStatus.stalled => const _Line(
            key: bannerKey,
            color: AppColors.error,
            icon: Icons.usb_off_rounded,
            title: 'Placa sem resposta',
            detail: 'A porta USB está aberta, mas a placa não envia nada há '
                'mais de 20 s: o mapa mostra o último estado conhecido.',
          ),
        SerialLinkStatus.error => const _Line(
            key: bannerKey,
            color: AppColors.error,
            icon: Icons.usb_off_rounded,
            title: 'Ligação USB com erro',
            detail: 'Chegam bytes, mas nenhum quadro válido. Verifique o '
                'firmware da placa e a velocidade da porta.',
          ),
        SerialLinkStatus.disconnected ||
        SerialLinkStatus.connected =>
          const _Line(
            key: bannerKey,
            color: AppColors.error,
            icon: Icons.usb_off_rounded,
            title: 'Cabo USB desconectado',
            detail: 'Nenhuma informação chega da placa: o mapa mostra o '
                'último estado conhecido, nada nele é atual.',
          ),
      };
    }
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
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
              color.withValues(alpha: 0.12), context.surfaceColor),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.6)),
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
                            color: color,
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
      ),
    );
  }
}
