import 'package:flutter/foundation.dart';

import 'app_user.dart';

/// One page of users returned by `GET /api/admin/users`.
@immutable
class AdminUserPage {
  const AdminUserPage({
    required this.users,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.totalPages,
  });

  final List<AppUser> users;
  final int page;
  final int pageSize;
  final int total;
  final int totalPages;

  AdminUserPage copyWith({
    List<AppUser>? users,
    int? page,
    int? pageSize,
    int? total,
    int? totalPages,
  }) {
    return AdminUserPage(
      users: users ?? this.users,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      total: total ?? this.total,
      totalPages: totalPages ?? this.totalPages,
    );
  }

  AdminUserPage replaceUser(AppUser user) {
    return copyWith(
      users: List<AppUser>.unmodifiable(
        users.map((item) => item.id == user.id ? user : item),
      ),
    );
  }

  AdminUserPage removeUser(int userId) {
    final remaining = users.where((item) => item.id != userId).toList();
    final newTotal = total > 0 ? total - 1 : 0;
    final newTotalPages =
        newTotal == 0 ? 0 : (newTotal + pageSize - 1) ~/ pageSize;
    return copyWith(
      users: List<AppUser>.unmodifiable(remaining),
      total: newTotal,
      totalPages: newTotalPages,
    );
  }
}
