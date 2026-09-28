import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_ext.dart';

/// Six filled/empty dots that visualise PIN entry progress.
class PinDots extends StatelessWidget {
  const PinDots({
    super.key,
    required this.filledCount,
    this.hasError = false,
  });

  final int filledCount;
  final bool hasError;

  static const int _length = 6;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_length, (i) {
        final filled = i < filledCount;
        final color = hasError
            ? AppColors.error
            : filled
                ? AppColors.secondary
                : Colors.transparent;
        final borderColor = hasError
            ? AppColors.error
            : filled
                ? AppColors.secondary
                : context.borderColor;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: borderColor, width: 2),
          ),
        );
      }),
    );
  }
}

/// 3×4 numeric keypad — theme-aware.
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.keyWidth = 72,
    this.keyHeight = 64,
    this.rowGap = 12,
  });

  final void Function(String) onDigit;
  final VoidCallback onDelete;
  final double keyWidth;
  final double keyHeight;
  final double rowGap;

  static const _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', 'del'],
  ];

  @override
  Widget build(BuildContext context) {
    final hPad = (keyWidth * 0.13).clamp(6.0, 12.0);
    final slotW = keyWidth + hPad * 2;
    final fontSize = (keyHeight * 0.38).clamp(16.0, 28.0);
    final iconSize = (keyHeight * 0.30).clamp(14.0, 22.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _keys.map((row) {
        return Padding(
          padding: EdgeInsets.only(bottom: rowGap),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map((key) {
              if (key.isEmpty) {
                return SizedBox(width: slotW, height: keyHeight);
              }
              if (key == 'del') {
                return _PinKey(
                  keyWidth: keyWidth,
                  keyHeight: keyHeight,
                  onTap: onDelete,
                  child: Icon(
                    Icons.backspace_outlined,
                    color: context.textSecondary,
                    size: iconSize,
                  ),
                );
              }
              return _PinKey(
                keyWidth: keyWidth,
                keyHeight: keyHeight,
                onTap: () => onDigit(key),
                child: Text(
                  key,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w400,
                    color: context.textPrimary,
                  ),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}

class _PinKey extends StatelessWidget {
  const _PinKey({
    required this.child,
    required this.onTap,
    required this.keyWidth,
    required this.keyHeight,
  });

  final Widget child;
  final VoidCallback onTap;
  final double keyWidth;
  final double keyHeight;

  @override
  Widget build(BuildContext context) {
    final hPad = (keyWidth * 0.13).clamp(6.0, 12.0);
    final radius = (keyHeight * 0.22).clamp(10.0, 18.0);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Material(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Container(
            width: keyWidth,
            height: keyHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: context.borderColor.withValues(alpha: 0.6),
                width: 0.5,
              ),
            ),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}
