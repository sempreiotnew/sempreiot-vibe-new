import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../shared/widgets/pin_pad.dart';
import '../../application/credentials_admin_provider.dart';

/// PIN challenge that identifies the operator: the Master PIN or the
/// Nível 4 PIN unlock it, and which one was typed determines the role
/// handed to [onUnlocked]. Used to gate the Acessos screen and the PIN
/// management area, so every action past it can be attributed to a role.
class EditorGate extends ConsumerStatefulWidget {
  const EditorGate({
    super.key,
    required this.onUnlocked,
    required this.subtitle,
  });

  final ValueChanged<EditorRole> onUnlocked;
  final String subtitle;

  @override
  ConsumerState<EditorGate> createState() => _EditorGateState();
}

class _EditorGateState extends ConsumerState<EditorGate> {
  final List<String> _digits = [];
  String? _error;
  bool _busy = false;

  void _onDigit(String d) {
    if (_digits.length >= 6 || _busy) return;
    setState(() {
      _digits.add(d);
      _error = null;
    });
    if (_digits.length == 6) _submit();
  }

  void _onDelete() {
    if (_digits.isEmpty || _busy) return;
    setState(() => _digits.removeLast());
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final (outcome, role) =
        await ref.read(credentialsAdminProvider).identifyEditor(_digits.join());
    if (!mounted) return;
    setState(() => _busy = false);

    if (outcome is VerifyOk && role != null) {
      widget.onUnlocked(role);
      return;
    }

    setState(() {
      _error = switch (outcome) {
        VerifyLocked(:final remaining) =>
          'Muitas tentativas. Aguarde ${remaining.inSeconds}s.',
        _ => 'PIN incorreto.',
      };
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _digits.clear());
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.admin_panel_settings_rounded,
                    size: 40,
                    color: AppColors.secondary.withValues(alpha: 0.8)),
                const SizedBox(height: 20),
                Text(
                  'Acesso restrito',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 32),
                PinDots(filledCount: _digits.length, hasError: _error != null),
                const SizedBox(height: 14),
                AnimatedOpacity(
                  opacity: _error != null ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _error ?? '',
                    style:
                        const TextStyle(fontSize: 13, color: AppColors.error),
                  ),
                ),
                const SizedBox(height: 32),
                AnimatedOpacity(
                  opacity: _busy ? 0.4 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: PinPad(onDigit: _onDigit, onDelete: _onDelete),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
