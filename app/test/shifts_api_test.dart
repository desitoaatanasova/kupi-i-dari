import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/shifts_api.dart';
import 'package:kupi_i_dari/core/statuses.dart';

http.Response jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('ShiftsApi', () {
    test('parses list envelope', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/shifts');
        expect(request.headers['Authorization'], isNull);
        return jsonResponse({
          'shifts': [
            {
              'id': 1,
              'title': 'Сутрешна смяна',
              'date': '2026-05-01',
              'startTime': '09:00:00',
              'endTime': '13:00:00',
              'status': 'OPEN',
            },
          ],
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final shifts = await api.list();
      expect(shifts.length, 1);
      expect(shifts.first.id, 1);
      expect(shifts.first.title, 'Сутрешна смяна');
      expect(shifts.first.date, DateTime(2026, 5, 1));
      expect(shifts.first.startTime, '09:00:00');
      expect(shifts.first.endTime, '13:00:00');
      expect(shifts.first.status, ShiftStatus.available);
      expect(shifts.first.locationIds, isEmpty);
      // The backend never exposes a count or a capacity: they stay unknown
      // instead of being invented as 0/1.
      expect(shifts.first.registeredCount, isNull);
      expect(shifts.first.capacity, isNull);
      expect(shifts.first.isFull, isFalse);
      expect(shifts.first.remaining, isNull);
    });

    test('parses nullable title and maps statuses', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'shifts': [
            {
              'id': 2,
              'title': null,
              'date': '2026-05-02',
              'startTime': '08:00',
              'endTime': '12:00',
              'status': 'CLOSED',
            },
            {
              'id': 3,
              'title': 'Друго',
              'date': '2026-05-03',
              'startTime': '10:00:00',
              'endTime': '14:00:00',
              'status': 'CANCELLED',
            },
            {
              'id': 4,
              'title': 'Трето',
              'date': '2026-05-04',
              'startTime': '11:00:00',
              'endTime': '15:00:00',
              'status': 'DRAFT',
            },
          ],
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final shifts = await api.list();
      expect(shifts[0].title, '');
      expect(shifts[0].status, ShiftStatus.completed);
      expect(shifts[1].status, ShiftStatus.archived);
      expect(shifts[2].status, ShiftStatus.draft);
    });

    test('sends token and query params', () async {
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer abc123');
        expect(request.url.queryParameters['status'], 'OPEN');
        expect(request.url.queryParameters['date'], '2026-05-01');
        return jsonResponse({'shifts': []}, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      await api.list(token: 'abc123', status: 'OPEN', date: '2026-05-01');
    });

    test('empty list', () async {
      final client = MockClient((request) async {
        return jsonResponse({'shifts': []}, 200);
      });
      final api = ShiftsApi(ApiClient(httpClient: client));
      final shifts = await api.list();
      expect(shifts, isEmpty);
    });

    test('malformed envelope throws UNEXPECTED_RESPONSE', () async {
      final client = MockClient((request) async {
        return jsonResponse({'items': []}, 200);
      });
      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.list(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
    });

    test('malformed record throws UNEXPECTED_RESPONSE', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'shifts': [
            {'id': 'bad'},
          ],
        }, 200);
      });
      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.list(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
    });

    test('parses detail with locations and nullable myRegistration', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/shifts/10');
        return jsonResponse({
          'id': 10,
          'title': 'Детайл',
          'date': '2026-05-05',
          'startTime': '09:00:00',
          'endTime': '13:00:00',
          'status': 'OPEN',
          'locations': [
            {'id': 1, 'name': 'Център', 'address': 'ул. Х', 'isActive': true},
          ],
          'myRegistration': null,
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final detail = await api.getDetail(10);
      expect(detail.shift.id, 10);
      expect(detail.locations.length, 1);
      expect(detail.locations.first.name, 'Център');
      expect(detail.myRegistration, isNull);
    });

    test('parses detail with myRegistration', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'id': 11,
          'title': null,
          'date': '2026-05-06',
          'startTime': '08:00:00',
          'endTime': '12:00:00',
          'status': 'OPEN',
          'locations': [],
          'myRegistration': {'status': 'REGISTERED'},
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final detail = await api.getDetail(11);
      expect(detail.shift.title, '');
      expect(detail.myRegistration?.status, 'REGISTERED');
      expect(detail.locations, isEmpty);
    });

    test('detail malformed locations throws UNEXPECTED_RESPONSE', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'id': 12,
          'title': 'X',
          'date': '2026-05-07',
          'startTime': '08:00:00',
          'endTime': '12:00:00',
          'status': 'OPEN',
          'locations': {'bad': true},
          'myRegistration': null,
        }, 200);
      });
      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.getDetail(12),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
    });
  });

  group('ShiftsApi.registerSelf', () {
    test(
      'posts to the registration endpoint with a bearer token and no body',
      () async {
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/shifts/5/registrations');
          expect(request.headers['Authorization'], 'Bearer vol-token');
          expect(request.headers['Content-Type'], isNull);
          expect(request.body, isEmpty);
          return jsonResponse({
            'id': 9,
            'shiftId': 5,
            'userId': 1,
            'status': 'REGISTERED',
          }, 201);
        });

        final api = ShiftsApi(ApiClient(httpClient: client));
        final result = await api.registerSelf(5, token: 'vol-token');
        expect(result.id, 9);
        expect(result.shiftId, 5);
        expect(result.userId, 1);
        expect(result.status, 'REGISTERED');
      },
    );

    test('parses a 200 reactivation response identically', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'id': 10,
          'shiftId': 5,
          'userId': 1,
          'status': 'REGISTERED',
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final result = await api.registerSelf(5);
      expect(result.id, 10);
      expect(result.status, 'REGISTERED');
    });

    test('rejects a malformed success response', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'id': 'not-an-int',
          'shiftId': 5,
          'userId': 1,
          'status': 'REGISTERED',
        }, 201);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.registerSelf(5),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
    });

    test('rejects a response without a status', () async {
      final client = MockClient((request) async {
        return jsonResponse({'id': 9, 'shiftId': 5, 'userId': 1}, 201);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.registerSelf(5),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
    });

    test('rejects a non-positive shift id before sending a request', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return jsonResponse({}, 201);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.registerSelf(0),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('maps registration error codes and statuses', () async {
      const cases = <String, int>{
        'ALREADY_REGISTERED': 409,
        'SHIFT_NOT_OPEN': 409,
        'FORBIDDEN': 403,
        'ACCOUNT_DISABLED': 403,
        'MUST_CHANGE_PASSWORD': 403,
        'NOT_FOUND': 404,
        'VALIDATION_ERROR': 400,
        'UNAUTHORIZED': 401,
        'RATE_LIMITED': 429,
      };

      for (final entry in cases.entries) {
        final client = MockClient((request) async {
          return jsonResponse({
            'error': {'code': entry.key, 'message': 'server text'},
          }, entry.value);
        });

        final api = ShiftsApi(ApiClient(httpClient: client));
        await expectLater(
          () => api.registerSelf(5),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', entry.key)
                .having((e) => e.statusCode, 'statusCode', entry.value),
          ),
        );
      }
    });
  });

  group('ShiftsApi admin writes', () {
    test('creates a shift and parses the returned detail', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/shifts');
        expect(request.headers['Authorization'], 'Bearer admin-token');
        expect(request.headers['Content-Type'], contains('application/json'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['title'], 'Нова смяна');
        expect(body['date'], '2026-05-10');
        expect(body['startTime'], '09:00');
        expect(body['endTime'], '13:00');
        expect(body['locationIds'], [2, 3]);
        return jsonResponse({
          'id': 20,
          'title': 'Нова смяна',
          'date': '2026-05-10',
          'startTime': '09:00:00',
          'endTime': '13:00:00',
          'status': 'DRAFT',
          'locations': [
            {'id': 2, 'name': 'Пункт', 'address': 'Адрес', 'isActive': true},
          ],
        }, 201);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final detail = await api.createShift(
        title: 'Нова смяна',
        date: DateTime(2026, 5, 10),
        startTime: '09:00',
        endTime: '13:00',
        locationIds: const [2, 3],
        token: 'admin-token',
      );

      expect(detail.shift.id, 20);
      expect(detail.shift.status, ShiftStatus.draft);
      expect(detail.locations.single.id, 2);
      expect(detail.myRegistration, isNull);
    });

    test('omits an absent title when creating', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.containsKey('title'), isFalse);
        return jsonResponse({
          'id': 21,
          'title': null,
          'date': '2026-05-11',
          'startTime': '09:00:00',
          'endTime': '12:00:00',
          'status': 'DRAFT',
          'locations': [],
        }, 201);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final detail = await api.createShift(
        title: null,
        date: DateTime(2026, 5, 11),
        startTime: '09:00',
        endTime: '12:00',
        locationIds: const [1],
      );
      expect(detail.shift.title, '');
    });

    test('updates metadata with an explicit nullable title', () async {
      final client = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/api/shifts/7');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['title'], isNull);
        expect(body['date'], '2026-06-01');
        expect(body['startTime'], '10:30');
        expect(body['endTime'], '15:00');
        return jsonResponse({
          'id': 7,
          'title': null,
          'date': '2026-06-01',
          'startTime': '10:30:00',
          'endTime': '15:00:00',
          'status': 'OPEN',
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final shift = await api.updateShift(
        7,
        title: null,
        date: DateTime(2026, 6, 1),
        startTime: '10:30',
        endTime: '15:00',
      );
      expect(shift.id, 7);
      expect(shift.title, '');
      expect(shift.status, ShiftStatus.available);
    });

    test('changes status through the status endpoint', () async {
      final client = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/api/shifts/7/status');
        expect(request.headers['Authorization'], 'Bearer admin-token');
        expect(jsonDecode(request.body), {'status': 'CLOSED'});
        return jsonResponse({
          'id': 7,
          'title': 'Смяна',
          'date': '2026-06-01',
          'startTime': '10:30:00',
          'endTime': '15:00:00',
          'status': 'CLOSED',
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final shift = await api.setShiftStatus(7, 'CLOSED', token: 'admin-token');
      expect(shift.status, ShiftStatus.completed);
    });

    test('replaces the complete location set', () async {
      final client = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/shifts/7/locations');
        expect(jsonDecode(request.body), {
          'locationIds': [1, 4],
        });
        return jsonResponse({
          'locations': [
            {'id': 1, 'name': 'Активен', 'address': 'А', 'isActive': true},
            {'id': 4, 'name': 'Архив', 'address': 'Б', 'isActive': false},
          ],
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final locations = await api.replaceShiftLocations(
        7,
        locationIds: const [1, 4],
      );
      expect(locations.map((location) => location.id), [1, 4]);
      expect(locations.last.isActive, isFalse);
    });

    test('rejects invalid ids before sending a request', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return jsonResponse({}, 200);
      });
      final api = ShiftsApi(ApiClient(httpClient: client));

      await expectLater(
        () => api.createShift(
          title: null,
          date: DateTime(2026, 5, 1),
          startTime: '09:00',
          endTime: '10:00',
          locationIds: const [1, 1],
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
      await expectLater(
        () => api.setShiftStatus(0, 'OPEN'),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        () => api.replaceShiftLocations(1, locationIds: const []),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        () => api.createShift(
          title: null,
          date: DateTime(2026, 5, 1),
          startTime: '09:00',
          endTime: '10:00',
          locationIds: List<int>.generate(101, (index) => index + 1),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('ShiftsApi.cancelSelf', () {
    test('sends a patch with no body and parses the response', () async {
      final client = MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/api/shifts/5/registrations/9/cancel');
        expect(request.headers['Authorization'], 'Bearer vol-token');
        expect(request.headers['Content-Type'], isNull);
        expect(request.body, isEmpty);
        return jsonResponse({
          'id': 9,
          'shiftId': 5,
          'userId': 1,
          'status': 'CANCELLED',
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      final result = await api.cancelSelf(5, 9, token: 'vol-token');
      expect(result.id, 9);
      expect(result.shiftId, 5);
      expect(result.userId, 1);
      expect(result.status, 'CANCELLED');
    });

    test('rejects a malformed success response', () async {
      final client = MockClient((request) async {
        return jsonResponse({'id': 9, 'shiftId': 5}, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.cancelSelf(5, 9),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
    });

    test('rejects non-positive ids before sending a request', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return jsonResponse({
          'id': 9,
          'shiftId': 5,
          'userId': 1,
          'status': 'CANCELLED',
        }, 200);
      });

      final api = ShiftsApi(ApiClient(httpClient: client));
      expect(
        () => api.cancelSelf(0, 9),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
      expect(
        () => api.cancelSelf(5, 0),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'UNEXPECTED_RESPONSE',
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('maps cancellation error codes and statuses', () async {
      const cases = <String, int>{
        'NOT_FOUND': 404,
        'SHIFT_NOT_OPEN': 409,
        'FORBIDDEN': 403,
        'UNAUTHORIZED': 401,
        'RATE_LIMITED': 429,
      };

      for (final entry in cases.entries) {
        final client = MockClient((request) async {
          return jsonResponse({
            'error': {'code': entry.key, 'message': 'server text'},
          }, entry.value);
        });

        final api = ShiftsApi(ApiClient(httpClient: client));
        await expectLater(
          () => api.cancelSelf(5, 9),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', entry.key)
                .having((e) => e.statusCode, 'statusCode', entry.value),
          ),
        );
      }
    });
  });
}
