import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';

/// A badge with the number of registered volunteers and the shift capacity.
///
/// Both counts are optional: the backend safe shift shape never exposes them,
/// so an API-backed shift has **unknown** counts and renders no badge at all.
/// An invented number is never shown.
class VolunteerCountBadge extends StatelessWidget {
  const VolunteerCountBadge({
    super.key,
    required this.registered,
    required this.capacity,
  });

  /// Number of registered volunteers, or `null` when unknown.
  final int? registered;

  /// Capacity of the shift, or `null` when unknown.
  final int? capacity;

  /// Whether both counts are known and usable.
  ///
  /// Unknown (`null`), negative or non-positive capacity values are treated as
  /// "no information" and hide the badge.
  bool get _hasKnownCounts {
    final registeredValue = registered;
    final capacityValue = capacity;
    if (registeredValue == null || capacityValue == null) return false;
    if (registeredValue < 0 || capacityValue <= 0) return false;
    return true;
  }

  bool get _isFull => (registered ?? 0) >= (capacity ?? 0);

  @override
  Widget build(BuildContext context) {
    if (!_hasKnownCounts) return const SizedBox.shrink();

    final color = _isFull ? AppColors.secondary : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people_alt_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$registered / $capacity',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
