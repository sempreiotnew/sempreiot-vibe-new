import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../access/domain/entities/access_level.dart';
import '../../application/credentials_admin_provider.dart';

/// Read-only view of the central's audit trail: PIN changes, grants,
/// blocks, failed attempts and lockouts, newest first — written for
/// operators, not developers: friendly labels and the same colored level
/// tags used across the access screens.
class AuditLogScreen extends ConsumerWidget {
  const AuditLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trail = ref.watch(auditTrailProvider);

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          'Registro de Atividades',
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
      body: trail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Erro ao carregar registro.',
              style: TextStyle(color: context.textSecondary)),
        ),
        data: (events) => events.isEmpty
            ? Center(
                child: Text(
                  'Nenhuma atividade registrada.',
                  style: TextStyle(
                      color: context.textSecondary.withValues(alpha: 0.6),
                      fontSize: 13),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                itemCount: events.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _AuditRow(event: events[i]),
              ),
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.event});
  final AuditEvent event;

  static const _labels = <String, String>{
    'pin_changed': 'PIN alterado',
    'pin_reset': 'PIN redefinido',
    'unlock_pin_changed': 'PIN de desbloqueio alterado',
    'unlock_pin_reset': 'PIN de desbloqueio redefinido',
    'unlock_pin_initialized': 'PIN de desbloqueio criado',
    'root_changed': 'Root alterado',
    'senha_changed': 'Senha alterada',
    'credentials_hashed': 'Credenciais protegidas',
    'auth_failed': 'Tentativa de PIN incorreta',
    'gate_locked': 'Bloqueado por excesso de tentativas',
    'level_granted': 'Nível concedido',
    'level_changed': 'Nível de acesso alterado',
    'master_granted': 'Usuário MASTER adicionado',
    'master_removed': 'Usuário MASTER removido',
    'user_blocked': 'Usuário bloqueado',
    'user_unblocked': 'Usuário desbloqueado',
    'access_accepted': 'Solicitação de acesso aceita',
    'access_rejected': 'Solicitação de acesso recusada',
    'editor_unlocked': 'Área restrita acessada',
  };

  static const _actorLabels = <String, String>{
    'master': 'Master',
    'admin': 'Administrador',
    'root': 'Root',
    'system': 'Sistema',
    'central': 'Central',
  };

  /// Where a failed attempt happened, in operator language.
  static const _gateLabels = <String, String>{
    'master_pin': 'PIN Master',
    'unlock_pin': 'Desbloqueio da central',
    'pin_editor': 'PINs de Acesso',
    'root': 'Credenciais root',
    'level_pin_LEVEL_1': 'PIN Nível 1',
    'level_pin_LEVEL_2': 'PIN Nível 2',
    'level_pin_LEVEL_3': 'PIN Nível 3',
    'level_pin_LEVEL_4': 'PIN Nível 4',
  };

  bool get _isWarning =>
      event.action == 'auth_failed' || event.action == 'gate_locked';

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> detail;
    try {
      detail = jsonDecode(event.detail) as Map<String, dynamic>;
    } catch (_) {
      detail = {};
    }

    final label = _labels[event.action] ?? event.action;
    final actor = _actorLabels[event.actor] ?? event.actor;

    final levelWire = detail['level'] as String?;
    final level = AccessLevel.fromWire(levelWire);
    final gate = _gateLabels[detail['gate'] as String?];
    final userSubId = detail['userSubId'] as String?;
    final lockSeconds = detail['lockSeconds'];

    final at = event.at;
    final timestamp =
        '${at.day.toString().padLeft(2, '0')}/${at.month.toString().padLeft(2, '0')}'
        '/${at.year} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

    final color = _isWarning ? AppColors.error : AppColors.secondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _isWarning ? Icons.warning_amber_rounded : Icons.history_rounded,
              size: 17,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  gate != null && event.action == 'auth_failed'
                      ? 'Tentativa incorreta — $gate'
                      : label,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _Tag(text: actor, color: _actorColor(event.actor, context)),
                    if (level != null)
                      _Tag(text: level.shortLabel, color: level.color),
                    if (levelWire == 'MASTER_PIN')
                      const _Tag(text: 'PIN MASTER', color: AppColors.error),
                    if (gate != null && event.action == 'gate_locked')
                      _Tag(text: gate, color: AppColors.error),
                    if (lockSeconds != null)
                      Text(
                        'bloqueio de ${lockSeconds}s',
                        style: TextStyle(
                            color: context.textSecondary.withValues(alpha: 0.8),
                            fontSize: 11),
                      ),
                  ],
                ),
                if (userSubId != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    userSubId,
                    style: TextStyle(
                      color: context.textSecondary.withValues(alpha: 0.7),
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            timestamp,
            style: TextStyle(
              color: context.textSecondary.withValues(alpha: 0.6),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Color _actorColor(String actor, BuildContext context) => switch (actor) {
        'master' => AppColors.error,
        'admin' => AccessLevel.level4.color,
        'root' => const Color(0xFF8B5CF6),
        _ => context.textSecondary,
      };
}

/// Small colored badge — same visual language as the level chips on the
/// access screens.
class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
