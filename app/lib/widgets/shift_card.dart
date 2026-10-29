import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/shift.dart';
import 'status_chip.dart';
import 'volunteer_count_badge.dart';

class ShiftCard extends StatelessWidget {
  const ShiftCard({
    super.key,
    required this.shift,
    this.onTap,
    this.buttonLabel = 'Виж смяната',
    this.onButtonPressed,
    this.isRegistered = false,
  });

  final Shift shift;
  final VoidCallback? onTap;
  final String buttonLabel;
  final VoidCallback? onButtonPressed;

  /// Whether the signed-in volunteer has a confirmed `REGISTERED`
  /// registration for this shift. Only a confirmed backend state may set it.
  final bool isRegistered;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
            border: Border.all(color: AppColors.border),
            boxShadow: AppTokens.cardShadow,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppTokens.radiusLarge),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          shift.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppTokens.spaceSm),
                      StatusChip(status: shift.status),
                      if (isRegistered) ...[
                        const SizedBox(width: AppTokens.spaceSm),
                        const _RegisteredChip(),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceMd),
                  Row(
                    children: [
                      const Icon(
                        Icons.calendar_today_outlined,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${shift.weekdayLabel}, ${shift.dateLabel}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.schedule_outlined,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        shift.timeRange,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceMd),
                  Row(
                    children: [
                      // The backend never exposes a count or a capacity, so the
                      // badge hides itself instead of showing an invented
                      // number.
                      VolunteerCountBadge(
                        registered: shift.registeredCount,
                        capacity: shift.capacity,
                      ),
                      const Spacer(),
                      if (onButtonPressed != null)
                        ElevatedButton(
                          onPressed: onButtonPressed,
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, AppTokens.touchTarget),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          child: Text(buttonLabel),
                        ),
                    ],
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

/// Marks a shift the signed-in volunteer has a confirmed registration for.
class _RegisteredChip extends StatelessWidget {
  const _RegisteredChip();

  @override
  Widget build(BuildContext context) {
    const textColor = Color(0xFF2E7D32);
    const backgroundColor = Color(0xFFE7F5EC);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 14, color: textColor),
          const SizedBox(width: 4),
          Text(
            'Записани сте',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}
