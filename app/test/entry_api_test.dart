import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/entry_api.dart';
import 'package:kupi_i_dari/core/statuses.dart';

http.Response jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> _contextBody({
  bool canSubmit = true,
  String? submissionError,
}) {
  return {
    'shift': {
      'id': 5,
      'title': 'Смяна',
      'date': '2026-05-01',
      'startTime': '09:00:00',
      'endTime': '13:00:00',
      'status': 'OPEN',
    },
    'canSubmit': canSubmit,
    'submissionError': submissionError,
    'entryWindow': {
      'opensAt': '2026-05-01T09:00:00+03:00',
      'closesAt': '2026-05-01T13:30:00+03:00',
    },
    'locations': [
      {'id': 1, 'name': 'Център', 'address': 'ул. Витоша 1', 'isActive': true},
    ],
    'quantities': [
      {'id': 9, 'shiftId': 5, 'locationId': 1, 'variantId': 100, 'quantity': 3},
    ],
  };
}

void main() {
  group('EntryApi.getEntryContext', () {
    test('parses the entry context shape', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/shifts/5/entry');
        expect(request.headers['Authorization'], 'Bearer token-123');
        return jsonResponse(_contextBody(), 200);
      });

      final api = EntryApi(ApiClient(httpClient: client));
      final context = await api.getEntryContext(5, token: 'token-123');
      expect(context.shift.id, 5);
      expect(context.shift.status, ShiftStatus.available);
      expect(context.canSubmit, isTrue);
      expect(context.submissionError, isNull);
      expect(context.entryWindow.opensAt, '2026-05-01T09:00:00+03:00');
      expect(context.locations.single.name, 'Център');
      expect(context.quantities.single.variantId, 100);
      expect(context.quantities.single.quantity, 3);
    });

    test('parses a submission error reason', () async {
      final client = MockClient((request) async {
        return jsonResponse(
          _contextBody(
            canSubmit: false,
            submissionError: 'REGISTRATION_REQUIRED',
          ),
          200,
        );
      });

      final api = EntryApi(ApiClient(httpClient: client));
      final context = await api.getEntryContext(5);
      expect(context.canSubmit, isFalse);
      expect(context.submissionError, 'REGISTRATION_REQUIRED');
    });

    test('rejects malformed entry payloads', () async {
      final client = MockClient((request) async {
        final body = _contextBody();
        body['canSubmit'] = 'yes';
        return jsonResponse(body, 200);
      });

      final api = EntryApi(ApiClient(httpClient: client));
      expect(
        () => api.getEntryContext(5),
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

  group('EntryApi.submitQuantities', () {
    test('sends the exact body and parses stored rows', () async {
      final client = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/shifts/5/quantities');
        expect(request.headers['Authorization'], 'Bearer token-123');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['locationId'], 1);
        expect(body['quantities'], [
          {'variantId': 100, 'quantity': 2},
        ]);
        return jsonResponse({
          'quantities': [
            {
              'id': 1,
              'shiftId': 5,
              'locationId': 1,
              'variantId': 100,
              'quantity': 2,
            },
          ],
        }, 200);
      });

      final api = EntryApi(ApiClient(httpClient: client));
      final saved = await api.submitQuantities(
        5,
        locationId: 1,
        items: [(variantId: 100, quantity: 2)],
        token: 'token-123',
      );
      expect(saved.single.variantId, 100);
      expect(saved.single.quantity, 2);
    });

    test('maps a closed entry window to an ApiException', () async {
      final client = MockClient((request) async {
        return jsonResponse({
          'error': {
            'code': 'ENTRY_WINDOW_CLOSED',
            'message': 'The entry window has closed.',
          },
        }, 409);
      });

      final api = EntryApi(ApiClient(httpClient: client));
      expect(
        () => api.submitQuantities(
          5,
          locationId: 1,
          items: [(variantId: 100, quantity: 1)],
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'ENTRY_WINDOW_CLOSED')
              .having((e) => e.statusCode, 'statusCode', 409),
        ),
      );
    });

    test('rejects non-positive ids before sending a request', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return jsonResponse({}, 200);
      });

      final api = EntryApi(ApiClient(httpClient: client));
      expect(
        () => api.submitQuantities(
          0,
          locationId: 1,
          items: [(variantId: 1, quantity: 1)],
        ),
        throwsA(isA<ApiException>()),
      );
      expect(called, isFalse);
    });
  });
}
