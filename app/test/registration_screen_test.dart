import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/models/app_user.dart';
import 'package:kupi_i_dari/screens/registration_screen.dart';
import 'package:kupi_i_dari/widgets/app_shell.dart';

import 'fakes.dart';

void setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<SessionController> pumpRegistration(
  WidgetTester tester,
  FakeAuthApi api,
) async {
  final controller = SessionController(authApi: api);
  setLargeSurface(tester);
  await tester.pumpWidget(
    SessionScope(
      controller: controller,
      child: const MaterialApp(home: RegistrationScreen()),
    ),
  );
  return controller;
}

Future<void> fillRegistration(
  WidgetTester tester, {
  String firstName = 'Ана',
  String lastName = 'Тестова',
  String phone = '0888123456',
}) async {
  await tester.enterText(
    find.byKey(const Key('registration-first-name-field')),
    firstName,
  );
  await tester.enterText(
    find.byKey(const Key('registration-last-name-field')),
    lastName,
  );
  await tester.enterText(
    find.byKey(const Key('registration-phone-field')),
    phone,
  );
}

Future<void> submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('registration-submit-button')));
  await tester.pump();
}

void main() {
  group('RegistrationScreen', () {
    testWidgets('offers only the volunteer role for public registration', (
      tester,
    ) async {
      await pumpRegistration(tester, FakeAuthApi());

      final volunteer = tester.widget<RadioListTile<UserRole>>(
        find.byKey(const Key('registration-role-volunteer')),
      );
      expect(volunteer.value, UserRole.volunteer);
      expect(volunteer.groupValue, UserRole.volunteer);

      final responsible = tester.widget<ListTile>(
        find.byKey(const Key('registration-role-responsible')),
      );
      final admin = tester.widget<ListTile>(
        find.byKey(const Key('registration-role-admin')),
      );
      expect(responsible.enabled, isFalse);
      expect(admin.enabled, isFalse);
      expect(
        find.text('Профилът се създава от администратор.'),
        findsNWidgets(2),
      );
    });

    testWidgets('validates required fields without calling the API', (
      tester,
    ) async {
      final api = FakeAuthApi();
      await pumpRegistration(tester, api);

      await submit(tester);

      expect(find.text('Попълнете полето.'), findsNWidgets(2));
      expect(find.text('Въведете телефонен номер.'), findsOneWidget);
      expect(api.registerCalls, 0);
    });

    testWidgets('rejects a malformed phone without calling the API', (
      tester,
    ) async {
      final api = FakeAuthApi();
      await pumpRegistration(tester, api);
      await fillRegistration(tester, phone: '123');
      await submit(tester);

      expect(find.text('Въведете валиден телефонен номер.'), findsOneWidget);
      expect(api.registerCalls, 0);
    });

    testWidgets('registers a volunteer and enters the app shell', (
      tester,
    ) async {
      final api = FakeAuthApi();
      final controller = await pumpRegistration(tester, api);
      await fillRegistration(
        tester,
        firstName: '  Ана ',
        lastName: ' Тестова  ',
      );

      await tester.tap(find.byKey(const Key('registration-submit-button')));
      await tester.pumpAndSettle();

      expect(api.registerCalls, 1);
      expect(api.lastRegisterFirstName, 'Ана');
      expect(api.lastRegisterLastName, 'Тестова');
      expect(api.lastRegisterPhone, '+359888123456');
      expect(api.lastRegisterRole, UserRole.volunteer);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.role, UserRole.volunteer);
      expect(controller.session?.token, 'register-token');
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.text('Пунктове за събиране'), findsOneWidget);
    });

    testWidgets('shows PHONE_TAKEN and does not authenticate', (tester) async {
      final api = FakeAuthApi()..registerError = buildError(409, 'PHONE_TAKEN');
      final controller = await pumpRegistration(tester, api);
      await fillRegistration(tester);

      await submit(tester);

      expect(find.text('Телефонният номер вече се използва.'), findsOneWidget);
      expect(controller.isAuthenticated, isFalse);
      expect(find.byType(RegistrationScreen), findsOneWidget);
    });

    testWidgets('shows network errors without leaving the form', (
      tester,
    ) async {
      final api =
          FakeAuthApi()
            ..registerError = const ApiException(
              code: ApiException.networkErrorCode,
              message: 'offline',
            );
      await pumpRegistration(tester, api);
      await fillRegistration(tester);

      await submit(tester);

      expect(
        find.text('Няма връзка със сървъра. Проверете интернет връзката.'),
        findsOneWidget,
      );
      expect(find.byType(RegistrationScreen), findsOneWidget);
    });

    testWidgets('prevents duplicate submissions while busy', (tester) async {
      final api = FakeAuthApi()..registerGate = Completer<void>();
      await pumpRegistration(tester, api);
      await fillRegistration(tester);

      await submit(tester);
      expect(api.registerCalls, 1);
      expect(find.text('Регистрирай се'), findsOneWidget);

      await tester.tap(find.byKey(const Key('registration-submit-button')));
      await tester.pump();
      expect(api.registerCalls, 1);

      api.registerGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AppShell), findsOneWidget);
    });
  });
}
