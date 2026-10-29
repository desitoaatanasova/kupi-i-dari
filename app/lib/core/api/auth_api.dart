import '../../models/app_user.dart';
import '../session/auth_session.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// Typed access to the backend authentication endpoints.
///
/// Endpoint paths are relative to [ApiClient.baseUrl] (which already ends in
/// `/api`). No endpoint, field or credential is invented here.
class AuthApi {
  AuthApi(this._client);

  final ApiClient _client;

  /// `POST /api/auth/login` — staff phone + password.
  Future<AuthSession> login({
    required String phone,
    required String password,
  }) async {
    final payload = await _client.post(
      '/auth/login',
      body: {'phone': phone, 'password': password},
    );
    return _requireSession(payload);
  }

  /// `POST /api/auth/register` — public volunteer registration.
  Future<AuthSession> registerVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
    required UserRole role,
  }) async {
    final payload = await _client.post(
      '/auth/register',
      body: {
        'firstName': firstName,
        'lastName': lastName,
        'phone': phone,
        'role': role.key,
      },
    );
    return _requireSession(payload);
  }

  /// `POST /api/auth/volunteer/login` — existing volunteer, name + phone.
  Future<AuthSession> loginVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    final payload = await _client.post(
      '/auth/volunteer/login',
      body: {'firstName': firstName, 'lastName': lastName, 'phone': phone},
    );
    return _requireSession(payload);
  }

  /// Legacy `POST /api/auth/volunteer` volunteer identification.
  Future<AuthSession> identifyVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    final payload = await _client.post(
      '/auth/volunteer',
      body: {'firstName': firstName, 'lastName': lastName, 'phone': phone},
    );
    return _requireSession(payload);
  }

  /// `GET /api/auth/me` — current safe profile.
  ///
  /// The backend returns the flat safe profile; a `{ "user": ... }` envelope
  /// is also accepted defensively.
  Future<AppUser> me({required String token}) async {
    final payload = await _client.get('/auth/me', token: token);
    final user = AppUser.tryParse(payload);
    if (user == null) throw malformedResponse();
    return user;
  }

  /// `POST /api/auth/password/change` — returns a fresh token and profile.
  Future<AuthSession> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    final payload = await _client.post(
      '/auth/password/change',
      token: token,
      body: {'currentPassword': currentPassword, 'newPassword': newPassword},
    );
    return _requireSession(payload);
  }

  /// `POST /api/auth/logout` — 204 with an empty body.
  Future<void> logout({required String token}) async {
    await _client.post('/auth/logout', token: token);
  }

  AuthSession _requireSession(Object? payload) {
    final session = AuthSession.tryParse(payload);
    if (session == null) throw malformedResponse();
    return session;
  }

  static ApiException malformedResponse() => const ApiException(
    code: 'UNEXPECTED_RESPONSE',
    message: 'The server returned an unexpected response.',
  );
}
