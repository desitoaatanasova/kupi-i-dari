import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/models/app_user.dart';

import 'fakes.dart';

void main() {
  group('SessionController', () {
    test('staff sign-in stores the session and notifies listeners', () async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      final result = await controller.signInStaff(
        phone: '+359881000001',
        password: 'secret',
      );

      expect(result, isNotNull);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.role, UserRole.admin);
      expect(controller.isBusy, isFalse);
      expect(api.loginCalls, 1);
      expect(notifications, greaterThanOrEqualTo(2));
    });

    test(
      'a failed sign-in leaves the session unauthenticated and not busy',
      () async {
        final api =
            FakeAuthApi()..loginError = buildError(401, 'INVALID_CREDENTIALS');
        final controller = SessionController(authApi: api);
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        await expectLater(
          controller.signInStaff(phone: '+359881000001', password: 'bad'),
          throwsA(isA<ApiException>()),
        );

        expect(controller.isAuthenticated, isFalse);
        expect(controller.isBusy, isFalse);
        expect(notifications, greaterThanOrEqualTo(2));
      },
    );

    test('a failed public login never clears an existing session', () async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      api.loginError = buildError(401, 'INVALID_CREDENTIALS');
      await expectLater(
        controller.signInStaff(phone: '+359881000001', password: 'bad'),
        throwsA(isA<ApiException>()),
      );

      expect(controller.isAuthenticated, isTrue);
    });

    test('volunteer registration stores the confirmed session', () async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);

      final result = await controller.registerVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
        role: UserRole.volunteer,
      );

      expect(result, isNotNull);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.role, UserRole.volunteer);
      expect(controller.session?.token, 'register-token');
      expect(api.registerCalls, 1);
      expect(api.lastRegisterFirstName, 'Ана');
      expect(api.lastRegisterLastName, 'Тестова');
      expect(api.lastRegisterPhone, '+359881000001');
      expect(api.lastRegisterRole, UserRole.volunteer);
    });

    test('a failed registration changes no session and resets busy', () async {
      final api = FakeAuthApi()..registerError = buildError(409, 'PHONE_TAKEN');
      final controller = SessionController(authApi: api);

      await expectLater(
        controller.registerVolunteer(
          firstName: 'Ана',
          lastName: 'Тестова',
          phone: '+359881000001',
          role: UserRole.volunteer,
        ),
        throwsA(isA<ApiException>()),
      );

      expect(controller.isAuthenticated, isFalse);
      expect(controller.isBusy, isFalse);
      expect(controller.session, isNull);
      expect(api.registerCalls, 1);
    });

    test('strict volunteer login stores the confirmed session', () async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);

      final result = await controller.signInVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
      );

      expect(result, isNotNull);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.role, UserRole.volunteer);
      expect(controller.session?.token, 'vol-login-token');
      expect(api.volunteerLoginCalls, 1);
      expect(api.volunteerCalls, 0);
      expect(api.lastVolunteerLoginFirstName, 'Ана');
      expect(api.lastVolunteerLoginLastName, 'Тестова');
      expect(api.lastVolunteerLoginPhone, '+359881000001');
    });

    test('volunteer login takes the role from the backend response', () async {
      final api =
          FakeAuthApi()
            ..volunteerLoginResponse = buildSession(role: UserRole.responsible);
      final controller = SessionController(authApi: api);

      await controller.signInVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
      );

      expect(controller.role, UserRole.responsible);
    });

    test('a failed volunteer login never clears an existing session', () async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      api.volunteerLoginError = buildError(401, 'INVALID_CREDENTIALS');
      await expectLater(
        controller.signInVolunteer(
          firstName: 'Ана',
          lastName: 'Тестова',
          phone: '+359881000001',
        ),
        throwsA(isA<ApiException>()),
      );

      expect(controller.isAuthenticated, isTrue);
      expect(controller.role, UserRole.admin);
      expect(api.volunteerLoginCalls, 1);
    });

    test('volunteer identification creates a volunteer session', () async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);

      await controller.identifyVolunteer(
        firstName: 'Ана',
        lastName: 'Тестова',
        phone: '+359881000001',
      );

      expect(controller.isAuthenticated, isTrue);
      expect(controller.role, UserRole.volunteer);
      expect(api.volunteerCalls, 1);
    });

    test('sign-out clears the session even when the request fails', () async {
      final api = FakeAuthApi()..logoutError = buildError(500, 'HTTP_ERROR');
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await controller.signOut();

      expect(controller.isAuthenticated, isFalse);
      expect(api.logoutCalls, 1);
    });

    test(
      'handleUnauthorized clears the session and sets a safe notice',
      () async {
        final api = FakeAuthApi();
        final controller = SessionController(authApi: api);
        await controller.signInStaff(
          phone: '+359881000001',
          password: 'secret',
        );

        controller.handleUnauthorized();

        expect(controller.isAuthenticated, isFalse);
        expect(controller.notice, 'Сесията изтече. Влезте отново.');
      },
    );

    test('respects a mandatory password change', () async {
      final api =
          FakeAuthApi()..loginResponse = buildSession(mustChangePassword: true);
      final controller = SessionController(authApi: api);

      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      expect(controller.mustChangePassword, isTrue);
    });

    test('an unknown role never grants staff privileges', () async {
      final api =
          FakeAuthApi()..loginResponse = buildSession(role: UserRole.unknown);
      final controller = SessionController(authApi: api);

      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      expect(controller.role, UserRole.unknown);
      expect(controller.role.isStaff, isFalse);
      expect(controller.role.isAdmin, isFalse);
    });

    test('changePassword adopts the refreshed session', () async {
      final api =
          FakeAuthApi()..changeResponse = buildSession(token: 'changed-token');
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      final updated = await controller.changePassword(
        currentPassword: 'old',
        newPassword: 'newpass123',
      );

      expect(updated, isNotNull);
      expect(controller.session?.token, 'changed-token');
      expect(api.changeCalls, 1);
    });

    test('a wrong current password does not clear the session', () async {
      final api =
          FakeAuthApi()..changeError = buildError(401, 'INVALID_CREDENTIALS');
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await expectLater(
        controller.changePassword(
          currentPassword: 'bad',
          newPassword: 'newpass123',
        ),
        throwsA(isA<ApiException>()),
      );

      expect(controller.isAuthenticated, isTrue);
    });

    test('an expired session during a change clears it', () async {
      final api = FakeAuthApi()..changeError = buildError(401, 'UNAUTHORIZED');
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await expectLater(
        controller.changePassword(
          currentPassword: 'old',
          newPassword: 'newpass123',
        ),
        throwsA(isA<ApiException>()),
      );

      expect(controller.isAuthenticated, isFalse);
      expect(controller.notice, 'Сесията изтече. Влезте отново.');
    });

    test('refreshUser updates the stored profile', () async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      api.meResponse = controller.user!.copyWith(mustChangePassword: false);
      final user = await controller.refreshUser();

      expect(user, isNotNull);
      expect(api.meCalls, 1);
    });
  });
}
