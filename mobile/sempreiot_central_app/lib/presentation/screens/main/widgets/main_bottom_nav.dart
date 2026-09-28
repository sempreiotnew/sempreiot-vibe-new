import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../main_tab.dart';

class MainBottomNav extends StatelessWidget {
  const MainBottomNav({
    super.key,
    required this.currentTab,
    required this.onTabChanged,
  });

  final MainTab currentTab;
  final ValueChanged<MainTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.barColor,
        border: Border(
          top: BorderSide(
            color: context.borderColor.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: MainTab.tabs.map((tab) {
              return Expanded(
                child: _NavItem(
                  tab: tab,
                  active: tab == currentTab,
                  onTap: () => onTabChanged(tab),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final MainTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.secondary : context.textSecondary;

    return InkWell(
      onTap: onTap,
      highlightColor: AppColors.secondary.withValues(alpha: 0.06),
      splashColor: AppColors.secondary.withValues(alpha: 0.08),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: 40,
            height: 30,
            decoration: BoxDecoration(
              color: active
                  ? AppColors.secondary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(tab.icon, size: 20, color: color),
          ),
          const SizedBox(height: 2),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              letterSpacing: 0.2,
            ),
            child: Text(tab.label),
          ),
        ],
      ),
    );
  }
}
