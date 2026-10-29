import 'package:flutter/foundation.dart';

import '../../models/app_user.dart';

/// The authenticated in-memory session.
///
/// The token is never written to disk in this phase: closing the app returns
/// the user to the start screen and requires a fresh sign-in.
@immutable
class AuthSession {
  const AuthSession({
    required this.token,
    required this.user,
    required this.expiresIn,
  });

  final String token;
  final AppUser user;
  final int? expiresIn;

  bool get mustChangePassword => user.mustChangePassword;

  AuthSession withUser(AppUser user) =>
      AuthSession(token: token, user: user, expiresIn: expiresIn);

  /// Parse a backend token response (`{ token, tokenType, expiresIn, user }`).
  /// Returns null when the payload does not look like a valid response.
  static AuthSession? tryParse(Object? payload) {
    if (payload is! Map) return null;
    final token = payload['token'];
    if (token is! String || token.isEmpty) return null;
    final user = AppUser.tryParse(payload['user']);
    if (user == null) return null;
    final expiresIn = payload['expiresIn'];
    return AuthSession(
      token: token,
      user: user,
      expiresIn: expiresIn is num ? expiresIn.toInt() : null,
    );
  }
}
