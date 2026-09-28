import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_ext.dart';
import '../../features/installation/domain/services/installation_backup_codec.dart';

/// Asks for the passphrase that protects an installation backup
/// (lifecycle §2). Returns null when cancelled. With [confirm], the operator
/// types it twice (creating a share); without, once (opening a share).
Future<String?> showPassphraseDialog(
  BuildContext context, {
  required String title,
  required String message,
  bool confirm = false,
  String actionLabel = 'Continuar',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PassphraseDialog(
      title: title,
      message: message,
      confirm: confirm,
      actionLabel: actionLabel,
    ),
  );
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.title,
    required this.message,
    required this.confirm,
    required this.actionLabel,
  });

  final String title;
  final String message;
  final bool confirm;
  final String actionLabel;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _first.text;
    if (value.length < InstallationBackupCodec.minPassphraseLength) {
      setState(() => _error =
          'Use pelo menos ${InstallationBackupCodec.minPassphraseLength} caracteres.');
      return;
    }
    if (widget.confirm && value != _second.text) {
      setState(() => _error = 'As senhas não conferem.');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message,
                style: TextStyle(color: context.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: _first,
              autofocus: true,
              obscureText: _obscure,
              textInputAction:
                  widget.confirm ? TextInputAction.next : TextInputAction.done,
              onSubmitted: widget.confirm ? null : (_) => _submit(),
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                labelText: 'Senha',
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _second,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                onChanged: (_) => setState(() => _error = null),
                decoration: const InputDecoration(labelText: 'Repita a senha'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: AppColors.error, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
    );
  }
}
