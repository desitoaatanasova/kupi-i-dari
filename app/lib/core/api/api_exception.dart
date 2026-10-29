/// A safe, user-presentable error raised by the API layer.
///
/// [code] is a stable machine code (either the backend error code such as
/// `INVALID_CREDENTIALS`, or a client-side code such as `NETWORK_ERROR`).
/// [message] is a short, non-technical description safe to surface in the UI.
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  /// Client-side code used for connection failures and timeouts.
  static const String networkErrorCode = 'NETWORK_ERROR';

  final String code;
  final String message;
  final int? statusCode;

  bool get isNetworkError => code == networkErrorCode;

  /// True only for a confirmed expired/revoked session (`UNAUTHORIZED`).
  /// `INVALID_CREDENTIALS` is also an HTTP 401 but is not a session expiry.
  bool get isUnauthorized => code == 'UNAUTHORIZED';

  bool get isMustChangePassword => code == 'MUST_CHANGE_PASSWORD';

  @override
  String toString() =>
      'ApiException($code${statusCode == null ? '' : ', $statusCode'})';
}
