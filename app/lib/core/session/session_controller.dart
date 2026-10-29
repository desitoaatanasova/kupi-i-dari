import 'package:flutter/foundation.dart';

import '../../models/app_user.dart';
import '../api/api_exception.dart';
import '../api/auth_api.dart';
import '../auth/auth_messages.dart';
import 'auth_session.dart';

/// Single source of truth for authentication state.
///
/// The session is held in memory only. Public login/identification failures
/// never clear an existing session; only an explicit sign-out or a confirmed
/// `401 UNAUTHORIZED` from an authenticated request does.
class SessionController extends ChangeNotifier {
  SessionController({required AuthApi authApi}) : _authApi = authApi;

  final AuthApi _authApi;

  AuthSession? _session;
  bool _busy = false;
  String? _notice;

  AuthSession? get session => _session;
  AppUser? get user => _session?.user;
  bool get isAuthenticated => _session != null;
  bool get isBusy => _busy;
  bool get mustChangePassword => user?.mustChangePassword ?? false;

  /// Unknown until an authenticated backend response has been received.
  UserRole get role => user?.role ?? UserRole.unknown;

  /// A safe, session-level message (for example an expired session notice).
  String? get notice => _notice;

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// Staff phone + password login.
  Future<AuthSession?> signInStaff({
    required String phone,
    required String password,
  }) {
    return _authenticate(
      () => _authApi.login(phone: phone, password: password),
    );
  }

  /// Public volunteer registration.
  Future<AuthSession?> registerVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
    required UserRole role,
  }) {
    return _authenticate(
      () => _authApi.registerVolunteer(
        firstName: firstName,
        lastName: lastName,
        phone: phone,
        role: role,
      ),
    );
  }

  /// Strict volunteer login for an existing account.
  Future<AuthSession?> signInVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) {
    return _authenticate(
      () => _authApi.loginVolunteer(
        firstName: firstName,
        lastName: lastName,
        phone: phone,
      ),
    );
  }

  /// Legacy volunteer identification (existing volunteer, name + phone).
  Future<AuthSession?> identifyVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) {
    return _authenticate(
      () => _authApi.identifyVolunteer(
        firstName: firstName,
        lastName: lastName,
        phone: phone,
      ),
    );
  }

  /// Refresh the current profile from `GET /api/auth/me`.
  Future<AppUser?> refreshUser() async {
    final current = _session;
    if (current == null) return null;
    try {
      final user = await _authApi.me(token: current.token);
      if (_session?.token != current.token) return _session?.user;
      _session = current.withUser(user);
      notifyListeners();
      return user;
    } on ApiException catch (error) {
      if (error.isUnauthorized) handleUnauthorized();
      rethrow;
    }
  }

  /// Change the current staff password and adopt the fresh session.
  Future<AuthSession?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final current = _session;
    if (current == null) return null;

    _setBusy(true);
    try {
      final updated = await _authApi.changePassword(
        token: current.token,
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      _session = updated;
      _notice = null;
      return updated;
    } on ApiException catch (error) {
      if (error.isUnauthorized) handleUnauthorized();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  /// Sign out locally first, then best-effort revoke the token server-side.
  ///
  /// The local session is always cleared, even if the network request fails.
  Future<void> signOut() async {
    final current = _session;
    _session = null;
    _busy = false;
    _notice = null;
    notifyListeners();

    if (current == null) return;
    try {
      await _authApi.logout(token: current.token);
    } catch (_) {
      // Local state is already cleared; a failed revoke must not re-authenticate.
    }
  }

  /// Clear the session after a confirmed `401 UNAUTHORIZED`.
  void handleUnauthorized() {
    if (_session == null) return;
    _session = null;
    _busy = false;
    _notice = AuthMessages.forCode('UNAUTHORIZED');
    notifyListeners();
  }

  Future<AuthSession?> _authenticate(
    Future<AuthSession> Function() request,
  ) async {
    _setBusy(true);
    try {
      final session = await request();
      _session = session;
      _notice = null;
      notifyListeners();
      return session;
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    if (_busy == value) return;
    _busy = value;
    notifyListeners();
  }
}
