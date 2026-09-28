import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/theme_ext.dart';

// ── Section header ────────────────────────────────────────────────────────────

class InfoSectionHeader extends StatelessWidget {
  const InfoSectionHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: context.textSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.4,
      ),
    );
  }
}

// ── Card wrapper ──────────────────────────────────────────────────────────────

class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

// ── Row divider ───────────────────────────────────────────────────────────────

class InfoRowDivider extends StatelessWidget {
  const InfoRowDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 0.5,
      thickness: 0.5,
      indent: 16,
      endIndent: 16,
      color: context.borderColor.withValues(alpha: 0.5),
    );
  }
}

// ── Read-only row ─────────────────────────────────────────────────────────────

class InfoReadRow extends StatelessWidget {
  const InfoReadRow({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.mono = false,
    this.canCopy = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool mono;
  final bool canCopy;

  @override
  Widget build(BuildContext context) {
    final empty = value.isEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                        : context.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    fontFamily: mono ? 'monospace' : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (canCopy && !empty)
            IconButton(
              icon: Icon(
                Icons.copy_rounded,
                size: 16,
                color: context.textSecondary.withValues(alpha: 0.5),
              ),
              tooltip: 'Copiar',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$label copiado.'),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            )
          else
            Icon(
              Icons.lock_outline_rounded,
              size: 14,
              color: context.textSecondary.withValues(alpha: 0.25),
            ),
        ],
      ),
    );
  }
}
