import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/models/app_user.dart';
import 'package:kupi_i_dari/screens/change_password_screen.dart';
import 'package:kupi_i_dari/screens/login_screen.dart';
import 'package:kupi_i_dari/screens/registration_screen.dart';
import 'package:kupi_i_dari/screens/start_screen.dart';
import 'package:kupi_i_dari/screens/volunteer_identification_screen.dart';
import 'package:kupi_i_dari/widgets/app_shell.dart';

import 'fakes.dart';

void setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<SessionController> pumpInScope(
  WidgetTester tester,
  SessionController controller,
  Widget home,
) async {
  setLargeSurface(tester);
  await tester.pumpWidget(
    SessionScope(controller: controller, child: MaterialApp(home: home)),
  );
  return controller;
}

Future<void> fillLogin(
  WidgetTester tester, {
  String phone = '0888123456',
  String password = 'secret123',
}) async {
  await tester.enterText(find.byType(TextFormField).at(0), phone);
  await tester.enterText(find.byType(TextFormField).at(1), password);
}

void main() {
  group('LoginScreen', () {
    testWidgets('validates required fields without calling the API', (
      tester,
    ) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const LoginScreen(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pump();

      expect(find.text('Въведете телефонен номер.'), findsOneWidget);
      expect(find.text('Въведете парола.'), findsOneWidget);
      expect(api.loginCalls, 0);
    });

    testWidgets('rejects a malformed phone number', (tester) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const LoginScreen(),
      );

      await tester.enterText(find.byType(TextFormField).at(0), '123');
      await tester.enterText(find.byType(TextFormField).at(1), 'secret123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pump();

      expect(find.text('Въведете валиден телефонен номер.'), findsOneWidget);
      expect(api.loginCalls, 0);
    });

    testWidgets('signs in and navigates to the app shell', (tester) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const LoginScreen(),
      );

      await fillLogin(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pumpAndSettle();

      expect(api.loginCalls, 1);
      expect(api.lastLoginPhone, '+359888123456');
      expect(find.text('Пунктове за събиране'), findsOneWidget);
    });

    testWidgets('prevents duplicate submissions while loading', (tester) async {
      final api = FakeAuthApi()..loginGate = Completer<void>();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const LoginScreen(),
      );

      await fillLogin(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pump();

      expect(api.loginCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(api.loginCalls, 1);

      api.loginGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Пунктове за събиране'), findsOneWidget);
    });

    testWidgets('shows a Bulgarian message on invalid credentials', (
      tester,
    ) async {
      final api =
          FakeAuthApi()..loginError = buildError(401, 'INVALID_CREDENTIALS');
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const LoginScreen(),
      );

      await fillLogin(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pump();

      expect(find.text('Грешен телефон или парола.'), findsOneWidget);
    });

    testWidgets('shows a rate-limit message', (tester) async {
      final api = FakeAuthApi()..loginError = buildError(429, 'RATE_LIMITED');
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const LoginScreen(),
      );

      await fillLogin(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pump();

      expect(
        find.text('Твърде много опити. Изчакайте малко и опитайте отново.'),
        findsOneWidget,
      );
    });

    testWidgets('routes a forced password change to the change screen', (
      tester,
    ) async {
      final api =
          FakeAuthApi()..loginResponse = buildSession(mustChangePassword: true);
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const LoginScreen(),
      );

      await fillLogin(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pumpAndSettle();

      expect(find.byType(ChangePasswordScreen), findsOneWidget);
    });
  });

  group('VolunteerIdentificationScreen', () {
    testWidgets('validates the form before logging in', (tester) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const VolunteerIdentificationScreen(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Влез'));
      await tester.pump();

      expect(find.text('Попълнете полето.'), findsNWidgets(2));
      expect(find.text('Въведете телефонен номер.'), findsOneWidget);
      expect(api.volunteerLoginCalls, 0);
      expect(find.text('Парола'), findsNothing);
    });

    testWidgets('logs in an existing volunteer without a password', (
      tester,
    ) async {
      final api = FakeAuthApi();
      final controller = await pumpInScope(
        tester,
        SessionController(authApi: api),
        const VolunteerIdentificationScreen(),
      );

      await tester.enterText(find.byType(TextFormField).at(0), 'Ана');
      await tester.enterText(find.byType(TextFormField).at(1), 'Тестова');
      await tester.enterText(find.byType(TextFormField).at(2), '0888123456');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Влез'));
      await tester.pumpAndSettle();

      expect(api.volunteerLoginCalls, 1);
      expect(api.volunteerCalls, 0);
      expect(api.lastVolunteerLoginPhone, '+359888123456');
      expect(controller.role, UserRole.volunteer);
      expect(find.text('Пунктове за събиране'), findsOneWidget);
    });

    testWidgets('shows a safe error when the volunteer is unknown', (
      tester,
    ) async {
      final api =
          FakeAuthApi()
            ..volunteerLoginError = buildError(401, 'INVALID_CREDENTIALS');
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const VolunteerIdentificationScreen(),
      );

      await tester.enterText(find.byType(TextFormField).at(0), 'Ана');
      await tester.enterText(find.byType(TextFormField).at(1), 'Тестова');
      await tester.enterText(find.byType(TextFormField).at(2), '0888123456');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Влез'));
      await tester.pump();

      expect(find.text('Грешно име, фамилия или телефон.'), findsOneWidget);
    });

    testWidgets('opens registration from the volunteer login', (tester) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const VolunteerIdentificationScreen(),
      );

      await tester.tap(
        find.widgetWithText(TextButton, 'Нямате профил? Регистрирайте се'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RegistrationScreen), findsOneWidget);
    });
  });

  group('ChangePasswordScreen', () {
    Future<SessionController> signedInController({
      bool mandatory = true,
    }) async {
      final api =
          FakeAuthApi()
            ..loginResponse = buildSession(mustChangePassword: mandatory);
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');
      return controller;
    }

    testWidgets('validates the new password rules', (tester) async {
      final controller = await signedInController();
      await pumpInScope(tester, controller, const ChangePasswordScreen());

      await tester.tap(find.widgetWithText(ElevatedButton, 'Смени паролата'));
      await tester.pump();
      expect(find.text('Въведете текущата парола.'), findsOneWidget);
      expect(find.text('Паролата трябва да е поне 8 символа.'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(0), 'OldPass123!');
      await tester.enterText(find.byType(TextFormField).at(1), 'OldPass123!');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Смени паролата'));
      await tester.pump();
      expect(
        find.text('Новата парола трябва да е различна от текущата.'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextFormField).at(1), 'NewPass456!');
      await tester.enterText(find.byType(TextFormField).at(2), 'Mismatch456!');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Смени паролата'));
      await tester.pump();
      expect(find.text('Паролите не съвпадат.'), findsOneWidget);
    });

    testWidgets('changes the password and proceeds to the shell', (
      tester,
    ) async {
      final controller = await signedInController();
      await pumpInScope(tester, controller, const ChangePasswordScreen());

      await tester.enterText(find.byType(TextFormField).at(0), 'OldPass123!');
      await tester.enterText(find.byType(TextFormField).at(1), 'NewPass456!');
      await tester.enterText(find.byType(TextFormField).at(2), 'NewPass456!');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Смени паролата'));
      await tester.pumpAndSettle();

      expect(controller.mustChangePassword, isFalse);
      expect(find.text('Пунктове за събиране'), findsOneWidget);
    });

    testWidgets('stays put when the backend still requires a change', (
      tester,
    ) async {
      final api =
          FakeAuthApi()
            ..changeResponse = buildSession(
              token: 'changed',
              mustChangePassword: true,
            );
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await pumpInScope(tester, controller, const ChangePasswordScreen());
      await tester.enterText(find.byType(TextFormField).at(0), 'OldPass123!');
      await tester.enterText(find.byType(TextFormField).at(1), 'NewPass456!');
      await tester.enterText(find.byType(TextFormField).at(2), 'NewPass456!');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Смени паролата'));
      await tester.pump();

      expect(find.byType(ChangePasswordScreen), findsOneWidget);
      expect(
        find.text(
          'Паролата е сменена, но профилът все още изисква нова парола.',
        ),
        findsOneWidget,
      );
    });
    testWidgets('returns to the start screen when the session expired', (
      tester,
    ) async {
      final api = FakeAuthApi()..changeError = buildError(401, 'UNAUTHORIZED');
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await pumpInScope(tester, controller, const ChangePasswordScreen());
      await tester.enterText(find.byType(TextFormField).at(0), 'OldPass123!');
      await tester.enterText(find.byType(TextFormField).at(1), 'NewPass456!');
      await tester.enterText(find.byType(TextFormField).at(2), 'NewPass456!');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Смени паролата'));
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isFalse);
      expect(find.byType(StartScreen), findsOneWidget);
    });
  });

  group('AppShell', () {
    testWidgets('shows the authenticated role badge', (tester) async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await pumpInScope(tester, controller, const AppShell());

      expect(find.text('Администратор'), findsOneWidget);
    });

    testWidgets('shows a demo badge without a session', (tester) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const AppShell(),
      );

      expect(find.text('Демо'), findsOneWidget);
    });

    testWidgets('logs out and returns to the start screen', (tester) async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await pumpInScope(tester, controller, const AppShell());
      await tester.tap(find.byTooltip('Изход'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Изход'));
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isFalse);
      expect(find.byType(StartScreen), findsOneWidget);
    });
  });

  group('StartScreen', () {
    testWidgets('the registration entry opens volunteer registration', (
      tester,
    ) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const StartScreen(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Регистрация'));
      await tester.pumpAndSettle();

      expect(find.byType(RegistrationScreen), findsOneWidget);
    });

    testWidgets('the login entry opens volunteer login', (tester) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const StartScreen(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pumpAndSettle();

      expect(find.byType(VolunteerIdentificationScreen), findsOneWidget);
    });

    testWidgets('the staff entry opens staff login', (tester) async {
      final api = FakeAuthApi();
      await pumpInScope(
        tester,
        SessionController(authApi: api),
        const StartScreen(),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Служебен вход'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Служебен вход'), findsWidgets);
    });

    testWidgets('shows a safe notice for an expired session', (tester) async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');
      controller.handleUnauthorized();

      await pumpInScope(tester, controller, const StartScreen());

      expect(find.text('Сесията изтече. Влезте отново.'), findsOneWidget);
    });

    testWidgets('blocks the shell while a password change is pending', (
      tester,
    ) async {
      final api =
          FakeAuthApi()..loginResponse = buildSession(mustChangePassword: true);
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await pumpInScope(tester, controller, const StartScreen());
      await tester.tap(find.text('Разгледай демо съдържанието'));
      await tester.pumpAndSettle();

      expect(find.byType(ChangePasswordScreen), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
    });

    testWidgets('offers to continue when a session exists', (tester) async {
      final api = FakeAuthApi();
      final controller = SessionController(authApi: api);
      await controller.signInStaff(phone: '+359881000001', password: 'secret');

      await pumpInScope(tester, controller, const StartScreen());

      expect(find.widgetWithText(ElevatedButton, 'Продължи'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Продължи'));
      await tester.pumpAndSettle();
      expect(find.text('Пунктове за събиране'), findsOneWidget);
    });
  });
}
