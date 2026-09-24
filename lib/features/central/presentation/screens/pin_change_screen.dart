import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../access/domain/entities/access_level.dart';
import '../../application/credentials_admin_provider.dart';
import '../../application/device_metadata_providers.dart';
import '../../../../shared/widgets/pin_pad.dart';

enum _PinStep { current, newPin, confirm }

extension on _PinStep {
  String get title => switch (this) {
        _PinStep.current => 'Digite o PIN atual',
        _PinStep.newPin => 'Digite o novo PIN',
        _PinStep.confirm => 'Confirme o novo PIN',
      };
}

/// Current → new → confirm flow for any PIN on this central.
///
/// Targets, in priority order: [unlock] true → the unlock PIN; [level]
/// set → that level's PIN; neither → the master PIN. [skipCurrent] skips
/// the current-PIN step — the Master-only path for resetting a forgotten
/// PIN or setting one for the first time; the service re-validates that.
class PinChangeScreen extends ConsumerStatefulWidget {
  const PinChangeScreen({
    super.key,
    this.level,
    this.unlock = false,
    this.skipCurrent = false,
    this.editorRole = EditorRole.master,
  }) : assert(!(unlock && level != null));

  final AccessLevel? level;
  final bool unlock;
  final bool skipCurrent;
  final EditorRole editorRole;

  @override
  ConsumerState<PinChangeScreen> createState() => _PinChangeScreenState();
}

class _PinChangeScreenState extends ConsumerState<PinChangeScreen> {
  late _PinStep _step = widget.skipCurrent ? _PinStep.newPin : _PinStep.current;
  final List<String> _digits = [];
  String? _currentPinValue;
  String _newPinValue = '';
  String? _errorMessage;
  bool _busy = false;

  String get _title => widget.unlock
      ? 'PIN de Desbloqueio'
      : widget.level == null
          ? 'Alterar PIN'
          : 'PIN ${widget.level!.shortLabel}';

  // ── Input handlers ────────────────────────────────────────────────────────

  void _onDigit(String d) {
    if (_digits.length >= 6 || _busy) return;
    setState(() {
      _digits.add(d);
      _errorMessage = null;
    });
    if (_digits.length == 6) _onComplete();
  }

  void _onDelete() {
    if (_digits.isEmpty || _busy) return;
    setState(() {
      _digits.removeLast();
      _errorMessage = null;
    });
  }

  void _clearWithError(String message) {
    setState(() => _errorMessage = message);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _digits.clear());
    });
  }

  // ── Step completion ───────────────────────────────────────────────────────

  Future<void> _onComplete() async {
    final entered = _digits.join();

    switch (_step) {
      case _PinStep.current:
        await _validateCurrentPin(entered);
      case _PinStep.newPin:
        _advanceToConfirm(entered);
      case _PinStep.confirm:
        await _confirmAndSave(entered);
    }
  }

  Future<void> _validateCurrentPin(String entered) async {
    setState(() => _busy = true);
    final creds = ref.read(credentialsAdminProvider);

    final outcome = widget.unlock
        ? await creds.verifyUnlockPin(entered)
        : widget.level == null
            ? await creds.verifyMasterPin(entered)
            : await creds.verifyLevelPin(widget.level!, entered);

    if (!mounted) return;
    setState(() => _busy = false);

    switch (outcome) {
      case VerifyOk():
        setState(() {
          _currentPinValue = entered;
          _step = _PinStep.newPin;
          _digits.clear();
          _errorMessage = null;
        });
      case VerifyUnset():
        _clearWithError('PIN não configurado.');
      case VerifyLocked(:final remaining):
        _clearWithError('Muitas tentativas. Aguarde ${remaining.inSeconds}s.');
      case VerifyWrong():
        _clearWithError('PIN incorreto. Tente novamente.');
    }
  }

  void _advanceToConfirm(String entered) {
    setState(() {
      _newPinValue = entered;
      _step = _PinStep.confirm;
      _digits.clear();
      _errorMessage = null;
    });
  }

  Future<void> _confirmAndSave(String entered) async {
    if (entered != _newPinValue) {
      setState(() {
        _step = _PinStep.newPin;
        _newPinValue = '';
        _digits.clear();
      });
      _clearWithError('PINs não coincidem. Tente novamente.');
      return;
    }

    setState(() => _busy = true);
    final creds = ref.read(credentialsAdminProvider);

    final error = widget.unlock
        ? await creds.changeUnlockPin(
            currentPin: widget.skipCurrent ? null : _currentPinValue,
            newPin: entered,
            by: widget.editorRole,
          )
        : widget.level == null
            ? await creds.changeMasterPin(
                currentPin: _currentPinValue!,
                newPin: entered,
              )
            : await creds.changeLevelPin(
                level: widget.level!,
                currentPin: widget.skipCurrent ? null : _currentPinValue,
                newPin: entered,
                by: widget.editorRole,
              );

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _busy = false;
        _step = _PinStep.newPin;
        _newPinValue = '';
        _digits.clear();
      });
      _clearWithError(error);
      return;
    }

    ref.invalidate(deviceCredentialsProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('PIN alterado com sucesso.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
    Navigator.of(context).pop(true);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasError = _errorMessage != null;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          _title,
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
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 12),

                  // Step indicator
                  _StepIndicator(
                    current: _step,
                    steps: widget.skipCurrent
                        ? const [_PinStep.newPin, _PinStep.confirm]
                        : _PinStep.values,
                  ),
                  const SizedBox(height: 32),

                  // Title
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      _step.title,
                      key: ValueKey(_step),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 36),

                  // PIN dots
                  PinDots(
                    filledCount: _digits.length,
                    hasError: hasError,
                  ),
                  const SizedBox(height: 14),

                  // Error label
                  AnimatedOpacity(
                    opacity: hasError ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _errorMessage ?? '',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: 36),

                  // Numpad
                  AnimatedOpacity(
                    opacity: _busy ? 0.4 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: PinPad(
                      onDigit: _onDigit,
                      onDelete: _onDelete,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Step indicator ────────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.current, required this.steps});
  final _PinStep current;
  final List<_PinStep> steps;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: steps.map((step) {
        final done = step.index < current.index;
        final active = step == current;
        final color =
            (done || active) ? AppColors.secondary : context.borderColor;

        return Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              width: active ? 28 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            if (step != steps.last)
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 12,
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: done
                    ? AppColors.secondary.withValues(alpha: 0.5)
                    : context.borderColor.withValues(alpha: 0.4),
              ),
          ],
        );
      }).toList(),
    );
  }
}
