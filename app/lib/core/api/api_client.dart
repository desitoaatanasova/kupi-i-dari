import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'api_exception.dart';

/// Low-level JSON HTTP client for the backend API.
///
/// A single [http.Client] is injected so tests can supply `MockClient` and so
/// the connection pool is shared. This class owns all URL joining, header
/// construction, JSON decoding and error-envelope parsing so endpoints never
/// duplicate that logic.
class ApiClient {
  ApiClient({
    http.Client? httpClient,
    String? baseUrl,
    Duration? timeout,
    void Function()? onUnauthorized,
  }) : _http = httpClient ?? http.Client(),
       _baseUrl = _normalizeBase(baseUrl ?? ApiConfig.baseUrl),
       _timeout = timeout ?? const Duration(seconds: 15),
       _onUnauthorized = onUnauthorized;

  final http.Client _http;
  final String _baseUrl;

  /// Per-request timeout; defaults to 15 seconds.
  final Duration _timeout;

  /// Called once for a confirmed `401 UNAUTHORIZED` response, before the
  /// original [ApiException] is rethrown.
  final void Function()? _onUnauthorized;

  String get baseUrl => _baseUrl;

  static String _normalizeBase(String value) {
    var base = value.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  Uri _uri(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_baseUrl$normalized');
  }

  Map<String, String> _headers({String? token, bool jsonBody = false}) {
    final headers = <String, String>{'Accept': 'application/json'};
    if (jsonBody) headers['Content-Type'] = 'application/json';
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<dynamic> get(String path, {String? token}) {
    return _send(() => _http.get(_uri(path), headers: _headers(token: token)));
  }

  Future<dynamic> post(String path, {Object? body, String? token}) {
    return _send(
      () => _http.post(
        _uri(path),
        headers: _headers(token: token, jsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  Future<dynamic> put(String path, {Object? body, String? token}) {
    return _send(
      () => _http.put(
        _uri(path),
        headers: _headers(token: token, jsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  /// Sends a PATCH request.
  ///
  /// The body is optional: when it is omitted no JSON body is sent and no
  /// `Content-Type` header is added, which is what the backend expects for
  /// bodyless PATCH endpoints such as the registration cancellation.
  Future<dynamic> patch(String path, {Object? body, String? token}) {
    return _send(
      () => _http.patch(
        _uri(path),
        headers: _headers(token: token, jsonBody: body != null),
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on TimeoutException {
      throw const ApiException(
        code: ApiException.networkErrorCode,
        message: 'Could not reach the server.',
      );
    } on http.ClientException {
      throw const ApiException(
        code: ApiException.networkErrorCode,
        message: 'Could not reach the server.',
      );
    }

    final decoded = _tryDecode(response.body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    final exception = _toException(response.statusCode, decoded);
    if (exception.statusCode == 401 && exception.isUnauthorized) {
      _notifyUnauthorized();
    }
    throw exception;
  }

  void _notifyUnauthorized() {
    final callback = _onUnauthorized;
    if (callback == null) return;
    try {
      callback();
    } catch (_) {
      // The API error remains the source of truth for the caller.
    }
  }

  /// Decode the JSON body, tolerating empty bodies and malformed content.
  static dynamic _tryDecode(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
  }

  static ApiException _toException(int statusCode, dynamic decoded) {
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        final code = error['code'];
        final message = error['message'];
        return ApiException(
          statusCode: statusCode,
          code: code is String && code.isNotEmpty ? code : 'HTTP_ERROR',
          message:
              message is String && message.isNotEmpty
                  ? message
                  : 'The request could not be completed.',
        );
      }
    }
    return ApiException(
      statusCode: statusCode,
      code: 'HTTP_ERROR',
      message: 'The request could not be completed.',
    );
  }
}
