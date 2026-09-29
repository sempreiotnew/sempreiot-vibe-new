import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../shared/widgets/encrypted_share_dialog.dart';
import '../../../../shared/widgets/passphrase_dialog.dart';
import '../../../provisioning/presentation/screens/provisioning_wizard_screen.dart';
import '../../application/installation_provider.dart';
import '../../domain/entities/installation.dart';
import '../../domain/services/installation_backup_codec.dart';
import '../../../central/domain/safr/safr_product.dart';

/// One installation on this phone: share it (encrypted QR, lifecycle §2),
/// manage its zones, provision units, and see this phone's work log.
class InstallationDetailScreen extends ConsumerWidget {
  const InstallationDetailScreen({super.key, required this.installationId});
  final String installationId;

  Future<void> _addZone(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final zone = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Nova zona'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(hintText: 'ex: Térreo'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Adicionar'),
          ),
        ],
      ),
    );
    if (zone == null || zone.trim().isEmpty) return;
    await ref
        .read(installationListProvider.notifier)
        .addZone(installationId, zone.trim());
  }

  Future<void> _share(
      BuildContext context, WidgetRef ref, Installation installation) async {
    final passphrase = await showPassphraseDialog(
      context,
      title: 'Compartilhar instalação',
      message: 'Defina uma senha e diga-a ao outro instalador (ou ao operador '
          'da central). O QR só abre com ela.',
      confirm: true,
      actionLabel: 'Gerar QR',
    );
    if (!context.mounted || passphrase == null) return;
    final envelope = InstallationBackupCodec.encode(installation, passphrase);
    await showEncryptedShareDialog(
      context,
      title: 'Compartilhar "${installation.displayName}"',
      envelope: envelope,
    );
  }

  Future<void> _rename(
      BuildContext context, WidgetRef ref, Installation installation) async {
    final ctrl = TextEditingController(text: installation.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Renomear instalação'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 32,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await ref
        .read(installationListProvider.notifier)
        .rename(installationId, name.trim());
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, Installation installation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Excluir deste telefone?'),
        content: Text(
          'A instalação "${installation.displayName}" some só deste telefone. '
          'Os dispositivos e a central continuam funcionando. Se nenhum outro '
          'telefone ou a central tiver o código, ele não pode ser recuperado '
          'daqui.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await ref.read(installationListProvider.notifier).delete(installationId);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _removeFromLog(
      BuildContext context, WidgetRef ref, ProvisionedDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Remover do meu registro?'),
        content: Text(
          '"${d.name}" sai só da lista deste telefone. O dispositivo continua '
          'configurado; para aposentá-lo de verdade use a central.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(installationListProvider.notifier)
        .removeProvisionedDevice(installationId, d.mac);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installations = ref.watch(installationListProvider).valueOrNull;
    Installation? installation;
    if (installations != null) {
      for (final i in installations) {
        if (i.localId == installationId) {
          installation = i;
          break;
        }
      }
    }

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.barColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: Text(installation?.displayName ?? '...',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          if (installation != null)
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _rename(context, ref, installation!);
                  case 'delete':
                    _delete(context, ref, installation!);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Renomear')),
                PopupMenuItem(
                    value: 'delete', child: Text('Excluir deste telefone')),
              ],
            ),
        ],
      ),
      body: installation == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _InfoRow(
                            label: 'SYSTEM_ID',
                            value:
                                '0x${installation.systemId.toRadixString(16).padLeft(4, '0').toUpperCase()}'),
                        _InfoRow(label: 'NET_SSID', value: installation.netSsid),
                        _InfoRow(label: 'CHANNEL', value: '${installation.channel}'),
                        _InfoRow(label: 'MESH_ID', value: '${installation.meshId}'),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ProvisioningWizardScreen(
                                installationId: installationId,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          label: const Text('Provisionar dispositivo'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () => _share(context, ref, installation!),
                          icon: const Icon(Icons.share_rounded, size: 18),
                          label: const Text('Compartilhar (outro instalador / central)'),
                        ),
                        const SizedBox(height: 24),
                        const _SectionLabel('ZONAS'),
                        const SizedBox(height: 8),
                        if (installation.zones.isEmpty)
                          Text('Nenhuma zona ainda.',
                              style: TextStyle(color: context.textSecondary))
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final z in installation.zones)
                                Chip(label: Text(z)),
                            ],
                          ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: () => _addZone(context, ref),
                            icon: const Icon(Icons.add),
                            label: const Text('Adicionar zona'),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _SectionLabel(
                            'CONFIGURADOS POR ESTE TELEFONE (${installation.devices.length})'),
                        const SizedBox(height: 4),
                        Text(
                          'Só um registro deste telefone. A lista completa da '
                          'instalação fica na central, que descobre cada '
                          'dispositivo quando ele entra na rede.',
                          style: TextStyle(
                              color: context.textSecondary, fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        if (installation.devices.isEmpty)
                          Text('Nenhum dispositivo ainda.',
                              style: TextStyle(color: context.textSecondary))
                        else
                          for (final d in installation.devices)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: const Icon(Icons.sensors_rounded),
                              title: Text(d.name,
                                  style: TextStyle(
                                      color: context.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                  [
                                    (SafrProduct.fromCode(d.productCode) ??
                                            SafrProduct.fromModel(d.model))
                                        ?.label,
                                    d.zone,
                                    d.mac,
                                  ].whereType<String>().join(' · '),
                                  style: TextStyle(
                                      color: context.textSecondary,
                                      fontSize: 12)),
                              trailing: IconButton(
                                tooltip: 'Remover do meu registro',
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () => _removeFromLog(context, ref, d),
                              ),
                            ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: context.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: context.textSecondary, fontSize: 13)),
          Text(value,
              style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
