import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/models/app_user.dart';
import 'package:kupi_i_dari/models/location.dart';
import 'package:kupi_i_dari/screens/locations_screen.dart';
import 'package:kupi_i_dari/screens/shifts_screen.dart';
import 'package:kupi_i_dari/widgets/location_card.dart';

import 'fakes.dart';

const _locationOne = Location(
  id: 1,
  name: 'Площад „Светлина“',
  address: 'ул. Централна 12, София',
);

const _locationTwo = Location(
  id: 2,
  name: 'Квартален пункт „Младост“',
  address: 'бул. Александър Малинов 45, София',
);

void setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<SessionController> adminSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.signInStaff(phone: '0888123456', password: 'secret123');
  return controller;
}

Future<SessionController> sessionWithRole(UserRole role) async {
  final authApi =
      FakeAuthApi()
        ..loginResponse = buildSession(role: role, token: 'role-token');
  final controller = SessionController(authApi: authApi);
  await controller.signInStaff(phone: '0888123456', password: 'secret123');
  return controller;
}

Widget wrap({
  required SessionController session,
  required FakeLocationsApi api,
  FakeShiftsApi? shiftsApi,
}) {
  return SessionScope(
    controller: session,
    child: ApiScope(
      adminUsersApi: FakeAdminUsersApi(),
      locationsApi: api,
      shiftsApi: shiftsApi ?? FakeShiftsApi(),
      productsApi: FakeProductsApi(),
      entryApi: FakeEntryApi(),
      child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
    ),
  );
}

Future<void> pumpLocations(
  WidgetTester tester, {
  required SessionController session,
  required FakeLocationsApi api,
  FakeShiftsApi? shiftsApi,
}) async {
  setLargeSurface(tester);
  await tester.pumpWidget(
    wrap(session: session, api: api, shiftsApi: shiftsApi),
  );
  await tester.pumpAndSettle();
}

Future<void> openMenu(WidgetTester tester, int id) async {
  await tester.tap(find.byKey(Key('location-admin-menu-$id')));
  await tester.pumpAndSettle();
}

String fieldText(WidgetTester tester, String key) {
  final textField = tester.widget<TextField>(
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField)),
  );
  return textField.controller!.text;
}

Future<void> pullToRefresh(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsOneWidget);
  await tester.fling(scrollable, const Offset(0, 1000), 1000);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('admin location visibility', () {
    testWidgets('admin sees create and card management actions', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      expect(find.byKey(const Key('location-create-button')), findsOneWidget);
      expect(find.byKey(const Key('location-admin-menu-1')), findsOneWidget);
      expect(find.text('Нов пункт'), findsOneWidget);
    });

    testWidgets('non-admin roles see no management controls', (tester) async {
      final controllers = <SessionController>[
        SessionController(authApi: FakeAuthApi()),
        await sessionWithRole(UserRole.volunteer),
        await sessionWithRole(UserRole.responsible),
        await sessionWithRole(UserRole.unknown),
      ];

      for (final session in controllers) {
        final api = FakeLocationsApi()..listResponse = [_locationOne];
        await pumpLocations(tester, session: session, api: api);

        expect(find.byKey(const Key('location-create-button')), findsNothing);
        expect(find.byKey(const Key('location-admin-menu-1')), findsNothing);
        expect(find.text('Нов пункт'), findsNothing);
        expect(find.byType(LocationCard), findsOneWidget);
      }
    });

    testWidgets('admin create remains available in the empty state', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = const [];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      expect(
        find.byKey(const Key('location-empty-create-button')),
        findsOneWidget,
      );
    });

    testWidgets('admin create remains available in the error state', (
      tester,
    ) async {
      final api =
          FakeLocationsApi()
            ..listError = const ApiException(
              code: 'NETWORK_ERROR',
              message: 'network error',
            );
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      expect(
        find.byKey(const Key('location-error-create-button')),
        findsOneWidget,
      );
    });
  });

  group('admin location creation', () {
    testWidgets('validates required fields without calling the API', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = const [];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('location-create-button')));
      await tester.pumpAndSettle();
      expect(find.text('Нов пункт'), findsOneWidget);

      await tester.tap(find.text('Създай пункт'));
      await tester.pump();
      expect(find.text('Въведете име на пункта.'), findsOneWidget);
      expect(api.createCalls, 0);

      await tester.enterText(
        find.byKey(const Key('location-name-field')),
        'Нов пункт',
      );
      await tester.tap(find.text('Създай пункт'));
      await tester.pump();
      expect(find.text('Въведете адрес на пункта.'), findsOneWidget);
      expect(api.createCalls, 0);
    });

    testWidgets('creates with trimmed values and inserts locally', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await tester.enterText(find.byType(TextField).first, 'няма такъв');
      await tester.pump();
      expect(find.text('Няма намерени пунктове.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('location-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('location-name-field')),
        '  Нов пункт  ',
      );
      await tester.enterText(
        find.byKey(const Key('location-address-field')),
        '  ул. Нова 1  ',
      );

      api.createResponse = const Location(
        id: 9,
        name: 'Нов пункт',
        address: 'ул. Нова 1',
      );
      await tester.tap(find.text('Създай пункт'));
      await tester.pumpAndSettle();

      expect(api.createCalls, 1);
      expect(api.lastCreateName, 'Нов пункт');
      expect(api.lastCreateAddress, 'ул. Нова 1');
      expect(api.lastCreateToken, 'token-123');
      expect(api.listCalls, 1);
      expect(find.text('Нов пункт'), findsWidgets);
      expect(find.text('Площад „Светлина“'), findsOneWidget);
      expect(find.text('Няма намерени пунктове.'), findsNothing);
    });

    testWidgets('a duplicate tap does not submit a second create request', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await tester.tap(find.byKey(const Key('location-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('location-name-field')),
        'Нов пункт',
      );
      await tester.enterText(
        find.byKey(const Key('location-address-field')),
        'ул. Нова 1',
      );
      api.createResponse = const Location(
        id: 9,
        name: 'Нов пункт',
        address: 'ул. Нова 1',
      );
      final gate = api.setCreatePending();

      await tester.tap(find.text('Създай пункт'));
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(api.createCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Нов пункт'), findsWidgets);
    });

    testWidgets('a delayed list response cannot overwrite a confirmed create', (
      tester,
    ) async {
      final api =
          FakeLocationsApi()..listResponse = [_locationOne, _locationTwo];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      final listGate = api.setPending();
      await pullToRefresh(tester);
      expect(api.listCalls, 2);

      await tester.tap(find.byKey(const Key('location-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('location-name-field')),
        'Нов пункт',
      );
      await tester.enterText(
        find.byKey(const Key('location-address-field')),
        'ул. Нова 1',
      );
      api.createResponse = const Location(
        id: 9,
        name: 'Нов пункт',
        address: 'ул. Нова 1',
      );
      await tester.tap(find.text('Създай пункт'));
      await tester.pumpAndSettle();
      expect(find.text('Нов пункт'), findsWidgets);

      api.listResponse = [_locationOne, _locationTwo];
      listGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Нов пункт'), findsWidgets);
      expect(find.text('Площад „Светлина“'), findsOneWidget);
      expect(find.text('Квартален пункт „Младост“'), findsOneWidget);
    });
  });

  group('admin location editing', () {
    testWidgets('prefills and replaces the location locally', (tester) async {
      final api =
          FakeLocationsApi()..listResponse = [_locationOne, _locationTwo];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await openMenu(tester, 1);
      await tester.tap(find.text('Редактирай'));
      await tester.pumpAndSettle();

      expect(fieldText(tester, 'location-name-field'), _locationOne.name);
      expect(fieldText(tester, 'location-address-field'), _locationOne.address);

      await tester.enterText(
        find.byKey(const Key('location-name-field')),
        'Обновен пункт',
      );
      await tester.enterText(
        find.byKey(const Key('location-address-field')),
        'ул. Обновена 2',
      );
      api.updateResponse = const Location(
        id: 1,
        name: 'Обновен пункт',
        address: 'ул. Обновена 2',
      );

      await tester.tap(find.text('Запази промените'));
      await tester.pumpAndSettle();

      expect(api.updateCalls, 1);
      expect(api.lastUpdateId, 1);
      expect(api.lastUpdateName, 'Обновен пункт');
      expect(api.lastUpdateAddress, 'ул. Обновена 2');
      expect(api.lastUpdateToken, 'token-123');
      expect(api.listCalls, 1);
      expect(find.text('Обновен пункт'), findsOneWidget);
      expect(find.text(_locationOne.name), findsNothing);
    });

    testWidgets('duplicate name keeps the form and entered values', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await openMenu(tester, 1);
      await tester.tap(find.text('Редактирай'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('location-name-field')),
        'Зает пункт',
      );
      await tester.enterText(
        find.byKey(const Key('location-address-field')),
        'ул. Заета 1',
      );
      api.updateError = buildError(409, 'NAME_TAKEN');

      await tester.tap(find.text('Запази промените'));
      await tester.pumpAndSettle();

      expect(api.updateCalls, 1);
      expect(find.text('Пункт с това име вече съществува.'), findsOneWidget);
      expect(find.text('Редактиране на пункт'), findsOneWidget);
      expect(fieldText(tester, 'location-name-field'), 'Зает пункт');
      expect(fieldText(tester, 'location-address-field'), 'ул. Заета 1');
    });

    testWidgets('search is preserved after a confirmed edit', (tester) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await tester.enterText(find.byType(TextField).first, 'Площад');
      await tester.pump();
      await openMenu(tester, 1);
      await tester.tap(find.text('Редактирай'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('location-name-field')),
        'Площад „Нова светлина“',
      );
      api.updateResponse = const Location(
        id: 1,
        name: 'Площад „Нова светлина“',
        address: 'ул. Централна 12, София',
      );

      await tester.tap(find.text('Запази промените'));
      await tester.pumpAndSettle();

      final searchField = tester.widget<TextField>(
        find.byType(TextField).first,
      );
      expect(searchField.controller?.text, 'Площад');
      expect(find.text('Площад „Нова светлина“'), findsOneWidget);
    });
  });

  group('admin location archive and undo', () {
    testWidgets('cancelling the dialog makes no API call', (tester) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await openMenu(tester, 1);
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();
      expect(find.text('Архивиране на пункт'), findsOneWidget);

      await tester.tap(find.text('Отказ'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 0);
      expect(find.text(_locationOne.name), findsOneWidget);
    });

    testWidgets('archives only after confirmation and offers undo', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await tester.enterText(find.byType(TextField).first, 'Площад');
      await tester.pump();
      await openMenu(tester, 1);
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();

      api.setStatusResponse = const Location(
        id: 1,
        name: 'Площад „Светлина“',
        address: 'ул. Централна 12, София',
        isActive: false,
      );
      final gate = api.setSetStatusPending();
      await tester.tap(find.text('Архивирай'));
      await tester.pump();

      expect(api.setStatusCalls, 1);
      expect(api.lastSetStatusId, 1);
      expect(api.lastSetStatusValue, isFalse);
      expect(api.lastSetStatusToken, 'token-123');
      expect(find.text(_locationOne.name), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text(_locationOne.name), findsNothing);
      expect(find.text('Пунктът е архивиран.'), findsOneWidget);
      expect(find.text('Върни'), findsOneWidget);
      final searchField = tester.widget<TextField>(
        find.byType(TextField).first,
      );
      expect(searchField.controller?.text, 'Площад');
    });

    testWidgets('successful undo restores the confirmed location', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      api.setStatusResponse = const Location(
        id: 1,
        name: 'Площад „Светлина“',
        address: 'ул. Централна 12, София',
        isActive: false,
      );
      await openMenu(tester, 1);
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();

      api.setStatusResponse = _locationOne;
      await tester.tap(find.text('Върни'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 2);
      expect(api.lastSetStatusValue, isTrue);
      expect(find.text(_locationOne.name), findsOneWidget);
      expect(find.text('Пунктът е възстановен.'), findsOneWidget);
    });

    testWidgets('archive failure preserves the card', (tester) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      api.setStatusError = const ApiException(
        code: 'NETWORK_ERROR',
        message: 'network error',
      );
      await openMenu(tester, 1);
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 1);
      expect(find.text(_locationOne.name), findsOneWidget);
      expect(
        find.text('Няма връзка със сървъра. Проверете интернет връзката.'),
        findsOneWidget,
      );
      expect(find.text('Върни'), findsNothing);
    });

    testWidgets('undo failure leaves the location absent', (tester) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      api.setStatusResponse = const Location(
        id: 1,
        name: 'Площад „Светлина“',
        address: 'ул. Централна 12, София',
        isActive: false,
      );
      await openMenu(tester, 1);
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();

      api.setStatusError = const ApiException(
        code: 'NETWORK_ERROR',
        message: 'network error',
      );
      await tester.tap(find.text('Върни'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 2);
      expect(find.text(_locationOne.name), findsNothing);
      expect(
        find.text('Няма връзка със сървъра. Проверете интернет връзката.'),
        findsOneWidget,
      );
    });

    testWidgets('a 401 archive clears the session', (tester) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      api.setStatusError = const ApiException(
        code: 'UNAUTHORIZED',
        statusCode: 401,
        message: 'expired',
      );
      await openMenu(tester, 1);
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Архивирай'));
      await tester.pumpAndSettle();

      expect(session.isAuthenticated, isFalse);
      expect(session.notice, 'Сесията изтече. Влезте отново.');
      expect(find.text(_locationOne.name), findsOneWidget);
    });
  });

  group('existing admin list behavior', () {
    testWidgets('a card still opens the shifts screen with the menu present', (
      tester,
    ) async {
      final api = FakeLocationsApi()..listResponse = [_locationOne];
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      await tester.tap(find.text(_locationOne.name));
      await tester.pumpAndSettle();

      expect(find.byType(ShiftsScreen), findsOneWidget);
      expect(find.text('Смени за ${_locationOne.name}'), findsOneWidget);
    });

    testWidgets('a list failure uses no sample data', (tester) async {
      final api =
          FakeLocationsApi()
            ..listError = const ApiException(
              code: 'NETWORK_ERROR',
              message: 'network error',
            );
      final session = await adminSession();
      await pumpLocations(tester, session: session, api: api);

      expect(find.byType(LocationCard), findsNothing);
      expect(find.text(_locationOne.name), findsNothing);
      expect(
        find.text('Няма връзка със сървъра. Проверете интернет връзката.'),
        findsOneWidget,
      );
      expect(find.text('Повтори'), findsOneWidget);
    });
  });
}
