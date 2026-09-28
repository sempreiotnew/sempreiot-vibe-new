import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_ext.dart';

/// Reusable, theme-aware search bar.
///
/// Usage:
/// ```dart
/// AppSearchBar(
///   hintText: 'Buscar centrais...',
///   onChanged: (query) => setState(() => _query = query),
/// )
/// ```
class AppSearchBar extends StatefulWidget {
  const AppSearchBar({
    super.key,
    required this.onChanged,
    this.controller,
    this.hintText = 'Pesquisar...',
    this.autofocus = false,
  });

  final ValueChanged<String> onChanged;

  /// Optional external controller. If omitted, the widget manages its own.
  final TextEditingController? controller;

  final String hintText;
  final bool autofocus;

  @override
  State<AppSearchBar> createState() => _AppSearchBarState();
}

class _AppSearchBarState extends State<AppSearchBar>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _ctrl;
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;
  final _focus = FocusNode();
  bool _owns = false;
  bool _focused = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ctrl = TextEditingController();
      _owns = true;
    } else {
      _ctrl = widget.controller!;
    }

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeOutCubic);

    _focus.addListener(_onFocus);
    _ctrl.addListener(_onText);
  }

  void _onFocus() {
    final f = _focus.hasFocus;
    setState(() => _focused = f);
    if (f) {
      _glowCtrl.forward();
    } else {
      _glowCtrl.reverse();
    }
  }

  void _onText() {
    final has = _ctrl.text.isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  void _clear() {
    _ctrl.clear();
    widget.onChanged('');
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ctrl.removeListener(_onText);
    if (_owns) _ctrl.dispose();
    _focus.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: AppColors.secondary.withValues(alpha: 0.13 * _glow.value),
              blurRadius: 18,
              spreadRadius: 0,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: child,
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _focused
                ? AppColors.secondary.withValues(alpha: 0.55)
                : context.borderColor.withValues(alpha: 0.6),
            width: _focused ? 1.3 : 0.5,
          ),
        ),
        child: Row(
          children: [
            // Leading icon — animates color on focus
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 10),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.search_rounded,
                  key: ValueKey(_focused),
                  size: 20,
                  color: _focused
                      ? AppColors.secondary
                      : context.textSecondary.withValues(alpha: 0.45),
                ),
              ),
            ),
            // Text field
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                autofocus: widget.autofocus,
                onChanged: widget.onChanged,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    color: context.textSecondary.withValues(alpha: 0.5),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  isDense: true,
                ),
              ),
            ),
            // Trailing clear button — scale + fade in/out
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: _hasText
                  ? GestureDetector(
                      key: const ValueKey('clear'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _clear,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: context.textSecondary.withValues(alpha: 0.18),
                          ),
                          child: Icon(
                            Icons.close_rounded,
                            size: 11,
                            color: context.textSecondary,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox(key: ValueKey('empty'), width: 14),
            ),
          ],
        ),
      ),
    );
  }
}
