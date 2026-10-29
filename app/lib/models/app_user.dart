import 'package:flutter/foundation.dart';

/// Backend role values, with Bulgarian labels for display.
///
/// [UserRole.unknown] is used for any role value the backend did not
/// document. An unknown role must never be treated as elevated.
enum UserRole {
  volunteer('VOLUNTEER', 'Доброволец'),
  responsible('RESPONSIBLE', 'Отговорник'),
  admin('ADMIN', 'Администратор'),
  unknown('UNKNOWN', 'Потребител');

  const UserRole(this.key, this.label);

  final String key;
  final String label;

  static UserRole fromKey(String? key) {
    for (final role in values) {
      if (role.key == key) return role;
    }
    return UserRole.unknown;
  }

  /// Whether this role may act on staff-only capabilities.
  /// Always false for [UserRole.unknown].
  bool get isStaff => this == responsible || this == admin;

  bool get isAdmin => this == admin;
}

/// The safe user profile returned by the backend (`users.toSafeProfile`).
@immutable
class AppUser {
  const AppUser({
    required this.id,
    required this.phone,
    required this.firstName,
    required this.lastName,
    required this.role,
    required this.isActive,
    required this.mustChangePassword,
  });

  final int id;
  final String phone;
  final String firstName;
  final String lastName;
  final UserRole role;
  final bool isActive;
  final bool mustChangePassword;

  String get fullName => '$firstName $lastName';

  /// Parse a profile defensively: accepts the flat safe profile, or a
  /// `{ "user": {...} }` envelope, and tolerates boolean/int flag variants.
  static AppUser? tryParse(Object? payload) {
    if (payload is! Map) return null;
    final map = payload['user'];
    final data = map is Map ? map : payload;
    return AppUser.fromJson(Map<String, dynamic>.from(data));
  }

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: _toInt(json['id']) ?? 0,
      phone: _toString(json['phone']),
      firstName: _toString(json['firstName']),
      lastName: _toString(json['lastName']),
      role: UserRole.fromKey(_toStringOrNull(json['role'])),
      isActive: _toBool(json['isActive']),
      mustChangePassword: _toBool(json['mustChangePassword']),
    );
  }

  AppUser copyWith({bool? mustChangePassword, bool? isActive}) {
    return AppUser(
      id: id,
      phone: phone,
      firstName: firstName,
      lastName: lastName,
      role: role,
      isActive: isActive ?? this.isActive,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppUser &&
      other.id == id &&
      other.role == role &&
      other.phone == phone;

  @override
  int get hashCode => Object.hash(id, phone, role);

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static bool _toBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value == 'true' || value == '1';
    return false;
  }

  static String _toString(Object? value) => _toStringOrNull(value) ?? '';

  static String? _toStringOrNull(Object? value) =>
      value is String ? value : null;
}
