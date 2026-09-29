import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/credentials_admin_provider.dart';
import '../../application/safr_downlink_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../widgets/device_avatar.dart';
import '../widgets/device_detail_widgets.dart';
import '../widgets/editor_gate.dart';

/// Dispositivo — everything the tablet knows about one device (identity,
/// place in the mesh, state on the board) and its management: rename,
/// retire, replace, decommission, forget (installation-lifecycle-v1.md §5,
/// PIN Master / Nível 4). Live: follows the device registry by MAC.
class DeviceSettingsScreen extends ConsumerStatefulWidget {
  const DeviceSettingsScreen({super.key, required this.mac});

  final String mac;

  @override
  ConsumerState<DeviceSettingsScreen> createState() =>
      _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends ConsumerState<DeviceSettingsScreen> {
  /// Content column cap: readable on a landscape tablet, full width on phones.
  static const _maxWidth = 720.0;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(topologyProvider);
    TopologyNode? node;
    for (final n in all) {
      if (n.mac == widget.mac) {
        node = n;
        break;
      }
    }

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          'Dispositivo',
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
      body: SafeArea(
        top: false,
        child: node == null
            ? _Gone(mac: widget.mac)
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxWidth),
                  child: _content(context, node, all),
                ),
              ),
      ),
    );
  }

  Widget _content(
      BuildContext context, TopologyNode node, List<TopologyNode> all) {
    String nameOf(String mac) {
      for (final n in all) {
        if (n.mac == mac) {
          return n.layer == 0 ? 'Central ($mac)' : deviceDisplayName(n);
        }
      }
      return mac;
    }

    final canManage = node.layer > 0 || node.boardState != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        _Hero(node: node, onRename: () => _rename(node)),
        const SizedBox(height: 24),
        const InfoSectionHeader('IDENTIFICAÇÃO'),
        const SizedBox(height: 10),
        InfoCard(children: [
          _Fact(
            icon: Icons.label_rounded,
            label: 'Nome',
            value: node.name ?? '',
            trailing: _EditButton(onTap: () => _rename(node)),
          ),
          const InfoRowDivider(),
          _Fact(
            icon: Icons.place_rounded,
            label: 'Zona',
            value: node.zone ?? '',
            trailing: _EditButton(onTap: () => _rename(node)),
          ),
          const InfoRowDivider(),
          _Fact(
            icon: Icons.qr_code_2_rounded,
            label: 'MAC',
            value: node.mac,
            mono: true,
            trailing: _CopyButton(label: 'MAC', value: node.mac),
          ),
          const InfoRowDivider(),
          _Fact(
            icon: Icons.inventory_2_outlined,
            label: 'Produto',
            value: node.productLabel,
          ),
          if ((node.hwRev ?? 0) > 0) ...[
            const InfoRowDivider(),
            _Fact(
              icon: Icons.memory_rounded,
              label: 'Revisão de hardware',
              value: '${node.hwRev}',
            ),
          ],
          const InfoRowDivider(),
          _Fact(
            icon: Icons.system_update_alt_rounded,
            label: 'Firmware',
            value: node.firmwareLabel,
            mono: node.firmwareLabel.isNotEmpty,
          ),
        ]),
        const SizedBox(height: 24),
        const InfoSectionHeader('REDE'),
        const SizedBox(height: 10),
        InfoCard(children: [
          _Fact(
              icon: Icons.category_rounded,
              label: 'Papel',
              value: deviceRoleLabel(node)),
          const InfoRowDivider(),
          _Fact(
              icon: Icons.layers_rounded,
              label: 'Camada',
              value: 'L${node.layer}'),
          if (node.parentMac != null) ...[
            const InfoRowDivider(),
            _Fact(
              icon: Icons.account_tree_outlined,
              label: 'Pai',
              value: nameOf(node.parentMac!),
            ),
          ],
          if (node.rssi != null) ...[
            const InfoRowDivider(),
            _Fact(
              icon: Icons.network_cell_rounded,
              label: node.sleeping ? 'Sinal (último despertar)' : 'Sinal',
              value: '${node.rssi} dBm',
              valueColor: signalColor(node.rssi),
            ),
          ],
          if (node.isLeaf) ...[
            const InfoRowDivider(),
            _Fact(
              icon: Icons.device_hub_rounded,
              label: 'Pais ao alcance',
              value: node.parentCandidates.isEmpty
                  ? 'nenhum informado ainda'
                  : node.parentCandidates
                      .map((c) => '${nameOf(c.mac)}  ${c.rssi} dBm')
                      .join('\n'),
              valueColor: node.singleParent ? AppColors.warning : null,
            ),
          ],
          if (node.batteryPct != null) ...[
            const InfoRowDivider(),
            _Fact(
                icon: Icons.battery_std_rounded,
                label: 'Bateria',
                value: '${node.batteryPct}%'),
          ],
        ]),
        if (node.isLeaf &&
            node.online &&
            (node.singleParent || node.weakLink)) ...[
          const SizedBox(height: 10),
          if (node.singleParent)
            const _Notice(
                'Só um pai ao alcance — instale um dispositivo AC mais perto.'),
          if (node.weakLink)
            const _Notice('Sinal fraco com o pai (abaixo de −85 dBm).'),
        ],
        const SizedBox(height: 24),
        const InfoSectionHeader('ESTADO'),
        const SizedBox(height: 10),
        InfoCard(children: [
          _Fact(
            icon: Icons.monitor_heart_outlined,
            label: 'Estado',
            value: _stateDetail(node),
            valueColor: !node.online ? AppColors.error : null,
          ),
          const InfoRowDivider(),
          _Fact(
            icon: Icons.schedule_rounded,
            label: 'Última comunicação',
            value: relativeTime(node.lastSeenAt),
          ),
          if (node.alarmLatched) ...[
            const InfoRowDivider(),
            _Fact(
              icon: Icons.local_fire_department_rounded,
              label: 'Alarme retido',
              value: node.alarmLatchedAt != null
                  ? 'desde ${relativeTime(node.alarmLatchedAt!)}'
                  : 'sim',
              valueColor: AppColors.error,
            ),
          ],
          if (node.boardState != null) ...[
            const InfoRowDivider(),
            _Fact(
              icon: Icons.developer_board_rounded,
              label: 'Na placa',
              value: switch (node.boardState!) {
                SafrDeviceState.expected => 'esperado (nunca ouvido)',
                SafrDeviceState.online => 'online',
                SafrDeviceState.missing => 'sem comunicação',
                SafrDeviceState.retired => node.heardWhileRetired
                    ? 'aposentado — mas transmitindo'
                    : 'aposentado',
                _ => '?',
              },
              valueColor: node.retired ? AppColors.trouble : null,
            ),
          ],
          if (node.pendingRename) ...[
            const InfoRowDivider(),
            const _Fact(
              icon: Icons.pending_outlined,
              label: 'Pendente',
              value: 'novo nome/zona: aplica quando o dispositivo falar',
              valueColor: AppColors.warning,
            ),
          ],
          if (node.pendingDecommission) ...[
            const InfoRowDivider(),
            const _Fact(
              icon: Icons.pending_outlined,
              label: 'Pendente',
              value: 'apagar da placa: aplica quando o dispositivo falar',
              valueColor: AppColors.warning,
            ),
          ],
        ]),
        if (canManage) ...[
          const SizedBox(height: 24),
          const InfoSectionHeader('GERENCIAR — PIN MASTER / NÍVEL 4'),
          const SizedBox(height: 10),
          InfoCard(children: [
            _ManageRow(
              label: 'Nome e zona',
              hint: 'Renomeia na placa e no dispositivo',
              icon: Icons.edit_rounded,
              onTap: () => _rename(node),
            ),
            const InfoRowDivider(),
            if (!node.retired)
              _ManageRow(
                label: 'Aposentar',
                hint: 'A placa passa a ignorar este dispositivo',
                icon: Icons.person_off_outlined,
                onTap: () => _retire(node),
              )
            else
              _ManageRow(
                label: 'Reativar',
                hint: 'Volta a aceitar este dispositivo',
                icon: Icons.person_add_alt_1_outlined,
                onTap: () => _unretire(node),
              ),
            const InfoRowDivider(),
            _ManageRow(
              label: 'Substituir por…',
              hint: 'Move nome e zona para um dispositivo novo',
              icon: Icons.swap_horiz_rounded,
              onTap: () => _replace(node),
            ),
            if (node.retired) ...[
              const InfoRowDivider(),
              _ManageRow(
                label: 'Esquecer',
                hint: 'Remove o registro aposentado da placa',
                icon: Icons.playlist_remove_rounded,
                onTap: () => _forget(node),
              ),
            ],
            const InfoRowDivider(),
            _ManageRow(
              label: 'Apagar da placa',
              hint: 'Reset de fábrica remoto (digite o nome para confirmar)',
              icon: Icons.delete_forever_outlined,
              destructive: true,
              onTap: () => _decommission(node),
            ),
          ]),
        ],
      ],
    );
  }

  String _stateDetail(TopologyNode node) {
    if (node.online && node.sleeping) {
      final next = node.nextWakeInSeconds;
      return 'Dormindo · próximo despertar '
          '${next != null ? 'em ~$next s' : 'a qualquer momento'}';
    }
    if (!node.online) {
      return '${deviceStateLabel(node)} (${relativeTime(node.lastSeenAt)})';
    }
    return deviceStateLabel(node);
  }

  // ── Management (lifecycle §5) ──────────────────────────────────────────────

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

  Future<void> _rename(TopologyNode node) async {
    // Lifecycle §5 H: SET_DEVICE to the board (which relays to the unit and
    // keeps it pending while the unit is away). Without a v3.2 board the row
    // is edited on this tablet only.
    final role = await _gate('renomear este dispositivo');
    if (role == null || !mounted) return;
    final nameCtrl = TextEditingController(text: node.name ?? '');
    final zoneCtrl = TextEditingController(text: node.zone ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: dialogContext.surfaceColor,
        title: const Text('Nome e zona'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                maxLength: 32,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Nome',
                  hintText: 'ex.: Sala de máquinas',
                  helperText: node.mac,
                ),
              ),
              TextField(
                controller: zoneCtrl,
                maxLength: 16,
                decoration: const InputDecoration(
                    labelText: 'Zona', hintText: 'ex.: Térreo'),
                onSubmitted: (_) => Navigator.pop(dialogContext, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final zone = zoneCtrl.text.trim();
    if (name.isEmpty) return;
    final db = ref.read(appDatabaseProvider);
    final result = await ref
        .read(safrDownlinkProvider)
        .sendSetDevice(node.mac, name, zone);
    await (db.update(db.meshDevices)..where((t) => t.mac.equals(node.mac)))
        .write(MeshDevicesCompanion(name: Value(name), zone: Value(zone)));
    await db.addAudit(
        role.auditName,
        result.ok ? 'device_rename' : 'device_rename_local',
        {'mac': node.mac, 'name': name, 'zone': zone, 'board_ok': result.ok});
    _show(
        result.ok
            ? 'Nome enviado à placa.'
            : 'Salvo só neste tablet — ${result.message}',
        result.ok);
  }

  Future<void> _retire(TopologyNode node) async {
    final role = await _gate('aposentar este dispositivo');
    if (role == null) return;
    final r = await ref.read(safrDownlinkProvider).sendRetireDevice(node.mac);
    await ref.read(appDatabaseProvider).addAudit(
        role.auditName, 'device_retire', {'mac': node.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.message, r.ok);
  }

  Future<void> _unretire(TopologyNode node) async {
    final role = await _gate('reativar este dispositivo');
    if (role == null) return;
    final r = await ref.read(safrDownlinkProvider).sendUnretireDevice(node.mac);
    await ref.read(appDatabaseProvider).addAudit(
        role.auditName, 'device_unretire', {'mac': node.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.message, r.ok);
  }

  Future<void> _forget(TopologyNode node) async {
    final role = await _gate('esquecer este dispositivo');
    if (role == null) return;
    final r = await ref.read(safrDownlinkProvider).sendForgetDevice(node.mac);
    await ref.read(appDatabaseProvider).addAudit(
        role.auditName, 'device_forget', {'mac': node.mac, 'ok': r.ok});
    if (r.ok) {
      final db = ref.read(appDatabaseProvider);
      await (db.delete(db.meshDevices)..where((t) => t.mac.equals(node.mac)))
          .go();
      if (mounted) Navigator.pop(context);
      return;
    }
    _show(r.message, r.ok);
  }

  Future<void> _replace(TopologyNode node) async {
    final role = await _gate('substituir este dispositivo');
    if (role == null || !mounted) return;
    final candidates = ref
        .read(topologyProvider)
        .where((n) => n.mac != node.mac && !n.retired && n.layer > 0)
        .toList();
    final chosen = await showDialog<TopologyNode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Substituir "${deviceDisplayName(node)}" por…'),
        children: candidates.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Nenhum dispositivo novo visto ainda. Configure a unidade '
                    'nova pelo telefone e aguarde ela aparecer na rede.',
                    style: TextStyle(color: ctx.textSecondary, fontSize: 13),
                  ),
                ),
              ]
            : [
                for (final c in candidates)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, c),
                    child: Text('${deviceDisplayName(c)} · '
                        '${c.online ? "online" : "sem comunicação"}'),
                  ),
              ],
      ),
    );
    if (chosen == null) return;
    final r = await ref
        .read(safrDownlinkProvider)
        .sendReplaceDevice(node.mac, chosen.mac);
    await ref.read(appDatabaseProvider).addAudit(role.auditName,
        'device_replace', {'old': node.mac, 'new': chosen.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.ok ? 'Substituído. O antigo foi aposentado.' : r.message, r.ok);
  }

  Future<void> _decommission(TopologyNode node) async {
    final role = await _gate('apagar este dispositivo da placa');
    if (role == null || !mounted) return;
    final expected = deviceDisplayName(node);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Apagar da placa?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'O dispositivo apaga a própria configuração e volta ao modo de '
                'instalação (LED branco piscando). Para confirmar, digite '
                'exatamente: $expected',
                style: TextStyle(color: ctx.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(controller: ctrl, autofocus: true),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim() == expected),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (ok != true) {
      if (ok == false && ctrl.text.isNotEmpty) {
        _show('Nome não confere. Nada foi feito.', false);
      }
      return;
    }
    final r = await ref.read(safrDownlinkProvider).sendDecommission(node.mac);
    await ref.read(appDatabaseProvider).addAudit(
        role.auditName, 'device_decommission', {'mac': node.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.ok ? 'Enviado. A unidade será apagada (ou ao acordar).' : r.message,
        r.ok);
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  const _Hero({required this.node, required this.onRename});

  final TopologyNode node;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final hasName = node.name?.isNotEmpty == true;
    final stateColor = !node.online || node.alarmLatched
        ? AppColors.error
        : node.sleeping
            ? context.textSecondary
            : AppColors.success;

    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.all(6),
          child: Opacity(
            opacity: node.stale ? deviceStaleOpacity : 1,
            child: DeviceAvatar(node: node, diameter: 72),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                deviceDisplayName(node),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  fontFamily: hasName ? null : 'monospace',
                ),
              ),
              if (node.zone?.isNotEmpty == true)
                Text(
                  node.zone!,
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: stateColor.withValues(alpha: 0.4), width: 0.7),
                ),
                child: Text(
                  node.alarmLatched ? 'Em alarme' : deviceStateLabel(node),
                  style: TextStyle(
                    color: stateColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Nome e zona',
          onPressed: onRename,
          icon: Icon(Icons.edit_rounded, color: context.textSecondary),
        ),
      ],
    );
  }
}

/// A labelled fact; unlike InfoReadRow it wraps and takes a value colour.
class _Fact extends StatelessWidget {
  const _Fact({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.mono = false,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool mono;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final empty = value.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: context.borderColor.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: context.textSecondary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  empty ? '—' : value,
                  style: TextStyle(
                    color: empty
                        ? context.textSecondary.withValues(alpha: 0.4)
                        : valueColor ?? context.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: mono ? 'monospace' : null,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing! else const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _EditButton extends StatelessWidget {
  const _EditButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Editar',
        onPressed: onTap,
        icon: Icon(Icons.edit_outlined,
            size: 17, color: context.textSecondary.withValues(alpha: 0.7)),
      );
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Copiar',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$label copiado.'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ));
        },
        icon: Icon(Icons.copy_rounded,
            size: 16, color: context.textSecondary.withValues(alpha: 0.7)),
      );
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({
    required this.label,
    required this.hint,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final String hint;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.error : context.textPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: (destructive ? AppColors.error : context.borderColor)
                    .withValues(alpha: destructive ? 0.12 : 0.3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  size: 18,
                  color: destructive ? AppColors.error : AppColors.secondary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: color,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(hint,
                      style: TextStyle(
                          color: context.textSecondary, fontSize: 11.5)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: context.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.45), width: 0.7),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 17, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.warning,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The device left the registry (forgotten, or the map was re-synced).
class _Gone extends StatelessWidget {
  const _Gone({required this.mac});
  final String mac;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.device_unknown_rounded,
                size: 48, color: context.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              'Dispositivo não está mais na rede',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              mac,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
