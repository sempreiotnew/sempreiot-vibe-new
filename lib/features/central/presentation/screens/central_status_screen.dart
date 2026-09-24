import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../presentation/screens/main/main_screen.dart';
import '../../../../shared/widgets/presence_indicator.dart';
import '../../../access/application/user_access_provider.dart';
import '../../../access/domain/entities/access_level.dart';
import '../../../access/domain/entities/saved_central.dart';
import '../widgets/device_detail_widgets.dart';

/// Strips the `Exception: ` prefix so the guard messages thrown by
/// RequestAccessNotifier.request() show as-is instead of a raw dump.
String _friendlyRequestError(Object e) {
  final msg = e.toString();
  const prefix = 'Exception: ';
  return msg.startsWith(prefix)
      ? msg.substring(prefix.length)
      : 'Falha ao enviar. Verifique a conexão.';
}

/// Shown when a user taps a central in "Centrais" that isn't (yet) accepted —
/// pending, rejected, or blocked. An accepted central opens the real
/// dashboard (`MainScreen(centralId: ...)`) instead; if acceptance happens
/// live while this screen is open, it hands off there automatically.
class CentralStatusScreen extends ConsumerWidget {
  const CentralStatusScreen({super.key, required this.identityId});

  final String identityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final centrals = ref.watch(savedCentralsProvider);
    final matches = centrals.where((c) => c.identityId == identityId);
    final item = matches.isNotEmpty ? matches.first : null;

    ref.listen<List<SavedCentral>>(savedCentralsProvider, (_, next) {
      final updated = next.where((c) => c.identityId == identityId);
      if (updated.isNotEmpty && updated.first.status == 'ACCEPTED') {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => MainScreen(centralId: identityId)),
        );
      }
    });

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          item != null && item.name.isNotEmpty ? item.name : 'Central',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: context.borderColor.withValues(alpha: 0.5),
          ),
        ),
      ),
      body: item == null
          ? Center(
              child: Text(
                'Central não encontrada.',
                style: TextStyle(color: context.textSecondary, fontSize: 13),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
              children: [
                _StatusBanner(item: item),
                const SizedBox(height: 20),
                const InfoSectionHeader('PRESENÇA'),
                const SizedBox(height: 10),
                InfoCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      child: PresenceIndicator(
                          identityId: item.identityId, fontSize: 13),
                    ),
                  ],
                ),
                if (item.status == 'REJECTED') ...[
                  const SizedBox(height: 24),
                  _RequestAgainButton(item: item),
                ],
              ],
            ),
    );
  }
}

// ── Status banner ─────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.item});
  final SavedCentral item;

  @override
  Widget build(BuildContext context) {
    final (color, icon, title, subtitle) = switch (item.status) {
      'PENDING' => (
          AppColors.warning,
          Icons.hourglass_top_rounded,
          'Aguardando confirmação',
          'O responsável pela central ainda não avaliou sua solicitação.',
        ),
      'ACCEPTED' => (
          AppColors.success,
          Icons.check_circle_rounded,
          'Acesso concedido',
          (item.level ?? AccessLevel.level1).label,
        ),
      'BLOCKED' => (
          AppColors.error,
          Icons.block_rounded,
          'Acesso bloqueado',
          'O responsável por esta central bloqueou seu acesso.',
        ),
      _ => (
          AppColors.error,
          Icons.cancel_rounded,
          'Solicitação recusada',
          'Você pode solicitar acesso novamente.',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Request again ────────────────────────────────────────────────────────────

class _RequestAgainButton extends ConsumerStatefulWidget {
  const _RequestAgainButton({required this.item});
  final SavedCentral item;

  @override
  ConsumerState<_RequestAgainButton> createState() =>
      _RequestAgainButtonState();
}

class _RequestAgainButtonState extends ConsumerState<_RequestAgainButton> {
  bool _submitting = false;

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await ref.read(requestAccessProvider.notifier).request(
            centralSubId: widget.item.subId,
            centralIdentityId: widget.item.identityId,
            centralName: widget.item.name,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Solicitação enviada! Aguardando aprovação.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(_friendlyRequestError(e)),
              behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _submitting ? null : _submit,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.secondary,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: _submitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Text(
                'Solicitar novamente',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}
