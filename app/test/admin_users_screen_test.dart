import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/models/admin_user_page.dart';
import 'package:kupi_i_dari/models/app_user.dart';
import 'package:kupi_i_dari/screens/admin_users_screen.dart';
import 'package:kupi_i_dari/widgets/app_shell.dart';
import 'package:kupi_i_dari/widgets/primary_button.dart';

import 'fakes.dart';

void setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

AppUser user(
  int id, {
  UserRole role = UserRole.responsible,
  bool isActive = true,
  bool mustChangePassword = false,
  String? firstName,
  String? lastName,
}) {
  return AppUser(
    id: id,
    phone: '+35988${id.toString().padLeft(7, '0')}',
    firstName: firstName ?? 'Име$id',
    lastName: lastName ?? 'Фамилия$id',
    role: role,
    isActive: isActive,
    mustChangePassword: mustChangePassword,
  );
}

AdminUserPage page(
  List<AppUser> users, {
  int pageNumber = 1,
  int pageSize = 20,
  int? total,
}) {
  final effectiveTotal = total ?? users.length;
  return AdminUserPage(
    users: List<AppUser>.unmodifiable(users),
    page: pageNumber,
    pageSize: pageSize,
    total: effectiveTotal,
    totalPages:
        effectiveTotal == 0 ? 0 : (effectiveTotal + pageSize - 1) ~/ pageSize,
  );
}

Future<SessionController> sessionFor(UserRole role) async {
  final authApi = FakeAuthApi();
  if (role == UserRole.volunteer) {
    final controller = SessionController(authApi: authApi);
    addTearDown(controller.dispose);
    await controller.identifyVolunteer(
      firstName: 'Иван',
      lastName: 'Петров',
      phone: '0888123456',
    );
    return controller;
  }

  if (role == UserRole.responsible) {
    authApi.loginResponse = buildSession(role: UserRole.responsible);
  }
  final controller = SessionController(authApi: authApi);
  addTearDown(controller.dispose);
  await controller.signInStaff(phone: '0888123456', password: 'secret123');
  return controller;
}

SessionController anonymousSession() {
  final controller = SessionController(authApi: FakeAuthApi());
  addTearDown(controller.dispose);
  return controller;
}

Widget scopeWith({
  required SessionController session,
  required FakeAdminUsersApi api,
  required Widget child,
}) {
  return SessionScope(
    controller: session,
    child: ApiScope(
      locationsApi: FakeLocationsApi(),
      shiftsApi: FakeShiftsApi(),
      productsApi: FakeProductsApi(),
      entryApi: FakeEntryApi(),
      adminUsersApi: api,
      child: MaterialApp(home: child),
    ),
  );
}

Future<void> pumpScreen(
  WidgetTester tester, {
  required SessionController session,
  required FakeAdminUsersApi api,
  bool shell = false,
  bool settle = true,
}) async {
  setLargeSurface(tester);
  await tester.pumpWidget(
    scopeWith(
      session: session,
      api: api,
      child: shell ? const AppShell() : AdminUsersScreen(adminUsersApi: api),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Future<void> fillCreateForm(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('admin-user-first-name-field')),
    'Нов',
  );
  await tester.enterText(
    find.byKey(const Key('admin-user-last-name-field')),
    'Служител',
  );
  await tester.enterText(
    find.byKey(const Key('admin-user-phone-field')),
    '0888123456',
  );
  await tester.enterText(
    find.byKey(const Key('admin-user-password-field')),
    'secret123',
  );
  await tester.enterText(
    find.byKey(const Key('admin-user-confirm-password-field')),
    'secret123',
  );
  await tester.pump();
}

void main() {
  group('AdminUsersScreen access and list', () {
    testWidgets('renders the safe list and requests all users on page 1', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin), user(2)]));
      final session = await sessionFor(UserRole.admin);

      await pumpScreen(tester, session: session, api: api);

      expect(api.listCalls, 1);
      expect(api.listRequests.single.role, isNull);
      expect(api.listRequests.single.isActive, isNull);
      expect(api.listRequests.single.page, 1);
      expect(api.listRequests.single.pageSize, 20);
      expect(find.byKey(const Key('admin-user-card-1')), findsOneWidget);
      expect(find.byKey(const Key('admin-user-card-2')), findsOneWidget);
      expect(find.text('Общо потребители: 2'), findsOneWidget);
      expect(find.text('Страница 1 от 1'), findsOneWidget);
      expect(find.text('Това сте вие'), findsOneWidget);
      expect(find.text('Трябва смяна на парола'), findsNothing);
    });

    testWidgets('shows forced password change and status details', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(
              page([
                user(1, role: UserRole.admin, mustChangePassword: true),
                user(2, isActive: false),
              ]),
            );
      final session = await sessionFor(UserRole.admin);

      await pumpScreen(tester, session: session, api: api);

      expect(find.text('Трябва смяна на парола'), findsOneWidget);
      expect(find.text('Деактивиран'), findsOneWidget);
      expect(find.text('Активен'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('admin-user-card-2')),
          matching: find.text('Отговорник'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('admin-user-card-1')),
          matching: find.text('Администратор'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('non-admin and anonymous users see a forbidden state', (
      tester,
    ) async {
      final responsibleApi = FakeAdminUsersApi();
      final responsible = await sessionFor(UserRole.responsible);
      await pumpScreen(tester, session: responsible, api: responsibleApi);
      expect(find.byKey(const Key('admin-users-forbidden')), findsOneWidget);
      expect(
        find.text('Нямате права да извършите това действие.'),
        findsOneWidget,
      );
      expect(responsibleApi.listCalls, 0);

      final anonymousApi = FakeAdminUsersApi();
      await pumpScreen(tester, session: anonymousSession(), api: anonymousApi);
      expect(find.byKey(const Key('admin-users-forbidden')), findsOneWidget);
      expect(anonymousApi.listCalls, 0);
    });

    testWidgets('admin tab is only present in the admin shell', (tester) async {
      final adminApi = FakeAdminUsersApi()..listResults.add(page([user(1)]));
      final admin = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: admin, api: adminApi, shell: true);

      expect(find.byKey(const Key('app-tab-2')), findsOneWidget);
      expect(find.text('Потребители'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-tab-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('admin-users-total')), findsOneWidget);

      final responsibleApi = FakeAdminUsersApi();
      final responsible = await sessionFor(UserRole.responsible);
      await pumpScreen(
        tester,
        session: responsible,
        api: responsibleApi,
        shell: true,
      );
      expect(find.byKey(const Key('app-tab-2')), findsNothing);
      expect(find.byType(AdminUsersScreen), findsNothing);
      expect(responsibleApi.listCalls, 0);
    });

    testWidgets('filters reset to page 1 and are sent to the backend', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin), user(2)]));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-users-role-responsible')));
      await tester.pumpAndSettle();
      expect(api.lastListRole, UserRole.responsible);
      expect(api.lastListPage, 1);

      await tester.tap(find.byKey(const Key('admin-users-active-false')));
      await tester.pumpAndSettle();
      expect(api.lastListIsActive, isFalse);
      expect(api.lastListPage, 1);
    });

    testWidgets('pagination moves to the next and previous page', (
      tester,
    ) async {
      final firstPage = <AppUser>[
        for (var id = 1; id <= 20; id++)
          user(id, role: id == 1 ? UserRole.admin : UserRole.responsible),
      ];
      final api =
          FakeAdminUsersApi()..listResults.add(page(firstPage, total: 21));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      api.listPageResponse = page([user(21)], pageNumber: 2, total: 21);
      await tester.tap(find.byKey(const Key('admin-users-next')));
      await tester.pumpAndSettle();
      expect(api.lastListPage, 2);
      expect(find.byKey(const Key('admin-user-card-21')), findsOneWidget);
      expect(find.text('Страница 2 от 2'), findsOneWidget);

      api.listPageResponse = page(firstPage, total: 21);
      await tester.tap(find.byKey(const Key('admin-users-prev')));
      await tester.pumpAndSettle();
      expect(api.lastListPage, 1);
      expect(find.byKey(const Key('admin-user-card-1')), findsOneWidget);
    });

    testWidgets('an out-of-range page is clamped back to page 1', (
      tester,
    ) async {
      final firstPage = <AppUser>[for (var id = 1; id <= 20; id++) user(id)];
      final api =
          FakeAdminUsersApi()..listResults.add(page(firstPage, total: 21));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      api.listPageResponse = page(const [], total: 0);
      await tester.tap(find.byKey(const Key('admin-users-next')));
      await tester.pumpAndSettle();

      expect(api.listRequests.last.page, 1);
      expect(find.byKey(const Key('admin-users-empty')), findsOneWidget);
      expect(find.text('Няма намерени потребители.'), findsOneWidget);
    });

    testWidgets('a stale list response cannot overwrite a newer filter', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      final staleGate = api.setListPending();
      final freshGate = api.setListPending();
      api.listResults.addAll([
        page([user(8, firstName: 'Stale')]),
        page([user(9, firstName: 'Fresh')]),
      ]);

      await tester.tap(find.byKey(const Key('admin-users-role-responsible')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('admin-users-active-true')));
      await tester.pump();

      freshGate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Fresh'), findsOneWidget);
      expect(find.textContaining('Stale'), findsNothing);

      staleGate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Fresh'), findsOneWidget);
      expect(find.textContaining('Stale'), findsNothing);
    });

    testWidgets('a 401 clears the session centrally', (tester) async {
      final api =
          FakeAdminUsersApi()
            ..listError = const ApiException(
              code: 'UNAUTHORIZED',
              statusCode: 401,
              message: 'expired',
            );
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      expect(session.isAuthenticated, isFalse);
      expect(session.notice, 'Сесията изтече. Влезте отново.');
      expect(find.byKey(const Key('admin-users-forbidden')), findsOneWidget);
    });

    testWidgets('shows a retryable error and recovers', (tester) async {
      final api =
          FakeAdminUsersApi()
            ..listError = const ApiException(
              code: 'NETWORK_ERROR',
              message: 'offline',
            );
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      expect(find.byKey(const Key('admin-users-error')), findsOneWidget);
      expect(
        find.text('Няма връзка със сървъра. Проверете интернет връзката.'),
        findsOneWidget,
      );
      expect(api.listCalls, 1);

      api.listError = null;
      api.listPageResponse = page([user(1, role: UserRole.admin)]);
      await tester.tap(find.byKey(const Key('admin-users-retry')));
      await tester.pumpAndSettle();

      expect(api.listCalls, 2);
      expect(find.byKey(const Key('admin-user-card-1')), findsOneWidget);
    });

    testWidgets('shows an empty state with a create action', (tester) async {
      final api = FakeAdminUsersApi()..listResults.add(page(const []));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      expect(find.byKey(const Key('admin-users-empty')), findsOneWidget);
      expect(find.text('Няма намерени потребители.'), findsOneWidget);
      expect(find.byKey(const Key('admin-users-empty-create')), findsOneWidget);
    });
  });

  group('AdminUsersScreen create', () {
    testWidgets('creates staff once, shows the last page and reports success', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      api.createResponse = user(
        9,
        firstName: 'Нов',
        lastName: 'Служител',
        mustChangePassword: true,
      );
      final createGate = api.setCreatePending();
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-user-create-button')));
      await tester.pumpAndSettle();
      expect(find.text('Нов служител'), findsOneWidget);
      await fillCreateForm(tester);

      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pump();
      expect(api.createCalls, 1);
      final saveButton = tester.widget<PrimaryButton>(
        find.byKey(const Key('admin-user-save-button')),
      );
      expect(saveButton.busy, isTrue);
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pump();
      expect(api.createCalls, 1);

      api.listResults.addAll([
        page([user(1, role: UserRole.admin)], total: 21),
        page(
          [user(9, firstName: 'Нов', lastName: 'Служител')],
          pageNumber: 2,
          total: 21,
        ),
      ]);
      createGate.complete();
      await tester.pumpAndSettle();

      expect(api.createCalls, 1);
      expect(api.lastCreateFirstName, 'Нов');
      expect(api.lastCreateLastName, 'Служител');
      expect(api.lastCreatePhone, '+359888123456');
      expect(api.lastCreateRole, UserRole.responsible);
      expect(api.lastCreatePassword, 'secret123');
      expect(api.lastListPage, 2);
      expect(find.text('Потребителят е създаден успешно.'), findsOneWidget);
      expect(find.byKey(const Key('admin-user-card-9')), findsOneWidget);
    });

    testWidgets('keeps the editor open and maps PHONE_TAKEN', (tester) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      api.createError = const ApiException(
        code: 'PHONE_TAKEN',
        statusCode: 409,
        message: 'taken',
      );
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-user-create-button')));
      await tester.pumpAndSettle();
      await fillCreateForm(tester);
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pumpAndSettle();

      expect(api.createCalls, 1);
      expect(find.text('Телефонният номер вече се използва.'), findsOneWidget);
      expect(find.text('Нов служител'), findsOneWidget);
      expect(api.listCalls, 1);
    });

    testWidgets('validates names, phone, password length and confirmation', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-user-create-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pump();
      expect(find.text('Въведете име.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('admin-user-first-name-field')),
        List.filled(61, 'А').join(),
      );
      await tester.pump();
      final firstNameEditor = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('admin-user-first-name-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(firstNameEditor.controller.text.length, 60);

      await tester.enterText(
        find.byKey(const Key('admin-user-first-name-field')),
        'Нов',
      );
      await tester.enterText(
        find.byKey(const Key('admin-user-last-name-field')),
        'Служител',
      );
      await tester.enterText(
        find.byKey(const Key('admin-user-phone-field')),
        '123',
      );
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pump();
      expect(find.text('Въведете валиден телефонен номер.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('admin-user-phone-field')),
        '0888123456',
      );
      await tester.enterText(
        find.byKey(const Key('admin-user-password-field')),
        'short',
      );
      await tester.enterText(
        find.byKey(const Key('admin-user-confirm-password-field')),
        'short',
      );
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pump();
      expect(find.text('Паролата трябва да е поне 8 символа.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('admin-user-password-field')),
        'secret123',
      );
      await tester.enterText(
        find.byKey(const Key('admin-user-confirm-password-field')),
        'secret124',
      );
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pump();
      expect(find.text('Паролите не съвпадат.'), findsOneWidget);
      expect(api.createCalls, 0);
    });

    testWidgets('keeps a matching role filter after creation', (tester) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      api.listPageResponse = page([user(2)]);
      await tester.tap(find.byKey(const Key('admin-users-role-responsible')));
      await tester.pumpAndSettle();
      expect(api.lastListRole, UserRole.responsible);

      api.createResponse = user(9);
      api.listPageResponse = page([user(2), user(9)]);
      await tester.tap(find.byKey(const Key('admin-user-create-button')));
      await tester.pumpAndSettle();
      await fillCreateForm(tester);
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pumpAndSettle();

      expect(api.lastListRole, UserRole.responsible);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const Key('admin-users-role-responsible')),
            )
            .selected,
        isTrue,
      );
      expect(find.byKey(const Key('admin-user-card-9')), findsOneWidget);
    });

    testWidgets('resets filters when the created user does not match', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      api.listPageResponse = page([user(1, role: UserRole.admin)]);
      await tester.tap(find.byKey(const Key('admin-users-role-admin')));
      await tester.pumpAndSettle();
      expect(api.lastListRole, UserRole.admin);

      api.createResponse = user(9);
      api.listPageResponse = page([user(1, role: UserRole.admin), user(9)]);
      await tester.tap(find.byKey(const Key('admin-user-create-button')));
      await tester.pumpAndSettle();
      await fillCreateForm(tester);
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pumpAndSettle();

      expect(api.lastListRole, isNull);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('admin-users-role-all')))
            .selected,
        isTrue,
      );
      expect(find.byKey(const Key('admin-user-card-9')), findsOneWidget);
    });
  });

  group('AdminUsersScreen edit and status', () {
    testWidgets('edits the profile in place without an extra list request', (
      tester,
    ) async {
      final api = FakeAdminUsersApi()..listResults.add(page([user(2)]));
      api.updateResponse = user(
        2,
        firstName: 'Обновен',
        lastName: 'Профил',
        mustChangePassword: true,
      );
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-user-menu-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-user-edit-2')));
      await tester.pumpAndSettle();

      expect(find.text('Редактиране на потребител'), findsOneWidget);
      expect(find.byKey(const Key('admin-user-role-readonly')), findsOneWidget);
      expect(find.byKey(const Key('admin-user-password-field')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('admin-user-first-name-field')),
        'Обновен',
      );
      await tester.enterText(
        find.byKey(const Key('admin-user-last-name-field')),
        'Профил',
      );
      await tester.enterText(
        find.byKey(const Key('admin-user-phone-field')),
        '0888999999',
      );
      await tester.tap(find.byKey(const Key('admin-user-save-button')));
      await tester.pumpAndSettle();

      expect(api.updateCalls, 1);
      expect(api.lastUpdateUserId, 2);
      expect(api.lastUpdateFirstName, 'Обновен');
      expect(api.lastUpdateLastName, 'Профил');
      expect(api.lastUpdatePhone, '+359888999999');
      expect(api.listCalls, 1);
      expect(find.text('Обновен Профил'), findsOneWidget);
      expect(find.text('Потребителят е обновен успешно.'), findsOneWidget);
    });

    testWidgets(
      'deactivation requires confirmation and removes a filtered row',
      (tester) async {
        final api =
            FakeAdminUsersApi()
              ..listResults.add(page([user(1, role: UserRole.admin), user(2)]));
        api.setStatusResponse = user(2, isActive: false);
        final session = await sessionFor(UserRole.admin);
        await pumpScreen(tester, session: session, api: api);

        api.listPageResponse = page([user(1, role: UserRole.admin), user(2)]);
        await tester.tap(find.byKey(const Key('admin-users-active-true')));
        await tester.pumpAndSettle();
        expect(api.lastListIsActive, isTrue);

        await tester.tap(find.byKey(const Key('admin-user-menu-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-user-deactivate-2')));
        await tester.pumpAndSettle();
        expect(
          find.text('Сигурни ли сте, че искате да деактивирате Име2 Фамилия2?'),
          findsOneWidget,
        );
        await tester.tap(find.text('Отказ'));
        await tester.pumpAndSettle();
        expect(api.setStatusCalls, 0);
        expect(find.byKey(const Key('admin-user-card-2')), findsOneWidget);

        await tester.tap(find.byKey(const Key('admin-user-menu-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-user-deactivate-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Деактивирай'));
        await tester.pumpAndSettle();

        expect(api.setStatusCalls, 1);
        expect(api.lastSetStatusUserId, 2);
        expect(api.lastSetStatusValue, isFalse);
        expect(find.byKey(const Key('admin-user-card-2')), findsNothing);
        expect(find.text('Общо потребители: 1'), findsOneWidget);
        expect(find.text('Потребителят е деактивиран.'), findsOneWidget);
      },
    );

    testWidgets(
      'deactivating the last row on a page reloads the previous page',
      (tester) async {
        final firstPage = <AppUser>[for (var id = 1; id <= 20; id++) user(id)];
        final api =
            FakeAdminUsersApi()..listResults.add(page(firstPage, total: 21));
        api.setStatusResponse = user(21, isActive: false);
        final session = await sessionFor(UserRole.admin);
        await pumpScreen(tester, session: session, api: api);

        api.listPageResponse = page(firstPage, total: 21);
        await tester.tap(find.byKey(const Key('admin-users-active-true')));
        await tester.pumpAndSettle();
        api.listPageResponse = page([user(21)], pageNumber: 2, total: 21);
        await tester.tap(find.byKey(const Key('admin-users-next')));
        await tester.pumpAndSettle();
        expect(api.lastListPage, 2);

        api.listPageResponse = page(firstPage, total: 20);
        await tester.tap(find.byKey(const Key('admin-user-menu-21')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-user-deactivate-21')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Деактивирай'));
        await tester.pumpAndSettle();

        expect(api.lastListPage, 1);
        expect(find.byKey(const Key('admin-user-card-21')), findsNothing);
        expect(find.text('Страница 1 от 1'), findsOneWidget);
      },
    );

    testWidgets('maps SELF_DEACTIVATION and leaves the row unchanged', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      api.setStatusError = const ApiException(
        code: 'SELF_DEACTIVATION',
        statusCode: 409,
        message: 'self',
      );
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-user-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-user-deactivate-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Деактивирай'));
      await tester.pumpAndSettle();

      expect(
        find.text('Не можете да деактивирате собствения си профил.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin-user-card-1')), findsOneWidget);
      expect(find.text('Активен'), findsOneWidget);
    });

    testWidgets('maps LAST_ADMIN and leaves the admin active', (tester) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(1, role: UserRole.admin)]));
      api.setStatusError = const ApiException(
        code: 'LAST_ADMIN',
        statusCode: 409,
        message: 'last',
      );
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-user-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-user-deactivate-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Деактивирай'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Последният активен администратор не може да бъде деактивиран.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin-user-card-1')), findsOneWidget);
      expect(find.text('Активен'), findsOneWidget);
    });

    testWidgets('activation sends true and keeps the row when filters match', (
      tester,
    ) async {
      final api =
          FakeAdminUsersApi()
            ..listResults.add(page([user(2, isActive: false)]));
      api.setStatusResponse = user(2, isActive: true);
      final session = await sessionFor(UserRole.admin);
      await pumpScreen(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('admin-user-menu-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-user-activate-2')));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 1);
      expect(api.lastSetStatusValue, isTrue);
      expect(find.byKey(const Key('admin-user-card-2')), findsOneWidget);
      expect(find.text('Потребителят е активиран.'), findsOneWidget);
      expect(find.text('Активен'), findsOneWidget);
    });
  });
}
