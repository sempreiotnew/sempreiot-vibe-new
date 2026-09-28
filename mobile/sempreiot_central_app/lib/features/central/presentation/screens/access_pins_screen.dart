import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../access/domain/entities/access_level.dart';
import '../../application/credentials_admin_provider.dart';
import '../../application/device_metadata_providers.dart';
import '../widgets/device_detail_widgets.dart';
import '../widgets/editor_gate.dart';
import 'audit_log_screen.dart';
import 'pin_change_screen.dart';

/// Management area for every credential on this central. Entry is gated by
/// [EditorGate] (Master or Nível 4 PIN) unless the caller already proved a
/// role ([initialRole], e.g. coming from the gated Acessos screen). Master
/// additionally manages root/senha, the master PIN, and can reset forgotten
/// PINs. The role lives only in this screen's state and dies with it.
class AccessPinsScreen extends ConsumerStatefulWidget {
  const AccessPinsScreen({super.key, this.initialRole});

  final EditorRole? initialRole;

  @override
  ConsumerState<AccessPinsScreen> createState() => _AccessPinsScreenState();
}

class _AccessPinsScreenState extends ConsumerState<AccessPinsScreen> {
  late EditorRole? _role = widget.initialRole;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          'PINs de Acesso',
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
      body: _role == null
          ? EditorGate(
              subtitle: 'Digite o PIN Master ou o PIN de Nível 4\n'
                  'para gerenciar os PINs desta central.',
              onUnlocked: (role) => setState(() => _role = role),
            )
          : _PinManagementBody(role: _role!),
    );
  }
}

// ── Management body ───────────────────────────────────────────────────────────

class _PinManagementBody extends ConsumerWidget {
  const _PinManagementBody({required this.role});
  final EditorRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(configuredLevelPinsProvider).valueOrNull ?? {};
    final rootUser = ref.watch(rootUserProvider).valueOrNull ?? '';
    final isMaster = role == EditorRole.master;

    final levels = AccessLevel.values.where((l) => l != AccessLevel.master);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        Row(
          children: [
            Icon(
              isMaster
                  ? Icons.shield_rounded
                  : Icons.admin_panel_settings_outlined,
              size: 15,
              color: isMaster ? AppColors.error : AccessLevel.level4.color,
            ),
            const SizedBox(width: 6),
            Text(
              'Sessão: ${role.label}',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const InfoSectionHeader('DESBLOQUEIO'),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            'PIN usado apenas para desbloquear a tela da central.',
            style: TextStyle(color: context.textSecondary, fontSize: 12),
          ),
        ),
        InfoCard(
          children: [
            _UnlockPinRow(role: role),
          ],
        ),
        const SizedBox(height: 24),
        const InfoSectionHeader('PINS DE NÍVEL'),
        const SizedBox(height: 10),
        InfoCard(
          children: [
            for (final (i, level) in levels.indexed) ...[
              if (i > 0) const InfoRowDivider(),
              _LevelPinRow(
                level: level,
                configured: configured[level] ?? false,
                role: role,
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        if (isMaster) ...[
          const InfoSectionHeader('MASTER'),
          const SizedBox(height: 10),
          InfoCard(
            children: [
              _NavRow(
                icon: Icons.pin_rounded,
                label: 'PIN Master',
                value: '••••••',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PinChangeScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const InfoSectionHeader('CREDENCIAIS ROOT'),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Exigidas para adicionar ou remover o usuário MASTER. '
              'Alterações exigem a senha atual.',
              style: TextStyle(color: context.textSecondary, fontSize: 12),
            ),
          ),
          InfoCard(
            children: [
              _NavRow(
                icon: Icons.manage_accounts_rounded,
                label: 'Root',
                value: rootUser.isEmpty ? 'Não definido' : rootUser,
                onTap: () => _showRootEditSheet(context, ref, isSenha: false),
              ),
              const InfoRowDivider(),
              _NavRow(
                icon: Icons.lock_outline_rounded,
                label: 'Senha',
                value: '••••••',
                onTap: () => _showRootEditSheet(context, ref, isSenha: true),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        const InfoSectionHeader('AUDITORIA'),
        const SizedBox(height: 10),
        InfoCard(
          children: [
            _NavRow(
              icon: Icons.receipt_long_rounded,
              label: 'Registro de atividades',
              value: 'PINs, acessos e bloqueios',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AuditLogScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _showRootEditSheet(BuildContext context, WidgetRef ref,
      {required bool isSenha}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RootEditSheet(isSenha: isSenha),
    );
  }
}

// ── Unlock PIN row ────────────────────────────────────────────────────────────

class _UnlockPinRow extends ConsumerWidget {
  const _UnlockPinRow({required this.role});
  final EditorRole role;

  Future<void> _open(BuildContext context, WidgetRef ref,
      {required bool reset}) async {
    if (reset && role != EditorRole.master) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PinChangeScreen(
          unlock: true,
          skipCurrent: reset,
          editorRole: role,
        ),
      ),
    );
    if (changed == true) ref.invalidate(unlockPinConfiguredProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured =
        ref.watch(unlockPinConfiguredProvider).valueOrNull ?? false;
    final isMaster = role == EditorRole.master;
    final canOpen = configured || isMaster;

    return InkWell(
      onTap: canOpen
          ? () => _open(context, ref, reset: !configured)
          : () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Apenas o Master pode definir um PIN não configurado.'),
                  behavior: SnackBarBehavior.floating,
                ),
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.lock_open_rounded,
                  size: 18, color: AppColors.secondary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PIN de Desbloqueio',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    configured ? '••••••' : 'Não configurado',
                    style: TextStyle(
                      color: configured
                          ? context.textSecondary
                          : AppColors.warning,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (configured && isMaster)
              IconButton(
                icon: Icon(Icons.restart_alt_rounded,
                    size: 18,
                    color: context.textSecondary.withValues(alpha: 0.6)),
                tooltip: 'Redefinir sem PIN atual',
                visualDensity: VisualDensity.compact,
                onPressed: () => _open(context, ref, reset: true),
              ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.secondary.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Level PIN row ─────────────────────────────────────────────────────────────

class _LevelPinRow extends ConsumerWidget {
  const _LevelPinRow({
    required this.level,
    required this.configured,
    required this.role,
  });

  final AccessLevel level;
  final bool configured;
  final EditorRole role;

  Future<void> _open(BuildContext context, WidgetRef ref,
      {required bool reset}) async {
    if (reset && role != EditorRole.master) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PinChangeScreen(
          level: level,
          skipCurrent: reset,
          editorRole: role,
        ),
      ),
    );
    if (changed == true) ref.invalidate(configuredLevelPinsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMaster = role == EditorRole.master;
    // Setting a PIN that was never configured has no "current" to type —
    // that's the reset path, so it's Master-only.
    final canOpen = configured || isMaster;

    return InkWell(
      onTap: canOpen
          ? () => _open(context, ref, reset: !configured)
          : () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Apenas o Master pode definir um PIN não configurado.'),
                  behavior: SnackBarBehavior.floating,
                ),
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: level.color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(level.icon, size: 18, color: level.color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${level.shortLabel} — ${level.label}',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    configured ? '••••••' : 'Não configurado',
                    style: TextStyle(
                      color: configured
                          ? context.textSecondary
                          : AppColors.warning,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (configured && isMaster)
              IconButton(
                icon: Icon(Icons.restart_alt_rounded,
                    size: 18,
                    color: context.textSecondary.withValues(alpha: 0.6)),
                tooltip: 'Redefinir sem PIN atual',
                visualDensity: VisualDensity.compact,
                onPressed: () => _confirmReset(context, ref),
              ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.secondary.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Redefinir PIN ${level.shortLabel}?',
            style: TextStyle(color: ctx.textPrimary)),
        content: Text(
          'O PIN atual será descartado sem verificação. Use apenas se o PIN foi esquecido.',
          style: TextStyle(color: ctx.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancelar', style: TextStyle(color: ctx.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Redefinir',
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _open(context, ref, reset: true);
    }
  }
}

// ── Simple nav row ────────────────────────────────────────────────────────────

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: AppColors.secondary),
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
                    value,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
    );
  }
}

// ── Root/senha edit sheet ─────────────────────────────────────────────────────

class _RootEditSheet extends ConsumerStatefulWidget {
  const _RootEditSheet({required this.isSenha});
  final bool isSenha;

  @override
  ConsumerState<_RootEditSheet> createState() => _RootEditSheetState();
}

class _RootEditSheetState extends ConsumerState<_RootEditSheet> {
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    final creds = ref.read(credentialsAdminProvider);
    final error = widget.isSenha
        ? await creds.changeSenha(
            currentSenha: _currentCtrl.text,
            newSenha: _newCtrl.text,
          )
        : await creds.changeRoot(
            currentSenha: _currentCtrl.text,
            newRoot: _newCtrl.text,
          );

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }

    ref.invalidate(rootUserProvider);
    ref.invalidate(deviceCredentialsProvider);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.isSenha ? 'Senha alterada.' : 'Root alterado.'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(20),
      ),
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
            widget.isSenha ? 'Alterar senha' : 'Alterar root',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          _SheetField(
            controller: _currentCtrl,
            hint: 'Senha atual',
            obscure: true,
          ),
          const SizedBox(height: 10),
          _SheetField(
            controller: _newCtrl,
            hint: widget.isSenha ? 'Nova senha' : 'Novo root',
            obscure: widget.isSenha,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: AppColors.error, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.secondary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Salvar',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  const _SheetField({
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
          color: AppColors.secondary.withValues(alpha: 0.4),
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
