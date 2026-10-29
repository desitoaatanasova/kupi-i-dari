import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';

ApiClient clientWith(
  Future<http.Response> Function(http.Request request) handler, {
  String baseUrl = 'https://api.test/api',
  Duration? timeout,
  void Function()? onUnauthorized,
}) {
  return ApiClient(
    baseUrl: baseUrl,
    timeout: timeout,
    onUnauthorized: onUnauthorized,
    httpClient: MockClient(handler),
  );
}

void main() {
  group('ApiClient', () {
    test(
      'joins the base URL and path (trailing slashes) and adds headers',
      () async {
        late http.Request captured;
        final client = clientWith((request) async {
          captured = request;
          return http.Response('{"ok":true}', 200);
        }, baseUrl: 'https://api.test/api/');

        final result = await client.get('/auth/me', token: 'abc');

        expect(result, {'ok': true});
        expect(captured.method, 'GET');
        expect(captured.url.toString(), 'https://api.test/api/auth/me');
        expect(captured.headers['Authorization'], 'Bearer abc');
        expect(captured.headers['Accept'], 'application/json');
      },
    );

    test('posts a JSON body with the correct content type', () async {
      late http.Request captured;
      final client = clientWith((request) async {
        captured = request;
        return http.Response('{"token":"t"}', 200);
      });

      await client.post('/auth/login', body: {'phone': 'x', 'password': 'y'});

      expect(captured.method, 'POST');
      expect(captured.headers['Content-Type'], 'application/json');
      expect(jsonDecode(captured.body), {'phone': 'x', 'password': 'y'});
    });

    test('puts a JSON body with a bearer token', () async {
      late http.Request captured;
      final client = clientWith((request) async {
        captured = request;
        return http.Response('{"quantities":[]}', 200);
      });

      await client.put(
        '/shifts/5/quantities',
        token: 'abc',
        body: {
          'locationId': 3,
          'quantities': [
            {'variantId': 8, 'quantity': 12},
          ],
        },
      );

      expect(captured.method, 'PUT');
      expect(
        captured.url.toString(),
        'https://api.test/api/shifts/5/quantities',
      );
      expect(captured.headers['Authorization'], 'Bearer abc');
      expect(captured.headers['Content-Type'], 'application/json');
      expect(jsonDecode(captured.body), {
        'locationId': 3,
        'quantities': [
          {'variantId': 8, 'quantity': 12},
        ],
      });
    });

    test('maps a put backend error envelope to an ApiException', () async {
      final client = clientWith(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'ENTRY_WINDOW_CLOSED', 'message': 'closed'},
          }),
          409,
        ),
      );

      await expectLater(
        client.put('/shifts/5/quantities', token: 't', body: {'locationId': 1}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'ENTRY_WINDOW_CLOSED')
              .having((e) => e.statusCode, 'status', 409),
        ),
      );
    });

    test('patches without a body and without a content type', () async {
      late http.Request captured;
      final client = clientWith((request) async {
        captured = request;
        return http.Response('{"id":9}', 200);
      });

      final result = await client.patch(
        '/shifts/5/registrations/9/cancel',
        token: 'abc',
      );

      expect(result, {'id': 9});
      expect(captured.method, 'PATCH');
      expect(
        captured.url.toString(),
        'https://api.test/api/shifts/5/registrations/9/cancel',
      );
      expect(captured.headers['Authorization'], 'Bearer abc');
      // No body means no Content-Type and no payload.
      expect(captured.headers.containsKey('Content-Type'), isFalse);
      expect(captured.body, isEmpty);
    });

    test('patches a JSON body when one is given', () async {
      late http.Request captured;
      final client = clientWith((request) async {
        captured = request;
        return http.Response('{"ok":true}', 200);
      });

      await client.patch(
        '/shifts/5/registrations/9/cancel',
        token: 'abc',
        body: {'reason': 'test'},
      );

      expect(captured.method, 'PATCH');
      expect(captured.headers['Content-Type'], 'application/json');
      expect(jsonDecode(captured.body), {'reason': 'test'});
    });

    test('maps a patch backend error envelope to an ApiException', () async {
      final client = clientWith(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'SHIFT_NOT_OPEN', 'message': 'closed'},
          }),
          409,
        ),
      );

      await expectLater(
        client.patch('/shifts/5/registrations/9/cancel', token: 't'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'SHIFT_NOT_OPEN')
              .having((e) => e.statusCode, 'status', 409),
        ),
      );
    });

    test('omits the authorization header when no token is given', () async {
      late http.Request captured;
      final client = clientWith((request) async {
        captured = request;
        return http.Response('{}', 200);
      });

      await client.get('/products');

      expect(captured.headers.containsKey('Authorization'), isFalse);
    });

    test('returns null for an empty 204 response', () async {
      final client = clientWith((_) async => http.Response('', 204));

      final result = await client.post('/auth/logout', token: 't');

      expect(result, isNull);
    });

    test('maps a backend error envelope to an ApiException', () async {
      final client = clientWith(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'INVALID_CREDENTIALS', 'message': 'nope'},
          }),
          401,
        ),
      );

      await expectLater(
        client.post('/auth/login', body: {'phone': 'x', 'password': 'y'}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'INVALID_CREDENTIALS')
              .having((e) => e.statusCode, 'status', 401)
              .having((e) => e.message, 'message', 'nope')
              .having((e) => e.isUnauthorized, 'unauthorized', isFalse),
        ),
      );
    });

    test('calls onUnauthorized for a confirmed 401 UNAUTHORIZED', () async {
      var calls = 0;
      final client = clientWith(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'UNAUTHORIZED', 'message': 'expired'},
          }),
          401,
        ),
        onUnauthorized: () => calls += 1,
      );

      await expectLater(
        client.get('/shifts', token: 'expired'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'UNAUTHORIZED')
              .having((e) => e.statusCode, 'status', 401),
        ),
      );
      expect(calls, 1);
    });

    test('does not call onUnauthorized for INVALID_CREDENTIALS', () async {
      var calls = 0;
      final client = clientWith(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'INVALID_CREDENTIALS', 'message': 'bad'},
          }),
          401,
        ),
        onUnauthorized: () => calls += 1,
      );

      await expectLater(
        client.post('/auth/login', body: {'phone': 'x', 'password': 'y'}),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 0);
    });

    test('does not call onUnauthorized for non-401 responses', () async {
      var calls = 0;
      final client = clientWith(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'UNAUTHORIZED', 'message': 'forbidden'},
          }),
          403,
        ),
        onUnauthorized: () => calls += 1,
      );

      await expectLater(
        client.get('/admin/users', token: 'staff'),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 0);
    });

    test(
      'a throwing onUnauthorized callback does not hide the API error',
      () async {
        final client = clientWith(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': 'UNAUTHORIZED', 'message': 'expired'},
            }),
            401,
          ),
          onUnauthorized: () => throw StateError('listener failed'),
        );

        await expectLater(
          client.get('/auth/me', token: 'expired'),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHORIZED'),
          ),
        );
      },
    );

    test('handles a malformed error envelope safely', () async {
      final client = clientWith((_) async => http.Response('not json', 500));

      await expectLater(
        client.get('/anything'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'HTTP_ERROR')
              .having((e) => e.statusCode, 'status', 500),
        ),
      );
    });

    test('falls back safely when the error object is incomplete', () async {
      final client = clientWith(
        (_) async => http.Response(jsonEncode({'error': {}}), 400),
      );

      await expectLater(
        client.get('/anything'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'HTTP_ERROR')
              .having((e) => e.statusCode, 'status', 400),
        ),
      );
    });

    test('maps a transport failure to NETWORK_ERROR', () async {
      final client = clientWith(
        (_) async => throw http.ClientException('boom'),
      );

      await expectLater(
        client.get('/anything'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiException.networkErrorCode)
              .having((e) => e.isNetworkError, 'isNetworkError', isTrue),
        ),
      );
    });

    test('maps a timeout to NETWORK_ERROR', () async {
      final never = Completer<http.Response>();
      final client = clientWith(
        (_) => never.future,
        timeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        client.get('/slow'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiException.networkErrorCode,
          ),
        ),
      );
    });
  });
}
