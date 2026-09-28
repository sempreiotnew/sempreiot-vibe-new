import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/user_access_provider.dart';
import '../../data/services/lookup_api_service.dart';
import '../../domain/entities/saved_central.dart';

/// Bottom sheet that edits this user's local nickname for a central.
/// Purely local — other users are not affected; the subId shown below the
/// field is the central's real identity.
class RenameCentralSheet extends ConsumerStatefulWidget {
  const RenameCentralSheet({super.key, required this.central});

  final SavedCentral central;

  @override
  ConsumerState<RenameCentralSheet> createState() =>
      _RenameCentralSheetState();
}

class _RenameCentralSheetState extends ConsumerState<RenameCentralSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.central.name);

  bool _restoring = false;
  String? _restoreError;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Re-fetches the official name (Device table) via the existing lookup.
  Future<void> _restoreOfficial() async {
    if (_restoring) return;
    setState(() {
      _restoring = true;
      _restoreError = null;
    });
    try {
      final info =
          await LookupApiService.lookupByIdentityId(widget.central.identityId);
      if (!mounted) return;
      _ctrl.text = info.displayName;
    } catch (_) {
      if (!mounted) return;
      setState(() =>
          _restoreError = 'Não foi possível obter o nome oficial.');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _save() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    ref
        .read(savedCentralsProvider.notifier)
        .updateName(widget.central.identityId, name);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Nome atualizado.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final isWide = MediaQuery.of(context).size.width > 600;

    return Container(
      margin: EdgeInsets.fromLTRB(isWide ? 80 : 12, 0, isWide ? 80 : 12, 12),
      padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + bottomInset),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(24),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Handle ────────────────────────────────────────────────────
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: context.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            Text(
              'Renomear Central',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Este nome é visível apenas para você — outros usuários não '
              'são afetados.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 20),

            // ── Name field ────────────────────────────────────────────────
            const _SectionLabel('NOME'),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: context.bgColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.secondary.withValues(alpha: 0.35),
                  width: 1.2,
                ),
              ),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                maxLength: 40,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: 'Nome da central...',
                  hintStyle: TextStyle(
                    color: context.textSecondary.withValues(alpha: 0.4),
                    fontSize: 13,
                  ),
                  counterText: '',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(height: 16),

            // ── Identity ──────────────────────────────────────────────────
            const _SectionLabel('IDENTIDADE'),
            const SizedBox(height: 8),
            Text(
              widget.central.subId,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),

            if (_restoreError != null) ...[
              const SizedBox(height: 8),
              Text(
                _restoreError!,
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 20),

            // ── Actions ───────────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.secondary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Salvar',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: _restoring ? null : _restoreOfficial,
                child: _restoring
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        'Restaurar nome oficial',
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 13,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: context.textSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

void showRenameCentralSheet(BuildContext context, SavedCentral central) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => RenameCentralSheet(central: central),
  );
}
