import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kupi_i_dari/core/api/api_client.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/auth_api.dart';
import 'package:kupi_i_dari/models/app_user.dart';

const profile = {
  'id': 5,
  'phone': '+359881000001',
  'firstName': 'Ана',
  'lastName': 'Тестова',
  'role': 'RESPONSIBLE',
  'isActive': true,
  'mustChangePassword': false,
};

http.Response jsonResponse(Object? body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

AuthApi apiWith(Future<http.Response> Function(http.Request request) handler) {
  return AuthApi(
    ApiClient(baseUrl: 'https://api.test/api', httpClient: MockClient(handler)),
  );
}

void main() {
  group('AuthApi.login', () {
    test('posts phone + password and parses the session', () async {
      late http.Request captured;
      final api = apiWith((request) async {
        captured = request;
        return jsonResponse({
          'token': 'jwt-1',
          'tokenType': 'Bearer',
          'expiresIn': 3600,
          'user': profile,
        }, 200);
      });

      final session = await api.login(phone: '+359881000001', password: 'pw');

      expect(captured.url.path, '/api/auth/login');
      expect(jsonDecode(captured.body), {
        'phone': '+359881000001',
        'password': 'pw',
      });
      expect(session.token, 'jwt-1');
      expect(session.expiresIn, 3600);
      expect(session.user.role, UserRole.responsible);
      expect(session.user.mustChangePassword, isFalse);
    });

    test('throws UNEXPECTED_RESPONSE when the token is missing', () async {
      final api = apiWith((_) async => jsonResponse({'user': profile}, 200));

      await expectLater(
        api.login(phone: '+359881000001', password: 'pw'),
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

  group('AuthApi.registerVolunteer', () {
    test('posts the selected role and parses the server session', () async {
      late http.Request captured;
      final api = apiWith((request) async {
        captured = request;
        return jsonResponse({
          'token': 'jwt-register',
          'tokenType': 'Bearer',
          'expiresIn': 3600,
          'user': {...profile, 'role': 'VOLUNTEER'},
        }, 201);
      });

      final session = await api.registerVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
        role: UserRole.volunteer,
      );

      expect(captured.url.path, '/api/auth/register');
      expect(jsonDecode(captured.body), {
        'firstName': 'Ана',
        'lastName': 'Тестова',
        'phone': '+359881000001',
        'role': 'VOLUNTEER',
      });
      expect(session.token, 'jwt-register');
      expect(session.user.role, UserRole.volunteer);
    });

    test('takes the role from the backend response', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'token': 'jwt-register',
          'tokenType': 'Bearer',
          'expiresIn': 3600,
          'user': profile,
        }, 201),
      );

      final session = await api.registerVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
        role: UserRole.volunteer,
      );

      expect(session.user.role, UserRole.responsible);
    });

    test('throws UNEXPECTED_RESPONSE for a malformed session', () async {
      final api = apiWith((_) async => jsonResponse({'user': profile}, 201));

      await expectLater(
        api.registerVolunteer(
          firstName: 'Ана',
          lastName: 'Тестова',
          phone: '+359881000001',
          role: UserRole.volunteer,
        ),
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

  group('AuthApi.loginVolunteer', () {
    test('posts name + phone to the strict login endpoint', () async {
      late http.Request captured;
      final api = apiWith((request) async {
        captured = request;
        return jsonResponse({
          'token': 'jwt-vol-login',
          'tokenType': 'Bearer',
          'expiresIn': 3600,
          'user': {...profile, 'role': 'VOLUNTEER'},
        }, 200);
      });

      final session = await api.loginVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
      );

      expect(captured.url.path, '/api/auth/volunteer/login');
      expect(jsonDecode(captured.body), {
        'firstName': 'Ана',
        'lastName': 'Тестова',
        'phone': '+359881000001',
      });
      expect(session.user.role, UserRole.volunteer);
    });

    test('throws UNEXPECTED_RESPONSE for a malformed session', () async {
      final api = apiWith((_) async => jsonResponse({'token': 'jwt'}, 200));

      await expectLater(
        api.loginVolunteer(
          firstName: 'Ана',
          lastName: 'Тестова',
          phone: '+359881000001',
        ),
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

  group('AuthApi.identifyVolunteer', () {
    test('posts name + phone and parses the session', () async {
      late http.Request captured;
      final api = apiWith((request) async {
        captured = request;
        return jsonResponse({
          'token': 'jwt-vol',
          'tokenType': 'Bearer',
          'expiresIn': 3600,
          'user': {...profile, 'role': 'VOLUNTEER'},
        }, 200);
      });

      final session = await api.identifyVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
      );

      expect(captured.url.path, '/api/auth/volunteer');
      expect(jsonDecode(captured.body), {
        'firstName': 'Ана',
        'lastName': 'Тестова',
        'phone': '+359881000001',
      });
      expect(session.user.role, UserRole.volunteer);
    });
  });

  group('AuthApi.me', () {
    test('parses the flat safe profile', () async {
      late http.Request captured;
      final api = apiWith((request) async {
        captured = request;
        return jsonResponse(profile, 200);
      });

      final user = await api.me(token: 'jwt-1');

      expect(captured.url.path, '/api/auth/me');
      expect(captured.headers['Authorization'], 'Bearer jwt-1');
      expect(user.id, 5);
      expect(user.role, UserRole.responsible);
    });

    test('also accepts a { user } envelope', () async {
      final api = apiWith((_) async => jsonResponse({'user': profile}, 200));

      final user = await api.me(token: 'jwt-1');

      expect(user.firstName, 'Ана');
    });

    test('maps an unknown role to UserRole.unknown', () async {
      final api = apiWith(
        (_) async => jsonResponse({...profile, 'role': 'SUPERUSER'}, 200),
      );

      final user = await api.me(token: 'jwt-1');

      expect(user.role, UserRole.unknown);
      expect(user.role.isStaff, isFalse);
    });

    test('throws UNEXPECTED_RESPONSE for a malformed body', () async {
      final api = apiWith((_) async => jsonResponse(null, 200));

      await expectLater(
        api.me(token: 'jwt-1'),
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

  group('AuthApi.changePassword', () {
    test('posts both passwords and parses the fresh session', () async {
      late http.Request captured;
      final api = apiWith((request) async {
        captured = request;
        return jsonResponse({
          'token': 'jwt-2',
          'tokenType': 'Bearer',
          'expiresIn': 3600,
          'user': profile,
        }, 200);
      });

      final session = await api.changePassword(
        token: 'jwt-1',
        currentPassword: 'old',
        newPassword: 'newpass123',
      );

      expect(captured.url.path, '/api/auth/password/change');
      expect(captured.headers['Authorization'], 'Bearer jwt-1');
      expect(jsonDecode(captured.body), {
        'currentPassword': 'old',
        'newPassword': 'newpass123',
      });
      expect(session.token, 'jwt-2');
    });
  });

  group('AuthApi.logout', () {
    test('resolves on the empty 204 response', () async {
      late http.Request captured;
      final api = apiWith((request) async {
        captured = request;
        return http.Response('', 204);
      });

      await api.logout(token: 'jwt-1');

      expect(captured.url.path, '/api/auth/logout');
      expect(captured.headers['Authorization'], 'Bearer jwt-1');
    });
  });
}
