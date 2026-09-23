import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../access/presentation/screens/qr_scanner_screen.dart';
import '../../../installation/domain/entities/installation.dart';
import '../../application/central_installation_provider.dart';

/// CENTRAL mode: which installation this tablet belongs to. The SYSTEM_ID
/// and SAFR key come from the phone's "Backup da instalação" QR — nothing
/// on the USB link ever carries them (POC-BRIEF §4.2). Until one is
/// imported the pipeline runs on the bench default identity and rejects
/// every frame from a provisioned board as foreign.
class CentralInstallationScreen extends ConsumerWidget {
  const CentralInstallationScreen({super.key});

  Future<void> _import(BuildContext context, WidgetRef ref, String raw) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final installation =
          await ref.read(centralInstallationProvider.notifier).import(raw);
      messenger.showSnackBar(SnackBar(
        content: Text('Instalação "${installation.displayName}" vinculada.'),
      ));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: AppColors.error,
      ));
    }
  }

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrScannerScreen(
          hint: 'Aponte para o QR "Backup da instalação" do app do instalador',
        ),
      ),
    );
    if (!context.mounted || scanned == null || scanned.trim().isEmpty) return;
    await _import(context, ref, scanned);
  }

  Future<void> _paste(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Colar JSON da instalação'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          autofocus: true,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: '{"localId": ..., "systemId": ..., "safrPskHex": ...}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Vincular'),
          ),
        ],
      ),
    );
    if (!context.mounted || raw == null || raw.trim().isEmpty) return;
    await _import(context, ref, raw);
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desvincular instalação?'),
        content: const Text(
            'A central volta à identidade de bancada e deixa de aceitar os '
            'quadros desta instalação até vincular de novo.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desvincular'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(centralInstallationProvider.notifier).clear();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(centralInstallationProvider);
    final installation = async.valueOrNull;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.barColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: const Text('Instalação',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: async.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (installation == null)
                  _EmptyCard()
                else
                  _InstallationCard(installation: installation),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _scan(context, ref),
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.secondary),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(installation == null
                      ? 'Escanear QR da instalação'
                      : 'Escanear outro QR'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => _paste(context, ref),
                  icon: const Icon(Icons.content_paste_rounded),
                  label: const Text('Colar JSON manualmente'),
                ),
                if (installation != null) ...[
                  const SizedBox(height: 24),
                  TextButton.icon(
                    onPressed: () => _clear(context, ref),
                    style: TextButton.styleFrom(foregroundColor: AppColors.error),
                    icon: const Icon(Icons.link_off_rounded),
                    label: const Text('Desvincular'),
                  ),
                ],
              ],
            ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Nenhuma instalação vinculada. A central está usando a '
              'identidade de bancada e vai rejeitar os quadros da placa '
              'provisionada. No app do instalador, abra a instalação e '
              'escaneie o QR "Backup da instalação".',
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _InstallationCard extends StatelessWidget {
  const _InstallationCard({required this.installation});
  final Installation installation;

  @override
  Widget build(BuildContext context) {
    final systemIdHex =
        '0x${installation.systemId.toRadixString(16).padLeft(4, '0').toUpperCase()}';
    return Container(
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
              const Icon(Icons.hub_rounded, color: AppColors.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  installation.displayName,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Row(label: 'SYSTEM_ID', value: systemIdHex),
          _Row(label: 'NET_SSID', value: installation.netSsid),
          _Row(label: 'CHANNEL', value: '${installation.channel}'),
          _Row(label: 'MESH_ID', value: '${installation.meshId}'),
          const _Row(label: 'CHAVE SAFR', value: 'presente (16 bytes)'),
          _Row(
            label: 'UNIDADES',
            value: '${installation.devices.length} provisionadas no app',
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: context.textSecondary, fontSize: 13)),
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
