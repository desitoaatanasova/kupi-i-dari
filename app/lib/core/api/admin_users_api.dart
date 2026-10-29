import '../../models/admin_user_page.dart';
import '../../models/app_user.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// Typed access to the backend admin user-management endpoints.
///
/// Endpoint paths are relative to [ApiClient.baseUrl] (which already ends in
/// `/api`). The contract follows backend Phase 3: every route requires an
/// active `ADMIN` bearer token and returns only the safe user profile.
class AdminUsersApi {
  AdminUsersApi(this._client);

  final ApiClient _client;

  /// `GET /api/admin/users` - paginated, optionally filtered user list.
  Future<AdminUserPage> listUserPage({
    required String token,
    UserRole? role,
    bool? isActive,
    int page = 1,
    int pageSize = 20,
  }) async {
    if (page < 1 || pageSize < 1 || pageSize > 100) {
      throw malformedResponse();
    }
    if (role == UserRole.unknown) throw malformedResponse();

    final query = <String, String>{'page': '$page', 'pageSize': '$pageSize'};
    if (role != null) query['role'] = role.key;
    if (isActive != null) query['isActive'] = isActive ? 'true' : 'false';

    final payload = await _client.get(
      '/admin/users?${_encodeQuery(query)}',
      token: token,
    );
    return _parsePage(payload, page, pageSize);
  }

  /// `POST /api/admin/users` - provision a `RESPONSIBLE` or `ADMIN` account.
  Future<AppUser> createStaff({
    required String token,
    required String firstName,
    required String lastName,
    required String phone,
    required UserRole role,
    required String password,
  }) async {
    if (role != UserRole.responsible && role != UserRole.admin) {
      throw malformedResponse();
    }
    final payload = await _client.post(
      '/admin/users',
      body: <String, Object?>{
        'firstName': firstName,
        'lastName': lastName,
        'phone': phone,
        'role': role.key,
        'password': password,
      },
      token: token,
    );
    return _parseUser(payload);
  }

  /// `PATCH /api/admin/users/:userId` - update only the editable profile
  /// fields. Role, password and security fields are deliberately absent.
  Future<AppUser> updateUserProfile(
    int userId, {
    required String token,
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    if (userId <= 0) throw malformedResponse();
    final payload = await _client.patch(
      '/admin/users/$userId',
      body: <String, Object?>{
        'firstName': firstName,
        'lastName': lastName,
        'phone': phone,
      },
      token: token,
    );
    return _parseUser(payload);
  }

  /// `PATCH /api/admin/users/:userId/status` - activate or deactivate a user.
  Future<AppUser> setUserStatus(
    int userId, {
    required String token,
    required bool isActive,
  }) async {
    if (userId <= 0) throw malformedResponse();
    final payload = await _client.patch(
      '/admin/users/$userId/status',
      body: <String, Object?>{'isActive': isActive},
      token: token,
    );
    return _parseUser(payload);
  }

  static AdminUserPage _parsePage(
    Object? payload,
    int requestedPage,
    int requestedPageSize,
  ) {
    if (payload is! Map) throw malformedResponse();
    final users = payload['users'];
    final pagination = payload['pagination'];
    if (users is! List || pagination is! Map) throw malformedResponse();

    final page = pagination['page'];
    final pageSize = pagination['pageSize'];
    final total = pagination['total'];
    final totalPages = pagination['totalPages'];

    if (page is! int || page < 1) throw malformedResponse();
    if (pageSize is! int || pageSize < 1 || pageSize > 100) {
      throw malformedResponse();
    }
    if (total is! int || total < 0) throw malformedResponse();
    if (totalPages is! int || totalPages < 0) throw malformedResponse();
    final expectedTotalPages =
        total == 0 ? 0 : (total + pageSize - 1) ~/ pageSize;
    if (totalPages != expectedTotalPages) throw malformedResponse();
    if (page != requestedPage || pageSize != requestedPageSize) {
      throw malformedResponse();
    }

    final records = <AppUser>[];
    for (final record in users) {
      records.add(_parseUser(record));
    }

    return AdminUserPage(
      users: List<AppUser>.unmodifiable(records),
      page: page,
      pageSize: pageSize,
      total: total,
      totalPages: totalPages,
    );
  }

  static AppUser _parseUser(Object? payload) {
    if (payload is! Map) throw malformedResponse();

    final id = payload['id'];
    final phone = payload['phone'];
    final firstName = payload['firstName'];
    final lastName = payload['lastName'];
    final roleKey = payload['role'];
    final isActive = payload['isActive'];
    final mustChangePassword = payload['mustChangePassword'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (phone is! String || phone.isEmpty) throw malformedResponse();
    if (firstName is! String || firstName.isEmpty) throw malformedResponse();
    if (lastName is! String || lastName.isEmpty) throw malformedResponse();
    if (roleKey is! String) throw malformedResponse();
    final role = UserRole.fromKey(roleKey);
    if (role == UserRole.unknown) throw malformedResponse();
    if (isActive is! bool) throw malformedResponse();
    if (mustChangePassword is! bool) throw malformedResponse();

    return AppUser(
      id: id,
      phone: phone,
      firstName: firstName,
      lastName: lastName,
      role: role,
      isActive: isActive,
      mustChangePassword: mustChangePassword,
    );
  }

  static String _encodeQuery(Map<String, String> query) {
    final parts = <String>[];
    query.forEach((key, value) {
      parts.add(
        '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}',
      );
    });
    return parts.join('&');
  }

  static ApiException malformedResponse() => const ApiException(
    code: 'UNEXPECTED_RESPONSE',
    message: 'The server returned an unexpected response.',
  );
}
