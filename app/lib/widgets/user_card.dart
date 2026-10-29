import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/app_user.dart';

class UserCard extends StatelessWidget {
  const UserCard({
    super.key,
    required this.user,
    this.isCurrentUser = false,
    this.onEdit,
    this.onActivate,
    this.onDeactivate,
  });

  final AppUser user;
  final bool isCurrentUser;
  final VoidCallback? onEdit;
  final VoidCallback? onActivate;
  final VoidCallback? onDeactivate;

  Color _statusColor(bool isActive) {
    return isActive ? AppColors.success : AppColors.textTertiary;
  }

  String _statusLabel(bool isActive) {
    return isActive ? 'Активен' : 'Деактивиран';
  }

  @override
  Widget build(BuildContext context) {
    final hasActions =
        onEdit != null || onActivate != null || onDeactivate != null;

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
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
                  ),
                  child: const Icon(
                    Icons.person_outline,
                    color: AppColors.primary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.fullName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user.phone,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: AppTokens.spaceSm,
                        runSpacing: AppTokens.spaceXs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Semantics(
                            label: 'Роля: ${user.role.label}',
                            child: ExcludeSemantics(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppTokens.spaceSm,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.backgroundSecondary,
                                  borderRadius: BorderRadius.circular(
                                    AppTokens.radiusPill,
                                  ),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Text(
                                  user.role.label,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Semantics(
                            label: 'Статус: ${_statusLabel(user.isActive)}',
                            child: ExcludeSemantics(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: _statusColor(user.isActive),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _statusLabel(user.isActive),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _statusColor(user.isActive),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (isCurrentUser)
                            Semantics(
                              label: 'Това сте вие',
                              child: ExcludeSemantics(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppTokens.spaceSm,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withValues(
                                      alpha: 0.08,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      AppTokens.radiusPill,
                                    ),
                                  ),
                                  child: const Text(
                                    'Това сте вие',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (user.mustChangePassword)
                            Semantics(
                              label: 'Трябва смяна на парола',
                              child: ExcludeSemantics(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppTokens.spaceSm,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.backgroundSecondary,
                                    borderRadius: BorderRadius.circular(
                                      AppTokens.radiusPill,
                                    ),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: const Text(
                                    'Трябва смяна на парола',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (hasActions)
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: PopupMenuButton<String>(
                      key: Key('admin-user-menu-${user.id}'),
                      tooltip: 'Действия за потребителя',
                      icon: const Icon(Icons.more_vert),
                      onSelected: (value) {
                        if (value == 'edit') {
                          onEdit?.call();
                        } else if (value == 'activate') {
                          onActivate?.call();
                        } else if (value == 'deactivate') {
                          onDeactivate?.call();
                        }
                      },
                      itemBuilder: (context) {
                        final items = <PopupMenuEntry<String>>[];
                        if (onEdit != null) {
                          items.add(
                            PopupMenuItem<String>(
                              key: Key('admin-user-edit-${user.id}'),
                              value: 'edit',
                              child: const Text('Редактирай'),
                            ),
                          );
                        }
                        if (user.isActive && onDeactivate != null) {
                          items.add(
                            PopupMenuItem<String>(
                              key: Key('admin-user-deactivate-${user.id}'),
                              value: 'deactivate',
                              child: const Text('Деактивирай'),
                            ),
                          );
                        } else if (!user.isActive && onActivate != null) {
                          items.add(
                            PopupMenuItem<String>(
                              key: Key('admin-user-activate-${user.id}'),
                              value: 'activate',
                              child: const Text('Активирай'),
                            ),
                          );
                        }
                        return items;
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
