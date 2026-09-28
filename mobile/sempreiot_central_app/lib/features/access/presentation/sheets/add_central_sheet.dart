import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/user_access_provider.dart';
import '../../domain/entities/lookup_result.dart';
import '../../../../shared/widgets/presence_indicator.dart';
import 'package:sempreiot_central_app/features/access/presentation/screens/qr_scanner_screen.dart';

/// Strips the `Exception: ` prefix so the guard messages thrown by
/// RequestAccessNotifier.request() (already user-facing Portuguese text)
/// show as-is instead of a generic fallback that would mask them.
String _friendlyError(Object e) {
  final msg = e.toString();
  const prefix = 'Exception: ';
  return msg.startsWith(prefix) ? msg.substring(prefix.length) : 'Falha ao enviar. Verifique a conexão.';
}

/// Bottom sheet that lets a user add a central by entering its Sub ID (or
/// scanning the central's QR code) and requesting access.
class AddCentralSheet extends ConsumerStatefulWidget {
  const AddCentralSheet({super.key});

  @override
  ConsumerState<AddCentralSheet> createState() => _AddCentralSheetState();
}

class _AddCentralSheetState extends ConsumerState<AddCentralSheet> {
  final _ctrl = TextEditingController();
  final _focusNode = FocusNode();

  LookupResult? _found;
  bool _searching = false;
  String? _searchError;

  bool _submitting = false;
  String? _submitError;

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    if (kIsWeb) return;
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrScannerScreen()),
    );
    if (!mounted || scanned == null || scanned.trim().isEmpty) return;
    _ctrl.text = scanned.trim();
    setState(() {
      _found = null;
      _searchError = null;
    });
    _search();
  }

  Future<void> _search() async {
    final id = _ctrl.text.trim();
    if (id.isEmpty) return;

    if (!mounted) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _found = null;
    });

    try {
      final result = await ref.read(lookupProvider(id).future);
      if (!mounted) return;
      setState(() => _found = result);
    } on Exception catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('Not found')
          ? 'Central não encontrada.'
          : 'Erro ao buscar central. Tente novamente.';
      setState(() => _searchError = msg);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _submit() async {
    if (_found == null || _submitting) return;

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      await ref.read(requestAccessProvider.notifier).request(
            centralSubId: _found!.subId,
            centralIdentityId: _found!.identityId,
            centralName: _found!.displayName,
          );

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Solicitação enviada! Aguardando aprovação.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = _friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final isWide = MediaQuery.of(context).size.width > 600;

    return Container(
      margin: EdgeInsets.fromLTRB(
          isWide ? 80 : 12, 0, isWide ? 80 : 12, 12),
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
              'Adicionar Central',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              kIsWeb
                  ? 'Insira o Sub ID da central.'
                  : 'Escaneie o QR Code ou insira o Sub ID da central.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 20),

            // ── ID field + buttons ────────────────────────────────────────
            const _SectionLabel('ID DA CENTRAL'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: context.bgColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _searchError != null
                            ? AppColors.error.withValues(alpha: 0.6)
                            : AppColors.secondary.withValues(alpha: 0.35),
                        width: 1.2,
                      ),
                    ),
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focusNode,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 14,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        hintText: 'Sub ID da central...',
                        hintStyle: TextStyle(
                          color: context.textSecondary.withValues(alpha: 0.4),
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        border: InputBorder.none,
                        suffixIcon: _ctrl.text.isNotEmpty
                            ? IconButton(
                                icon: Icon(
                                  Icons.clear_rounded,
                                  size: 16,
                                  color: context.textSecondary,
                                ),
                                onPressed: () {
                                  _ctrl.clear();
                                  setState(() {
                                    _found = null;
                                    _searchError = null;
                                  });
                                },
                              )
                            : null,
                      ),
                      onChanged: (_) => setState(() {
                        _found = null;
                        _searchError = null;
                      }),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                ),
                // Camera scan button (mobile only)
                if (!kIsWeb) ...[
                  const SizedBox(width: 10),
                  _IconActionButton(
                    icon: Icons.qr_code_scanner_rounded,
                    color: context.textPrimary,
                    backgroundColor: context.bgColor,
                    borderColor: AppColors.secondary.withValues(alpha: 0.35),
                    onTap: _scanQr,
                  ),
                ],
                const SizedBox(width: 8),
                _SearchButton(
                  loading: _searching,
                  onTap: _search,
                ),
              ],
            ),

            // ── Error ─────────────────────────────────────────────────────
            if (_searchError != null) ...[
              const SizedBox(height: 8),
              Text(
                _searchError!,
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 12,
                ),
              ),
            ],

            // ── Central info card ─────────────────────────────────────────
            if (_found != null) ...[
              const SizedBox(height: 16),
              _FoundCentralCard(result: _found!),
              if (_submitError != null) ...[
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    _submitError!,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _SubmitButton(
                enabled: !_submitting,
                loading: _submitting,
                onTap: _submit,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Supporting widgets ────────────────────────────────────────────────────────

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
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _IconActionButton extends StatelessWidget {
  const _IconActionButton({
    required this.icon,
    required this.color,
    required this.backgroundColor,
    required this.borderColor,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final Color backgroundColor;
  final Color borderColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: 1.2),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.loading, required this.onTap});
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: loading
              ? AppColors.secondary.withValues(alpha: 0.3)
              : AppColors.secondary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: loading
            ? const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              )
            : const Icon(Icons.search_rounded, color: Colors.white, size: 20),
      ),
    );
  }
}

class _FoundCentralCard extends StatelessWidget {
  const _FoundCentralCard({required this.result});
  final LookupResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.secondary.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.sensors_rounded,
              size: 20,
              color: AppColors.secondary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.displayName,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  result.subId,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                PresenceIndicator(identityId: result.identityId),
              ],
            ),
          ),
          const Icon(
            Icons.check_circle_rounded,
            color: AppColors.success,
            size: 20,
          ),
        ],
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.enabled,
    required this.loading,
    required this.onTap,
  });

  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: enabled ? onTap : null,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.secondary,
          disabledBackgroundColor: AppColors.secondary.withValues(alpha: 0.3),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text(
                'Solicitar Acesso',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

void showAddCentralSheet(BuildContext context) {
  showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AddCentralSheet(),
  );
}
