import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Reusable 6-digit OTP input: a hidden TextField overlaid by six visual boxes.
///
/// Keeping the TextField stable (never rebuilt during typing) avoids the iOS
/// UIKit keyboard constraint warnings that occur when the field is recreated
/// on every keystroke.
class OtpInputRow extends StatelessWidget {
  const OtpInputRow({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (enabled) focusNode.requestFocus();
      },
      child: Stack(
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([controller, focusNode]),
            builder: (context, _) {
              final text = controller.text;
              final hasFocus = focusNode.hasFocus;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(6, (i) {
                  final char = i < text.length ? text[i] : '';
                  final isActive = hasFocus && i == text.length.clamp(0, 5);
                  return _DigitBox(
                    char: char,
                    isActive: isActive,
                    enabled: enabled,
                  );
                }),
              );
            },
          ),
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                key: const ValueKey('_otp_hidden'),
                controller: controller,
                focusNode: focusNode,
                enabled: enabled,
                maxLength: 6,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: false,
                  signed: false,
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                autofillHints: const [AutofillHints.oneTimeCode],
                textInputAction: TextInputAction.done,
                onEditingComplete: () {},
                autocorrect: false,
                enableSuggestions: false,
                onChanged: onChanged,
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DigitBox extends StatelessWidget {
  const _DigitBox({
    required this.char,
    required this.isActive,
    required this.enabled,
  });

  final String char;
  final bool isActive;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final borderColor = isActive
        ? AppColors.secondary
        : char.isNotEmpty
            ? AppColors.secondary.withValues(alpha: 0.5)
            : AppColors.divider;
    final borderWidth = isActive ? 2.0 : 1.0;

    return Container(
      width: 48,
      height: 60,
      decoration: BoxDecoration(
        color: enabled
            ? AppColors.surfaceDark
            : AppColors.surfaceDark.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
          color: enabled
              ? AppColors.textPrimaryDark
              : AppColors.textPrimaryDark.withValues(alpha: 0.5),
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
