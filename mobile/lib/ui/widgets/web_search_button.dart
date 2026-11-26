import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 联网搜索开关胶囊：与「深度思考」并排。
class WebSearchButton extends StatelessWidget {
  const WebSearchButton({
    super.key,
    required this.enabled,
    required this.onToggle,
  });

  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => onToggle(!enabled),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: enabled ? c.accentOutline : c.borderSoft,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.travel_explore_rounded,
                size: 14,
                color: enabled ? c.accent : c.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '智能搜索',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: enabled ? FontWeight.w500 : FontWeight.w400,
                  color: enabled ? c.accent : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
