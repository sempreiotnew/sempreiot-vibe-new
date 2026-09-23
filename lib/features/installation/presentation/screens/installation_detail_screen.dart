import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../provisioning/presentation/screens/provisioning_wizard_screen.dart';
import '../../application/installation_provider.dart';
import '../../domain/entities/installation.dart';

/// Shows an installation's QR (for backup / handing to another installer
/// phone) and manages its zones list (POC-BRIEF.md §6.1).
class InstallationDetailScreen extends ConsumerWidget {
  const InstallationDetailScreen({super.key, required this.installationId});
  final String installationId;

  Future<void> _addZone(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final zone = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nova zona'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'ex: Térreo'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text),
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
      ),
      body: installation == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: QrImageView(
                      data: jsonEncode(installation.toJson()),
                      version: QrVersions.auto,
                      size: 220,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: AppColors.primary,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Backup da instalação — não é o QR do dispositivo',
                    style: TextStyle(color: context.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  // Same payload as the QR, for a central without a camera:
                  // paste it into "Instalação > Colar JSON" on the tablet.
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: jsonEncode(installation!.toJson())));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Código da instalação copiado (contém as chaves — '
                            'envie só para a central).'),
                      ));
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copiar código para a central'),
                  ),
                  const SizedBox(height: 24),
                  _InfoRow(label: 'SYSTEM_ID', value: '0x${installation.systemId.toRadixString(16).padLeft(4, '0').toUpperCase()}'),
                  _InfoRow(label: 'NET_SSID', value: installation.netSsid),
                  _InfoRow(label: 'CHANNEL', value: '${installation.channel}'),
                  _InfoRow(label: 'MESH_ID', value: '${installation.meshId}'),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'ZONAS',
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (installation.zones.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Nenhuma zona ainda.',
                          style: TextStyle(color: context.textSecondary)),
                    )
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
                  OutlinedButton.icon(
                    onPressed: () => _addZone(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Adicionar zona'),
                  ),
                  const SizedBox(height: 24),
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
                  if (installation.devices.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'DISPOSITIVOS PROVISIONADOS',
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final d in installation.devices)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${d.name} — ${d.zone} (${d.mac})',
                            style: TextStyle(
                                color: context.textPrimary, fontSize: 13),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
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
