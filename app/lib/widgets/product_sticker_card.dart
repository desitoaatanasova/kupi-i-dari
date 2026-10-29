import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/product.dart';

/// A product row with quantity controls.
///
/// The default constructor keeps the original demo usage ([product]); the
/// [ProductStickerCard.labelled] constructor drives the API-backed entry screen
/// from a product name plus an optional variant label, with an optional
/// disabled/loading presentation.
class ProductStickerCard extends StatelessWidget {
  ProductStickerCard({
    super.key,
    required Product product,
    required this.onIncrease,
    required this.onDecrease,
    required this.quantity,
    this.onIncreaseLongPress,
    this.onDecreaseLongPress,
  }) : name = product.name,
       unitLabel = product.unitLabel,
       enabled = true;

  const ProductStickerCard.labelled({
    super.key,
    required this.name,
    required this.unitLabel,
    required this.onIncrease,
    required this.onDecrease,
    required this.quantity,
    this.onIncreaseLongPress,
    this.onDecreaseLongPress,
    this.enabled = true,
  });

  final String name;
  final String unitLabel;
  final int quantity;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;
  final VoidCallback? onIncreaseLongPress;
  final VoidCallback? onDecreaseLongPress;

  /// When false the quantity controls are disabled (for example while a
  /// submission is in progress).
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
        border: Border.all(color: AppColors.border),
        boxShadow: AppTokens.cardShadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Мярка: $unitLabel',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          _QuantityControls(
            quantity: quantity,
            enabled: enabled,
            onIncrease: onIncrease,
            onDecrease: onDecrease,
            onIncreaseLongPress: onIncreaseLongPress,
            onDecreaseLongPress: onDecreaseLongPress,
          ),
        ],
      ),
    );
  }
}

class _QuantityControls extends StatelessWidget {
  const _QuantityControls({
    required this.quantity,
    required this.onIncrease,
    required this.onDecrease,
    this.onIncreaseLongPress,
    this.onDecreaseLongPress,
    this.enabled = true,
  });

  final int quantity;
  final bool enabled;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;
  final VoidCallback? onIncreaseLongPress;
  final VoidCallback? onDecreaseLongPress;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _RoundIconButton(
          icon: Icons.remove,
          color: AppColors.textSecondary,
          onTap: onDecrease,
          onLongPress: onDecreaseLongPress,
          tooltip: 'Намали',
          enabled: enabled,
        ),
        SizedBox(
          width: 48,
          child: Text(
            '$quantity',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        _RoundIconButton(
          icon: Icons.add,
          color: AppColors.primary,
          onTap: onIncrease,
          onLongPress: onIncreaseLongPress,
          tooltip: 'Увеличи',
          enabled: enabled,
        ),
      ],
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
    this.onLongPress,
    this.enabled = true,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            onPressed: enabled ? onTap : null,
            onLongPress: enabled ? onLongPress : null,
            icon: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppTokens.radiusPill),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            style: IconButton.styleFrom(
              backgroundColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusPill),
              ),
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}
