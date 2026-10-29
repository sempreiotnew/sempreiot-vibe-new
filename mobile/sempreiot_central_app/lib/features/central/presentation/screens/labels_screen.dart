import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/credentials_admin_provider.dart';
import '../../application/device_labels_provider.dart';
import '../../application/safr_downlink_provider.dart';
import '../../application/serial_link_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../widgets/device_avatar.dart';
import '../widgets/editor_gate.dart';
import 'device_settings_screen.dart';

/// Zonas / Endereçamentos — the board's label table of one kind (protocol
/// §14.1 / §14.2): the names the user sees behind the ids every unit
/// carries. Create, rename and delete go to the board (PIN Master / Nível
/// 4); the list shown is the table as the board sent it back. A label a
/// unit still carries cannot be deleted.
class LabelsScreen extends ConsumerStatefulWidget {
  const LabelsScreen({super.key, required this.kind});

  final SafrLabelKind kind;

  @override
  ConsumerState<LabelsScreen> createState() => _LabelsScreenState();
}

class _LabelsScreenState extends ConsumerState<LabelsScreen> {
  static const _maxWidth = 720.0;

  SafrLabelKind get kind => widget.kind;

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(labelIndexProvider).of(kind);
    final nodes = ref.watch(topologyProvider);
    final linkUp =
        ref.watch(serialLinkProvider) == SerialLinkStatus.connected;
    final counts = <int, int>{};
    for (final n in nodes) {
      final id = kind == SafrLabelKind.zone ? n.zoneId : n.addressId;
      if (id != null && id != 0) counts[id] = (counts[id] ?? 0) + 1;
    }

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          kind.plural,
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: linkUp ? () => _edit(null) : null,
        backgroundColor: linkUp ? AppColors.secondary : context.borderColor,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text(kind == SafrLabelKind.zone
            ? 'Nova zona'
            : 'Novo endereçamento'),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text(
                  kind == SafrLabelKind.zone
                      ? 'Uma zona é um grupo de dispositivos acionado em '
                          'conjunto. A placa guarda a lista; cada dispositivo '
                          'pertence a uma zona, escolhida na tela do '
                          'dispositivo.'
                      : 'Um endereçamento diz onde o dispositivo está '
                          '(ex.: 1º andar). A placa guarda a lista; cada '
                          'dispositivo recebe o seu na tela do dispositivo.',
                  style:
                      TextStyle(color: context.textSecondary, fontSize: 13),
                ),
                if (!linkUp) ...[
                  const SizedBox(height: 12),
                  const _Notice(
                    icon: Icons.usb_off_rounded,
                    text: 'Sem a placa na USB a lista não pode ser alterada.',
                  ),
                ],
                const SizedBox(height: 16),
                if (labels.isEmpty)
                  _Empty(kind: kind)
                else
                  Container(
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: context.borderColor.withValues(alpha: 0.6),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < labels.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 0.5,
                              thickness: 0.5,
                              indent: 16,
                              endIndent: 16,
                              color:
                                  context.borderColor.withValues(alpha: 0.5),
                            ),
                          _LabelRow(
                            label: labels[i],
                            units: counts[labels[i].id] ?? 0,
                            onOpen: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => LabelDevicesScreen(
                                    kind: kind, label: labels[i]),
                              ),
                            ),
                            onRename: linkUp ? () => _edit(labels[i]) : null,
                            onDelete: linkUp
                                ? () => _delete(
                                    labels[i], counts[labels[i].id] ?? 0)
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<EditorRole?> _gate(String what) => requestEditorRole(
        context,
        subtitle: 'Digite o PIN Master ou o PIN de Nível 4\npara $what.',
      );

  void _show(String message, bool ok) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: ok ? AppColors.success : AppColors.trouble,
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// Create (null) or rename a label: the board keeps the table, the id is
  /// chosen here (protocol §7.6 SET_LABEL).
  Future<void> _edit(SafrLabel? existing) async {
    final what = existing == null
        ? 'criar ${kind.singular.toLowerCase()}'
        : 'renomear ${kind.singular.toLowerCase()}';
    final role = await _gate(what);
    if (role == null || !mounted) return;
    final ctrl = TextEditingController(text: existing?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text(existing == null
            ? (kind == SafrLabelKind.zone
                ? 'Nova zona'
                : 'Novo endereçamento')
            : 'Renomear'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: safrLabelNameMaxLen,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: kind.singular,
            hintText: kind == SafrLabelKind.zone
                ? 'ex.: Portões'
                : 'ex.: 1º andar',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(existing == null ? 'Criar' : 'Salvar'),
          ),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    final index = ref.read(labelIndexProvider);
    final same = index
        .of(kind)
        .where((l) => l.id != existing?.id && l.name == trimmed)
        .isNotEmpty;
    if (same) {
      _show('Já existe "$trimmed".', false);
      return;
    }
    if (existing == null && index.of(kind).length >= safrLabelCap) {
      _show('A placa aceita até $safrLabelCap ${kind.plural.toLowerCase()}.',
          false);
      return;
    }
    final id = existing?.id ?? index.nextId(kind);
    final r = await ref.read(safrDownlinkProvider).sendSetLabel(kind, id, trimmed);
    await ref.read(appDatabaseProvider).addAudit(
      role.auditName,
      existing == null ? 'label_create' : 'label_rename',
      {'kind': kind.name, 'id': id, 'name': trimmed, 'ok': r.ok},
    );
    _show(r.ok ? 'Confirmado pela placa.' : r.message, r.ok);
  }

  Future<void> _delete(SafrLabel label, int units) async {
    if (units > 0) {
      _show(
          '"${label.name}" ainda está em $units dispositivo${units == 1 ? '' : 's'}. '
          'Troque neles antes de apagar.',
          false);
      return;
    }
    final role = await _gate('apagar ${kind.singular.toLowerCase()}');
    if (role == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Apagar "${label.name}"?'),
        content: const Text('A placa remove o nome da sua lista.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r = await ref.read(safrDownlinkProvider).sendDelLabel(kind, label.id);
    await ref.read(appDatabaseProvider).addAudit(
      role.auditName,
      'label_delete',
      {'kind': kind.name, 'id': label.id, 'name': label.name, 'ok': r.ok},
    );
    _show(r.ok ? 'Confirmado pela placa.' : r.message, r.ok);
  }
}

class _LabelRow extends StatelessWidget {
  const _LabelRow({
    required this.label,
    required this.units,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final SafrLabel label;
  final int units;
  final VoidCallback onOpen;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onOpen,
      contentPadding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      title: Text(
        label.name,
        style: TextStyle(
          color: context.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        units == 0
            ? 'Nenhum dispositivo'
            : '$units dispositivo${units == 1 ? '' : 's'} · toque para ver',
        style: TextStyle(color: context.textSecondary, fontSize: 12.5),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Renomear',
            onPressed: onRename,
            icon: Icon(Icons.edit_rounded,
                size: 20, color: context.textSecondary),
          ),
          IconButton(
            tooltip: 'Apagar',
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline_rounded,
                size: 20,
                color: units == 0
                    ? AppColors.error
                    : context.textSecondary.withValues(alpha: 0.5)),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.kind});
  final SafrLabelKind kind;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            kind == SafrLabelKind.zone
                ? Icons.account_tree_outlined
                : Icons.place_outlined,
            size: 40,
            color: context.textSecondary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            kind == SafrLabelKind.zone
                ? 'Nenhuma zona ainda'
                : 'Nenhum endereçamento ainda',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A lista vem da placa; crie o primeiro abaixo.',
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.trouble.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.trouble),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(color: context.textPrimary, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// The units that carry one label, each a shortcut to its Dispositivo
/// screen. Live: follows the registry.
class LabelDevicesScreen extends ConsumerWidget {
  const LabelDevicesScreen({super.key, required this.kind, required this.label});

  final SafrLabelKind kind;
  final SafrLabel label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The label as the board holds it now (renamed since = the new name).
    final current = ref
            .watch(labelIndexProvider)
            .of(kind)
            .where((l) => l.id == label.id)
            .firstOrNull ??
        label;
    final units = ref
        .watch(topologyProvider)
        .where((n) =>
            (kind == SafrLabelKind.zone ? n.zoneId : n.addressId) == label.id)
        .toList()
      ..sort((a, b) => deviceDisplayName(a)
          .toLowerCase()
          .compareTo(deviceDisplayName(b).toLowerCase()));

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current.name,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              kind.singular,
              style: TextStyle(color: context.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: units.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    kind == SafrLabelKind.zone
                        ? 'Nenhum dispositivo nesta zona.\nEscolha-a na tela '
                            'do dispositivo, em "Zona e endereçamento".'
                        : 'Nenhum dispositivo neste endereçamento.\nEscolha-o '
                            'na tela do dispositivo, em "Zona e endereçamento".',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 13.5),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                itemCount: units.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final n = units[i];
                  final other = kind == SafrLabelKind.zone ? n.address : n.zone;
                  return Material(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DeviceSettingsScreen(mac: n.mac),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            DeviceAvatar(node: n, diameter: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    deviceDisplayName(n),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: context.textPrimary,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    [
                                      deviceStateLabel(n),
                                      if (other != null) other,
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: !n.online || n.alarmLatched
                                          ? AppColors.error
                                          : context.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded,
                                color: context.textSecondary),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
