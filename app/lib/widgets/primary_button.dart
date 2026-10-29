import 'package:flutter/material.dart';

import '../core/theme/app_tokens.dart';

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expanded = true,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expanded;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy) ...[
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: AppTokens.spaceSm),
        ] else if (icon != null) ...[
          Icon(icon, size: 20),
          const SizedBox(width: AppTokens.spaceSm),
        ],
        Text(label),
      ],
    );

    return ElevatedButton(
      onPressed: busy ? null : onPressed,
      child:
          expanded
              ? SizedBox(width: double.infinity, child: Center(child: child))
              : child,
    );
  }
}
