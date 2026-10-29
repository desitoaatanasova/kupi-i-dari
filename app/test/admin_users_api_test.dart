import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kupi_i_dari/core/api/admin_users_api.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/models/app_user.dart';

const _admin = {
  'id': 1,
  'phone': '+359881000001',
  'firstName': 'Анна',
  'lastName': 'Админова',
  'role': 'ADMIN',
  'isActive': true,
  'mustChangePassword': false,
};

const _responsible = {
  'id': 2,
  'phone': '+359881000002',
  'firstName': 'Радослав',
  'lastName': 'Отговорников',
  'role': 'RESPONSIBLE',
  'isActive': true,
  'mustChangePassword': true,
};

Map<String, Object?> pagePayload({
  List<Map<String, Object?>> users = const [_admin],
  int page = 1,
  int pageSize = 20,
  int? total,
  int? totalPages,
}) {
  final effectiveTotal = total ?? users.length;
  return {
    'users': users,
    'pagination': {
      'page': page,
      'pageSize': pageSize,
      'total': effectiveTotal,
      'totalPages':
          totalPages ??
          (effectiveTotal == 0
              ? 0
              : (effectiveTotal + pageSize - 1) ~/ pageSize),
    },
  };
}

http.Response jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

AdminUsersApi apiWith(
  Future<http.Response> Function(http.Request request) handler, {
  void Function(http.Request request)? onRequest,
}) {
  return AdminUsersApi(
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
  group('AdminUsersApi.listUserPage', () {
    test('sends all filters and parses the safe page shape', () async {
      late http.Request captured;
      final api = apiWith(
        (_) async => jsonResponse(
          pagePayload(
            users: const [_responsible],
            page: 2,
            pageSize: 20,
            total: 21,
          ),
          200,
        ),
        onRequest: (request) => captured = request,
      );

      final result = await api.listUserPage(
        token: 'admin-token',
        role: UserRole.responsible,
        isActive: true,
        page: 2,
      );

      expect(captured.method, 'GET');
      expect(captured.url.path, '/api/admin/users');
      expect(captured.url.queryParameters, {
        'page': '2',
        'pageSize': '20',
        'role': 'RESPONSIBLE',
        'isActive': 'true',
      });
      expect(captured.headers['Authorization'], 'Bearer admin-token');
      expect(result.page, 2);
      expect(result.pageSize, 20);
      expect(result.total, 21);
      expect(result.totalPages, 2);
      expect(result.users, hasLength(1));
      expect(result.users.single.id, 2);
      expect(result.users.single.firstName, 'Радослав');
      expect(result.users.single.role, UserRole.responsible);
      expect(result.users.single.mustChangePassword, isTrue);
    });

    test('omits optional filters and keeps the requested page size', () async {
      late http.Request captured;
      final api = apiWith(
        (_) async => jsonResponse(
          pagePayload(pageSize: 50, total: 0, users: const []),
          200,
        ),
        onRequest: (request) => captured = request,
      );

      final result = await api.listUserPage(token: 'admin-token', pageSize: 50);

      expect(captured.url.queryParameters, {'page': '1', 'pageSize': '50'});
      expect(result.users, isEmpty);
      expect(result.totalPages, 0);
    });

    test('rejects pagination outside the documented limits locally', () async {
      var requests = 0;
      final api = apiWith((_) async {
        requests++;
        return jsonResponse(pagePayload(), 200);
      });

      await expectLater(
        api.listUserPage(token: 't', page: 0),
        throwsUnexpectedResponse(),
      );
      await expectLater(
        api.listUserPage(token: 't', pageSize: 0),
        throwsUnexpectedResponse(),
      );
      await expectLater(
        api.listUserPage(token: 't', pageSize: 101),
        throwsUnexpectedResponse(),
      );
      await expectLater(
        api.listUserPage(token: 't', role: UserRole.unknown),
        throwsUnexpectedResponse(),
      );
      expect(requests, 0);
    });

    test('rejects malformed page envelopes', () async {
      final payloads = <Object?>[
        null,
        <Object?>[],
        <String, Object?>{},
        {'users': 'nope', 'pagination': <String, Object?>{}},
        {'users': <Object?>[], 'pagination': 'nope'},
        {
          'users': <Object?>[],
          'pagination': {
            'page': 2,
            'pageSize': 20,
            'total': 0,
            'totalPages': 0,
          },
        },
        {
          'users': <Object?>[],
          'pagination': {
            'page': 1,
            'pageSize': 10,
            'total': 0,
            'totalPages': 0,
          },
        },
        {
          'users': <Object?>[],
          'pagination': {
            'page': 1,
            'pageSize': 20,
            'total': 21,
            'totalPages': 1,
          },
        },
        {
          'users': <Object?>[],
          'pagination': {
            'page': 1,
            'pageSize': 20,
            'total': -1,
            'totalPages': 0,
          },
        },
      ];

      for (final payload in payloads) {
        final api = apiWith((_) async => jsonResponse(payload, 200));
        await expectLater(
          api.listUserPage(token: 't'),
          throwsUnexpectedResponse(),
          reason: 'payload: $payload',
        );
      }
    });

    test('rejects malformed or unsafe user records', () async {
      final malformed = <Map<String, Object?>>[
        <String, Object?>{..._admin, 'id': '1'},
        <String, Object?>{..._admin, 'id': 0},
        <String, Object?>{..._admin, 'phone': ''},
        <String, Object?>{..._admin, 'firstName': null},
        <String, Object?>{..._admin, 'lastName': ''},
        <String, Object?>{..._admin, 'role': 'SUPERUSER'},
        <String, Object?>{..._admin, 'isActive': 'true'},
        <String, Object?>{..._admin, 'mustChangePassword': 1},
        {
          'id': 1,
          'role': 'ADMIN',
          'isActive': true,
          'mustChangePassword': false,
        },
      ];

      for (final record in malformed) {
        final api = apiWith(
          (_) async => jsonResponse(pagePayload(users: [record]), 200),
        );
        await expectLater(
          api.listUserPage(token: 't'),
          throwsUnexpectedResponse(),
          reason: 'record: $record',
        );
      }
    });
  });

  group('AdminUsersApi writes', () {
    test(
      'creates staff with the exact backend body and parses the profile',
      () async {
        late http.Request request;
        final api = apiWith(
          (_) async => jsonResponse(_responsible, 201),
          onRequest: (value) => request = value,
        );

        final result = await api.createStaff(
          token: 'admin-token',
          firstName: 'Радослав',
          lastName: 'Отговорников',
          phone: '+359881000002',
          role: UserRole.responsible,
          password: 'secret123',
        );

        expect(request.method, 'POST');
        expect(request.url.path, '/api/admin/users');
        expect(request.headers['Content-Type'], startsWith('application/json'));
        expect(jsonDecode(request.body), {
          'firstName': 'Радослав',
          'lastName': 'Отговорников',
          'phone': '+359881000002',
          'role': 'RESPONSIBLE',
          'password': 'secret123',
        });
        expect(result.role, UserRole.responsible);
        expect(result.mustChangePassword, isTrue);
      },
    );

    test('refuses to create a volunteer or unknown role locally', () async {
      var requests = 0;
      final api = apiWith((_) async {
        requests++;
        return jsonResponse(_admin, 201);
      });

      await expectLater(
        api.createStaff(
          token: 't',
          firstName: 'A',
          lastName: 'B',
          phone: '+359881000001',
          role: UserRole.volunteer,
          password: 'secret123',
        ),
        throwsUnexpectedResponse(),
      );
      await expectLater(
        api.createStaff(
          token: 't',
          firstName: 'A',
          lastName: 'B',
          phone: '+359881000001',
          role: UserRole.unknown,
          password: 'secret123',
        ),
        throwsUnexpectedResponse(),
      );
      expect(requests, 0);
    });

    test('updates the editable profile fields only', () async {
      late http.Request request;
      final api = apiWith(
        (_) async => jsonResponse({..._admin, 'firstName': 'Нова'}, 200),
        onRequest: (value) => request = value,
      );

      final result = await api.updateUserProfile(
        1,
        token: 'admin-token',
        firstName: 'Нова',
        lastName: 'Админова',
        phone: '+359881000001',
      );

      expect(request.method, 'PATCH');
      expect(request.url.path, '/api/admin/users/1');
      expect(jsonDecode(request.body), {
        'firstName': 'Нова',
        'lastName': 'Админова',
        'phone': '+359881000001',
      });
      expect(result.firstName, 'Нова');
    });

    test('sets status through the dedicated endpoint', () async {
      late http.Request request;
      final api = apiWith(
        (_) async => jsonResponse({..._admin, 'isActive': false}, 200),
        onRequest: (value) => request = value,
      );

      final result = await api.setUserStatus(
        1,
        token: 'admin-token',
        isActive: false,
      );

      expect(request.method, 'PATCH');
      expect(request.url.path, '/api/admin/users/1/status');
      expect(jsonDecode(request.body), {'isActive': false});
      expect(result.isActive, isFalse);
    });

    test('rejects invalid ids locally without sending a request', () async {
      var requests = 0;
      final api = apiWith((_) async {
        requests++;
        return jsonResponse(_admin, 200);
      });

      await expectLater(
        api.updateUserProfile(
          0,
          token: 't',
          firstName: 'A',
          lastName: 'B',
          phone: '+359881000001',
        ),
        throwsUnexpectedResponse(),
      );
      await expectLater(
        api.setUserStatus(0, token: 't', isActive: false),
        throwsUnexpectedResponse(),
      );
      expect(requests, 0);
    });

    test('preserves documented backend error codes', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'error': {'code': 'PHONE_TAKEN', 'message': 'Phone is already used.'},
        }, 409),
      );

      await expectLater(
        api.createStaff(
          token: 't',
          firstName: 'A',
          lastName: 'B',
          phone: '+359881000001',
          role: UserRole.admin,
          password: 'secret123',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'PHONE_TAKEN'),
        ),
      );
    });
  });
}
