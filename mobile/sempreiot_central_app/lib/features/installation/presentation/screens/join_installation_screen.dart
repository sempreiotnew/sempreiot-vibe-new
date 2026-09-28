import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../shared/widgets/passphrase_dialog.dart';
import '../../../access/presentation/screens/qr_scanner_screen.dart';
import '../../application/installation_provider.dart';
import '../../domain/services/installation_backup_codec.dart';
import 'installation_detail_screen.dart';
import 'join_from_board_screen.dart';

/// "Entrar em instalação existente" (lifecycle §5 D): a second installer
/// scans the encrypted QR another phone or the tablet shows, types the
/// passphrase, and from then on provisions units into the same site.
class JoinInstallationScreen extends ConsumerStatefulWidget {
  const JoinInstallationScreen({super.key});

  @override
  ConsumerState<JoinInstallationScreen> createState() =>
      _JoinInstallationScreenState();
}

class _JoinInstallationScreenState extends ConsumerState<JoinInstallationScreen> {
  bool _busy = false;

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrScannerScreen(
          hint: 'Aponte para o QR "Compartilhar instalação" do outro telefone '
              'ou da central',
        ),
      ),
    );
    if (!mounted || scanned == null || scanned.trim().isEmpty) return;
    await _join(scanned);
  }

  Future<void> _paste() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Colar código compartilhado'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          autofocus: true,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: '{"v":2,"kdf":"pbkdf2-sha256",...}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    await _join(raw);
  }

  Future<void> _join(String raw) async {
    final messenger = ScaffoldMessenger.of(context);
    final format = InstallationBackupCodec.detectFormat(raw);
    if (format == BackupFormat.unknown) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Isto não é um código de instalação compartilhado.'),
        backgroundColor: AppColors.error,
      ));
      return;
    }
    if (format == BackupFormat.legacyPlaintext) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Este é um backup antigo sem senha. Peça ao outro '
            'instalador para usar "Compartilhar" na versão atual do app.'),
        backgroundColor: AppColors.error,
      ));
      return;
    }
    final passphrase = await showPassphraseDialog(
      context,
      title: 'Senha da instalação',
      message: 'Digite a senha que o outro instalador definiu ao compartilhar.',
      actionLabel: 'Entrar',
    );
    if (!mounted || passphrase == null) return;

    setState(() => _busy = true);
    try {
      final shared = InstallationBackupCodec.decode(raw, passphrase);
      final (installation, outcome) = await ref
          .read(installationListProvider.notifier)
          .importShared(shared);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(outcome == ImportSharedOutcome.added
            ? 'Você entrou na instalação "${installation.displayName}".'
            : 'A instalação "${installation.displayName}" já estava neste '
                'telefone; nome e zonas atualizados.'),
      ));
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              InstallationDetailScreen(installationId: installation.localId),
        ),
      );
    } on BackupDecodeException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: AppColors.error,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.barColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: const Text('Entrar em instalação',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.group_add_rounded,
                              color: AppColors.secondary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text('Outro instalador já criou a instalação?',
                                style: TextStyle(
                                    color: context.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Peça para ele abrir a instalação e tocar em '
                        '"Compartilhar". Escaneie o QR e digite a senha que ele '
                        'definiu. Os dispositivos que você configurar entram na '
                        'mesma instalação — não é preciso juntar listas.',
                        style: TextStyle(
                            color: context.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.secondary),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Escanear QR compartilhado'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.content_paste_rounded),
                  label: const Text('Colar código compartilhado'),
                ),
                const SizedBox(height: 24),
                Text(
                  'Ninguém com o código por perto? A própria placa entrega o '
                  'código a quem tem a etiqueta dela.',
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const JoinFromBoardScreen()),
                          ),
                  icon: const Icon(Icons.developer_board_rounded),
                  label: const Text('Entrar pela placa (dois toques no botão)'),
                ),
                if (_busy) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
