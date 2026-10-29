import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/category.dart';

class CategoryCard extends StatelessWidget {
  CategoryCard({
    super.key,
    required Category category,
    required this.productCount,
    this.selected = false,
    this.onTap,
  }) : name = category.name,
       icon = category.icon;

  /// Constructor for API-driven grouping, where categories are free-form
  /// strings without a dedicated icon.
  const CategoryCard.labelled({
    super.key,
    required this.name,
    this.icon = Icons.category_outlined,
    required this.productCount,
    this.selected = false,
    this.onTap,
  });

  final String name;
  final IconData icon;
  final int productCount;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? AppColors.primary : AppColors.textSecondary;
    return Material(
      type: MaterialType.transparency,
      child: Ink(
        decoration: BoxDecoration(
          color:
              selected
                  ? AppColors.primary.withValues(alpha: 0.08)
                  : AppColors.background,
          borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: Row(
              children: [
                Icon(icon, size: 26, color: accent),
                const SizedBox(width: AppTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color:
                              selected
                                  ? AppColors.primary
                                  : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$productCount продукта',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.check_circle : Icons.chevron_right,
                  size: selected ? 22 : 20,
                  color: selected ? AppColors.primary : AppColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
