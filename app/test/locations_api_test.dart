import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/locations_api.dart';

const locations = [
  {
    'id': 2,
    'name': 'Пункт „Надежда“',
    'address': 'бул. България 12, София',
    'isActive': true,
  },
  {
    'id': 1,
    'name': 'Пункт „Тракия“',
    'address': 'ул. Христо Ботев 8, Пловдив',
    'isActive': true,
  },
];

http.Response jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

LocationsApi apiWith(
  Future<http.Response> Function(http.Request request) handler,
  void Function(http.Request request)? onRequest,
) {
  return LocationsApi(
    ApiClient(
      baseUrl: 'https://api.test/api',
      httpClient: MockClient((request) {
        onRequest?.call(request);
        return handler(request);
      }),
    ),
  );
}

Matcher throwsUnexpectedResponse() => throwsA(
  isA<ApiException>().having((e) => e.code, 'code', 'UNEXPECTED_RESPONSE'),
);

void main() {
  group('LocationsApi.list', () {
    test('parses a valid envelope including Bulgarian text', () async {
      late http.Request captured;
      final api = apiWith(
        (_) async => jsonResponse({'locations': locations}, 200),
        (request) => captured = request,
      );

      final result = await api.list();

      expect(captured.method, 'GET');
      expect(captured.url.toString(), 'https://api.test/api/locations');
      expect(result, hasLength(2));
      expect(result[0].id, 2);
      expect(result[0].name, 'Пункт „Надежда“');
      expect(result[0].address, 'бул. България 12, София');
      expect(result[0].isActive, isTrue);
      expect(result[1].id, 1);
    });

    test('returns an empty list for an empty locations array', () async {
      final api = apiWith(
        (_) async => jsonResponse({'locations': []}, 200),
        null,
      );

      expect(await api.list(), isEmpty);
    });

    test(
      'throws UNEXPECTED_RESPONSE when locations is missing or not a list',
      () async {
        for (final payload in [
          <String, Object?>{},
          {'locations': null},
          {'locations': 'nope'},
          {'locations': <String, Object?>{}},
          <Object?>[],
          null,
        ]) {
          final api = apiWith((_) async => jsonResponse(payload, 200), null);
          await expectLater(api.list(), throwsUnexpectedResponse());
        }
      },
    );

    test('throws UNEXPECTED_RESPONSE for malformed record fields', () async {
      final malformed = [
        {'id': '2', 'name': 'A', 'address': 'B', 'isActive': true},
        {'id': 0, 'name': 'A', 'address': 'B', 'isActive': true},
        {'id': 1, 'name': '', 'address': 'B', 'isActive': true},
        {'id': 1, 'name': 'A', 'address': null, 'isActive': true},
        {'id': 1, 'name': 'A', 'address': 'B', 'isActive': 'true'},
        {'id': 1, 'name': 'A', 'address': 'B', 'isActive': null},
        {'id': 1, 'name': 'A', 'address': 'B'},
        'not a record',
      ];

      for (final record in malformed) {
        final api = apiWith(
          (_) async => jsonResponse({
            'locations': [record],
          }, 200),
          null,
        );
        await expectLater(
          api.list(),
          throwsUnexpectedResponse(),
          reason: 'record: $record',
        );
      }
    });

    test('defensively excludes archived records', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'locations': [
            ...locations,
            {
              'id': 9,
              'name': 'Архив',
              'address': 'ул. Стара 1',
              'isActive': false,
            },
          ],
        }, 200),
        null,
      );

      final result = await api.list();

      expect(result.map((location) => location.id), [2, 1]);
      expect(result.every((location) => location.isActive), isTrue);
    });

    test('sends the bearer token when provided', () async {
      late http.Request captured;
      final api = apiWith(
        (_) async => jsonResponse({'locations': []}, 200),
        (request) => captured = request,
      );

      await api.list(token: 'jwt-1');

      expect(captured.headers['Authorization'], 'Bearer jwt-1');
      expect(captured.headers['Accept'], 'application/json');
    });

    test('omits the authorization header when no token is provided', () async {
      late http.Request captured;
      final api = apiWith(
        (_) async => jsonResponse({'locations': []}, 200),
        (request) => captured = request,
      );

      await api.list();

      expect(captured.headers.containsKey('Authorization'), isFalse);
    });

    test('maps a structured error response to an ApiException', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'error': {'code': 'RATE_LIMITED', 'message': 'Too many requests.'},
        }, 429),
        null,
      );

      await expectLater(
        api.list(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'RATE_LIMITED')
              .having((e) => e.statusCode, 'status', 429),
        ),
      );
    });

    test('handles a malformed error response safely', () async {
      final api = apiWith((_) async => http.Response('not json', 500), null);

      await expectLater(
        api.list(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'HTTP_ERROR')
              .having((e) => e.statusCode, 'status', 500),
        ),
      );
    });

    test(
      '401 UNAUTHORIZED is exposed as an unauthorized ApiException',
      () async {
        final api = apiWith(
          (_) async => jsonResponse({
            'error': {'code': 'UNAUTHORIZED', 'message': 'Missing token.'},
          }, 401),
          null,
        );

        await expectLater(
          api.list(token: 'expired'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'UNAUTHORIZED')
                .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
          ),
        );
      },
    );
  });

  group('LocationsApi.createLocation', () {
    test(
      'sends the admin create request and parses the safe location',
      () async {
        late http.Request captured;
        final api = apiWith(
          (_) async => jsonResponse({
            'id': 7,
            'name': 'Нов пункт',
            'address': 'ул. Нова 1, София',
            'isActive': true,
          }, 201),
          (request) => captured = request,
        );

        final result = await api.createLocation(
          name: 'Нов пункт',
          address: 'ул. Нова 1, София',
          token: 'admin-token',
        );

        expect(captured.method, 'POST');
        expect(captured.url.toString(), 'https://api.test/api/locations');
        expect(captured.headers['Authorization'], 'Bearer admin-token');
        expect(captured.headers['Content-Type'], contains('application/json'));
        expect(jsonDecode(captured.body), {
          'name': 'Нов пункт',
          'address': 'ул. Нова 1, София',
        });
        expect(result.id, 7);
        expect(result.name, 'Нов пункт');
        expect(result.address, 'ул. Нова 1, София');
        expect(result.isActive, isTrue);
      },
    );

    test('throws UNEXPECTED_RESPONSE for a malformed created record', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'id': 7,
          'name': '',
          'address': 'ул. Нова 1',
          'isActive': true,
        }, 201),
        null,
      );

      await expectLater(
        api.createLocation(name: 'A', address: 'B'),
        throwsUnexpectedResponse(),
      );
    });

    test('maps NAME_TAKEN to the structured exception', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'error': {
            'code': 'NAME_TAKEN',
            'message': 'A location with this name already exists.',
          },
        }, 409),
        null,
      );

      await expectLater(
        api.createLocation(name: 'A', address: 'B'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'NAME_TAKEN')
              .having((e) => e.statusCode, 'status', 409),
        ),
      );
    });
  });

  group('LocationsApi.updateLocation', () {
    test('sends the update route, body and bearer token', () async {
      late http.Request captured;
      final api = apiWith(
        (_) async => jsonResponse({
          'id': 7,
          'name': 'Обновен пункт',
          'address': 'ул. Нова 2',
          'isActive': true,
        }, 200),
        (request) => captured = request,
      );

      final result = await api.updateLocation(
        7,
        name: 'Обновен пункт',
        address: 'ул. Нова 2',
        token: 'admin-token',
      );

      expect(captured.method, 'PATCH');
      expect(captured.url.toString(), 'https://api.test/api/locations/7');
      expect(captured.headers['Authorization'], 'Bearer admin-token');
      expect(captured.headers['Content-Type'], contains('application/json'));
      expect(jsonDecode(captured.body), {
        'name': 'Обновен пункт',
        'address': 'ул. Нова 2',
      });
      expect(result.name, 'Обновен пункт');
      expect(result.address, 'ул. Нова 2');
    });

    test('throws UNEXPECTED_RESPONSE for a malformed updated record', () async {
      final api = apiWith(
        (_) async => jsonResponse({'id': 7, 'name': 'A'}, 200),
        null,
      );

      await expectLater(
        api.updateLocation(7, name: 'A', address: 'B'),
        throwsUnexpectedResponse(),
      );
    });

    test('exposes a 401 as an unauthorized exception', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'error': {'code': 'UNAUTHORIZED', 'message': 'Expired.'},
        }, 401),
        null,
      );

      await expectLater(
        api.updateLocation(7, name: 'A', address: 'B', token: 'expired'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'UNAUTHORIZED')
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    });
  });

  group('LocationsApi.setLocationStatus', () {
    for (final active in [false, true]) {
      test('sends isActive: $active and parses the result', () async {
        late http.Request captured;
        final api = apiWith(
          (_) async => jsonResponse({
            'id': 7,
            'name': 'Пункт',
            'address': 'ул. Нова 1',
            'isActive': active,
          }, 200),
          (request) => captured = request,
        );

        final result = await api.setLocationStatus(
          7,
          isActive: active,
          token: 'admin-token',
        );

        expect(captured.method, 'PATCH');
        expect(
          captured.url.toString(),
          'https://api.test/api/locations/7/status',
        );
        expect(captured.headers['Authorization'], 'Bearer admin-token');
        expect(jsonDecode(captured.body), {'isActive': active});
        expect(result.id, 7);
        expect(result.isActive, active);
      });
    }

    test('throws UNEXPECTED_RESPONSE for a malformed status record', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'id': 7,
          'name': 'Пункт',
          'address': 'ул. Нова 1',
          'isActive': 'false',
        }, 200),
        null,
      );

      await expectLater(
        api.setLocationStatus(7, isActive: false),
        throwsUnexpectedResponse(),
      );
    });

    test('maps structured errors from the status route', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'error': {'code': 'NOT_FOUND', 'message': 'Location not found.'},
        }, 404),
        null,
      );

      await expectLater(
        api.setLocationStatus(7, isActive: false),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'NOT_FOUND')
              .having((e) => e.statusCode, 'status', 404),
        ),
      );
    });
  });
}
