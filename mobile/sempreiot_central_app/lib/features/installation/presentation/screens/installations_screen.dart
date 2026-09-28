import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/installation_provider.dart';
import '../../domain/entities/installation.dart';
import 'installation_detail_screen.dart';
import 'join_installation_screen.dart';

/// Lists installation codes generated on this phone (POC-BRIEF.md §6.1) and
/// lets the operator create a new one before starting the provisioning
/// wizard (Case A: the phone generates the code).
class InstallationsScreen extends ConsumerWidget {
  const InstallationsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    final installation = await ref
        .read(installationListProvider.notifier)
        .create(displayName: name.trim());
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InstallationDetailScreen(installationId: installation.localId),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(installationListProvider);

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.barColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: const Text('Instalações',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'join',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const JoinInstallationScreen()),
            ),
            backgroundColor: context.surfaceColor,
            foregroundColor: context.textPrimary,
            icon: const Icon(Icons.group_add_rounded),
            label: const Text('Entrar em instalação existente'),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'create',
            onPressed: () => _create(context, ref),
            backgroundColor: AppColors.secondary,
            icon: const Icon(Icons.add),
            label: const Text('Nova instalação'),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Erro ao carregar instalações: $e',
              style: TextStyle(color: context.textSecondary)),
        ),
        data: (installations) {
          if (installations.isEmpty) {
            return Center(
              child: Text(
                'Nenhuma instalação ainda.\nToque em "Nova instalação" para criar uma, '
                'ou em "Entrar em instalação existente" se outro instalador já criou.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textSecondary),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
            itemCount: installations.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _InstallationTile(installation: installations[i]),
          );
        },
      ),
    );
  }
}

class _InstallationTile extends StatelessWidget {
  const _InstallationTile({required this.installation});
  final Installation installation;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.surfaceColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                InstallationDetailScreen(installationId: installation.localId),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.hub_rounded, color: AppColors.secondary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(installation.displayName,
                        style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      '${installation.netSsid} · canal ${installation.channel} · '
                      '${installation.zones.length} zona(s)',
                      style: TextStyle(color: context.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: context.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nova instalação'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'ex: Galpão 2'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Criar'),
        ),
      ],
    );
  }
}
