import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../access/application/central_access_provider.dart';
import '../../../access/domain/entities/access_level.dart';
import '../../../access/domain/entities/access_relation.dart';
import '../../../access/presentation/screens/my_qr_screen.dart';
import '../../application/credentials_admin_provider.dart';
import '../widgets/device_detail_widgets.dart';
import '../widgets/editor_gate.dart';
import 'access_pins_screen.dart';

/// Access management for this central. The whole screen is gated: entering
/// requires the Master or Nível 4 PIN, and the proven role is attached to
/// every action taken here — so the audit trail always knows who touched
/// what. The role dies with the screen.
class DeviceAccessScreen extends ConsumerStatefulWidget {
  const DeviceAccessScreen({super.key});

  @override
  ConsumerState<DeviceAccessScreen> createState() => _DeviceAccessScreenState();
}

class _DeviceAccessScreenState extends ConsumerState<DeviceAccessScreen> {
  EditorRole? _role;

  @override
  Widget build(BuildContext context) {
    final role = _role;
    if (role == null) {
      return Scaffold(
        backgroundColor: context.bgColor,
        appBar: AppBar(
          backgroundColor: context.bgColor,
          elevation: 0,
          iconTheme: IconThemeData(color: context.textPrimary),
          title: Text(
            'Acessos',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        body: EditorGate(
          subtitle: 'Digite o PIN Master ou o PIN de Nível 4\n'
              'para gerenciar os acessos desta central.',
          onUnlocked: (r) => setState(() => _role = r),
        ),
      );
    }

    final pending = ref.watch(centralPendingRequestsProvider);
    final granted = ref.watch(centralGrantedProvider);
    final blocked = ref.watch(centralBlockedProvider);
    final syncing = ref.watch(centralAccessSyncingProvider);
    final centralIdAsync = ref.watch(centralIdProvider);
    final centralId = centralIdAsync.valueOrNull ?? '';

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          'Acessos',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          const _RefreshButton(),
          IconButton(
            icon: const Icon(Icons.qr_code_rounded),
            tooltip: 'Meu QR Code',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MyQrScreen()),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: context.borderColor.withValues(alpha: 0.5),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(centralAccessRelationsProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
          children: [
            // ── SOLICITAÇÕES PENDENTES ────────────────────────────────
            if (pending.isNotEmpty) ...[
              _PendingSectionHeader(count: pending.length),
              const SizedBox(height: 8),
              ...pending.map(
                (rel) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PendingRequestCard(
                    relation: rel,
                    centralId: centralId,
                    actor: role.auditName,
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── CREDENCIAIS ───────────────────────────────────────────
            const InfoSectionHeader('CREDENCIAIS'),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'PINs de nível, root e senha são gerenciados em PINs de '
                'Acesso (restrito a Master e Administrador).',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
            InfoCard(
              children: [
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AccessPinsScreen(initialRole: role),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.secondary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.admin_panel_settings_rounded,
                            size: 18,
                            color: AppColors.secondary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PINs de Acesso',
                                style: TextStyle(
                                  color: context.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Níveis, root, senha e auditoria',
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: AppColors.secondary.withValues(alpha: 0.7),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ── ACESSO CONCEDIDO ─────────────────────────────────────
            const InfoSectionHeader('ACESSO CONCEDIDO'),
            const SizedBox(height: 10),
            if (granted.isEmpty && syncing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.secondary,
                    ),
                  ),
                ),
              )
            else if (granted.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Nenhum usuário com acesso concedido.',
                  style: TextStyle(
                    color: context.textSecondary.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              )
            else
              ...granted.map(
                (rel) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _GrantedUserCard(
                    relation: rel,
                    centralId: centralId,
                    actor: role,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            const _AddAccessButton(),

            // ── BLOQUEADOS ────────────────────────────────────────────
            if (blocked.isNotEmpty) ...[
              const SizedBox(height: 24),
              const InfoSectionHeader('BLOQUEADOS'),
              const SizedBox(height: 10),
              ...blocked.map(
                (rel) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _BlockedUserCard(relation: rel, actor: role.auditName),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── PIN row ───────────────────────────────────────────────────────────────────

// ── Refresh button ────────────────────────────────────────────────────────────

class _RefreshButton extends ConsumerStatefulWidget {
  const _RefreshButton();

  @override
  ConsumerState<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends ConsumerState<_RefreshButton> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await ref.read(centralAccessRelationsProvider.notifier).refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_refreshing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.secondary),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.refresh_rounded),
      tooltip: 'Atualizar',
      onPressed: _refresh,
    );
  }
}

// ── Granted user card ─────────────────────────────────────────────────────────

class _GrantedUserCard extends ConsumerWidget {
  const _GrantedUserCard({
    required this.relation,
    required this.centralId,
    required this.actor,
  });
  final AccessRelation relation;
  final String centralId;
  final EditorRole actor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = relation.level ?? AccessLevel.level1;

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: level.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(level.icon, size: 20, color: level.color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        level.label,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: level.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: level.color.withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        level.shortLabel,
                        style: TextStyle(
                          color: level.color,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  relation.userSubId,
                  style: TextStyle(
                    color: context.textSecondary.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.copy_rounded,
                size: 16, color: context.textSecondary.withValues(alpha: 0.4)),
            tooltip: 'Copiar Sub ID',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: relation.userSubId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Sub ID copiado.'),
                  behavior: SnackBarBehavior.floating,
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded,
                size: 18, color: AppColors.secondary),
            tooltip: 'Alterar nível',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _LevelChangeSheet(
                relation: relation,
                centralId: centralId,
                actor: actor,
              ),
            ),
          ),
          // MASTER cannot be kicked: no block action. The only way out is a
          // root-authorized demotion via the level-change sheet.
          if (level != AccessLevel.master)
            IconButton(
              icon: const Icon(Icons.block_rounded,
                  size: 18, color: AppColors.error),
              tooltip: 'Bloquear',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => _confirmBlock(
                  context, ref, relation, centralId, actor.auditName),
            ),
        ],
      ),
    );
  }
}

// ── Blocked user card ─────────────────────────────────────────────────────────

class _BlockedUserCard extends ConsumerStatefulWidget {
  const _BlockedUserCard({required this.relation, required this.actor});
  final AccessRelation relation;
  final String actor;

  @override
  ConsumerState<_BlockedUserCard> createState() => _BlockedUserCardState();
}

class _BlockedUserCardState extends ConsumerState<_BlockedUserCard> {
  bool _loading = false;

  Future<void> _unblock() async {
    setState(() => _loading = true);
    try {
      await ref
          .read(centralAccessRelationsProvider.notifier)
          .unblock(relation: widget.relation, actor: widget.actor);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Erro: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.error.withValues(alpha: 0.3), width: 0.8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.block_rounded,
                size: 20, color: AppColors.error),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              widget.relation.userSubId,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.secondary),
            )
          else
            TextButton(
              onPressed: _unblock,
              child: const Text('Desbloquear',
                  style: TextStyle(
                      color: AppColors.secondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

Future<void> _confirmBlock(
  BuildContext context,
  WidgetRef ref,
  AccessRelation relation,
  String centralId,
  String actor,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: ctx.surfaceColor,
      title:
          Text('Bloquear usuário?', style: TextStyle(color: ctx.textPrimary)),
      content: Text(
        'O acesso será revogado imediatamente e futuras solicitações deste usuário serão ignoradas.',
        style: TextStyle(color: ctx.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancelar', style: TextStyle(color: ctx.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child:
              const Text('Bloquear', style: TextStyle(color: AppColors.error)),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    await ref
        .read(centralAccessRelationsProvider.notifier)
        .block(relation: relation, centralId: centralId, actor: actor);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Erro: $e'), behavior: SnackBarBehavior.floating),
      );
    }
  }
}

// ── Level-change PIN sheet ──────────────────────────────────────────────────

class _LevelChangeSheet extends ConsumerStatefulWidget {
  const _LevelChangeSheet({
    required this.relation,
    required this.centralId,
    required this.actor,
  });
  final AccessRelation relation;
  final String centralId;

  /// Role proven at the Acessos screen gate — the authority for the change
  /// (Nível 4 or Master) and the actor recorded in the audit trail.
  final EditorRole actor;

  @override
  ConsumerState<_LevelChangeSheet> createState() => _LevelChangeSheetState();
}

class _LevelChangeSheetState extends ConsumerState<_LevelChangeSheet> {
  AccessLevel? _selected;
  final _rootCtrl = TextEditingController();
  final _senhaCtrl = TextEditingController();
  String? _error;
  bool _saving = false;

  /// Granting MASTER or demoting the current MASTER — both are gated by the
  /// root + senha device-ownership credentials on top of the screen gate.
  bool get _isMasterOp =>
      _selected == AccessLevel.master ||
      widget.relation.level == AccessLevel.master;

  @override
  void dispose() {
    _rootCtrl.dispose();
    _senhaCtrl.dispose();
    super.dispose();
  }

  void _selectLevel(AccessLevel level) {
    if (_saving) return;
    setState(() {
      _selected = level;
      _error = null;
    });
  }

  Future<void> _submitMasterOp() async {
    final level = _selected!;

    // Only one MASTER per central, ever.
    if (level == AccessLevel.master) {
      final hasOtherMaster = ref.read(centralGrantedProvider).any((r) =>
          r.level == AccessLevel.master &&
          r.userSubId != widget.relation.userSubId);
      if (hasOtherMaster) {
        setState(() => _error = 'Já existe um usuário MASTER nesta central.');
        return;
      }
    }

    setState(() => _saving = true);
    final outcome = await ref
        .read(credentialsAdminProvider)
        .verifyRootCredentials(_rootCtrl.text.trim(), _senhaCtrl.text);
    if (!mounted) return;

    switch (outcome) {
      case VerifyOk():
        break;
      case VerifyUnset():
        setState(() {
          _saving = false;
          _error = 'Credenciais root não configuradas.';
        });
        return;
      case VerifyLocked(:final remaining):
        setState(() {
          _saving = false;
          _error = 'Muitas tentativas. Aguarde ${remaining.inSeconds}s.';
        });
        return;
      case VerifyWrong():
        setState(() {
          _saving = false;
          _error = 'Root ou senha incorretos.';
        });
        return;
    }

    await _applyChange(level, alreadySaving: true);
  }

  Future<void> _applyChange(AccessLevel level,
      {bool alreadySaving = false}) async {
    if (!alreadySaving) setState(() => _saving = true);
    try {
      await ref.read(centralAccessRelationsProvider.notifier).changeLevel(
            relation: widget.relation,
            level: level,
            centralId: widget.centralId,
            masterRemoval: widget.relation.level == AccessLevel.master &&
                level != AccessLevel.master,
            actor: widget.actor.auditName,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Erro ao alterar nível.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final currentLevel = widget.relation.level;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: context.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Alterar nível de acesso',
              style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              widget.relation.userSubId,
              style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 11,
                  fontFamily: 'monospace'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: AccessLevel.values.map((level) {
                final selected = _selected == level;
                final isCurrent = currentLevel == level;
                return ChoiceChip(
                  label: Text(level.shortLabel),
                  selected: selected,
                  onSelected: (_) => _selectLevel(level),
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : level.color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                  backgroundColor: level.color.withValues(alpha: 0.10),
                  selectedColor: level.color,
                  side: BorderSide(
                    color: isCurrent
                        ? level.color
                        : level.color.withValues(alpha: 0.3),
                    width: isCurrent ? 1.4 : 0.8,
                  ),
                  avatar: isCurrent && !selected
                      ? Icon(Icons.check_circle_rounded,
                          size: 14, color: level.color)
                      : null,
                );
              }).toList(),
            ),
            if (_selected != null && _isMasterOp) ...[
              const SizedBox(height: 24),
              Center(
                child: Text(
                  _selected == AccessLevel.master
                      ? 'Conceder MASTER exige as credenciais root desta central.'
                      : 'Remover o usuário MASTER exige as credenciais root desta central.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
              _RootCredentialField(controller: _rootCtrl, hint: 'Root'),
              const SizedBox(height: 10),
              _RootCredentialField(
                  controller: _senhaCtrl, hint: 'Senha', obscure: true),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Center(
                  child: Text(_error!,
                      style: const TextStyle(
                          color: AppColors.error, fontSize: 12)),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _submitMasterOp,
                  style: FilledButton.styleFrom(
                    backgroundColor: AccessLevel.master.color,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          'Confirmar',
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                ),
              ),
            ] else if (_selected != null &&
                _selected != widget.relation.level) ...[
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'Alterar para ${_selected!.label}, autorizado como ${widget.actor.label}.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Center(
                  child: Text(_error!,
                      style: const TextStyle(
                          color: AppColors.error, fontSize: 12)),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : () => _applyChange(_selected!),
                  style: FilledButton.styleFrom(
                    backgroundColor: _selected!.color,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          'Confirmar ${_selected!.shortLabel}',
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
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

class _RootCredentialField extends StatelessWidget {
  const _RootCredentialField({
    required this.controller,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AccessLevel.master.color.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: TextStyle(color: context.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: context.textSecondary.withValues(alpha: 0.5),
            fontSize: 13,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

// ── Add access button ─────────────────────────────────────────────────────────

class _AddAccessButton extends StatelessWidget {
  const _AddAccessButton();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const MyQrScreen()),
        ),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              colors: [
                AppColors.secondary.withValues(alpha: 0.04),
                AppColors.secondary.withValues(alpha: 0.09),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: AppColors.secondary,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Adicionar acesso',
                style: TextStyle(
                  color: AppColors.secondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pending section header ────────────────────────────────────────────────────

class _PendingSectionHeader extends StatelessWidget {
  const _PendingSectionHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'SOLICITAÇÕES PENDENTES',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              color: AppColors.warning,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Pending request card ──────────────────────────────────────────────────────

class _PendingRequestCard extends ConsumerStatefulWidget {
  const _PendingRequestCard({
    required this.relation,
    required this.centralId,
    required this.actor,
  });

  final AccessRelation relation;
  final String centralId;
  final String actor;

  @override
  ConsumerState<_PendingRequestCard> createState() =>
      _PendingRequestCardState();
}

class _PendingRequestCardState extends ConsumerState<_PendingRequestCard> {
  bool _loading = false;

  Future<void> _resolve(String decision) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await ref.read(centralAccessRelationsProvider.notifier).resolve(
            relation: widget.relation,
            decision: decision,
            centralId: widget.centralId,
            actor: widget.actor,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _block() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await ref.read(centralAccessRelationsProvider.notifier).block(
            relation: widget.relation,
            centralId: widget.centralId,
            actor: widget.actor,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.relation;
    final since = _timeSince(req.requestedAt);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.person_outline_rounded,
              size: 20,
              color: AppColors.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  req.userSubId,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.warning,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Pendente · $since',
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.secondary,
                ),
              ),
            )
          else ...[
            _ActionButton(
              icon: Icons.check_rounded,
              color: AppColors.success,
              onTap: () => _resolve('ACCEPTED'),
            ),
            const SizedBox(width: 6),
            _ActionButton(
              icon: Icons.close_rounded,
              color: AppColors.error,
              onTap: () => _resolve('REJECTED'),
            ),
            const SizedBox(width: 6),
            _ActionButton(
              icon: Icons.block_rounded,
              color: context.textSecondary,
              onTap: _block,
            ),
          ],
        ],
      ),
    );
  }

  String _timeSince(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'agora';
    if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'há ${diff.inHours} h';
    return 'há ${diff.inDays} d';
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: color.withValues(alpha: 0.3),
            width: 0.8,
          ),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
