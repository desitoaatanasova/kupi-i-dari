import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/models/location.dart';
import 'package:kupi_i_dari/screens/locations_screen.dart';
import 'package:kupi_i_dari/screens/shifts_screen.dart';
import 'package:kupi_i_dari/widgets/location_card.dart';

import 'fakes.dart';

const _apiLocations = [
  Location(
    id: 1,
    name: 'Площад „Светлина“',
    address: 'ул. Централна 12, София',
  ),
  Location(
    id: 2,
    name: 'Квартален пункт „Младост“',
    address: 'бул. Александър Малинов 45, София',
  ),
  Location(
    id: 3,
    name: 'Пункт „Тракия“',
    address: 'ул. Христо Ботев 8, Пловдив',
  ),
  Location(id: 4, name: 'Пункт „Северен“', address: 'ул. Дунав 3, Варна'),
  Location(
    id: 5,
    name: 'Пункт „Централен пазар“',
    address: 'ул. Княз Александър 20, Бургас',
    isActive: false,
  ),
];

Future<void> _pumpLocations(WidgetTester tester, FakeLocationsApi api) async {
  await tester.pumpWidget(
    ApiScope(
      locationsApi: api,
      shiftsApi: FakeShiftsApi(),
      productsApi: FakeProductsApi(),
      entryApi: FakeEntryApi(),
      adminUsersApi: FakeAdminUsersApi(),
      child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pulls the refreshable list down far enough to trigger its
/// [RefreshIndicator]. The scrollable is captured before the refresh starts,
/// because the loading state temporarily replaces the indicator.
Future<void> _pullToRefresh(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsOneWidget);
  await tester.fling(scrollable, const Offset(0, 300), 1000);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('LocationsScreen', () {
    testWidgets('shows loading indicator while request is pending', (
      tester,
    ) async {
      final api = FakeLocationsApi();
      api.setPending();
      await tester.pumpWidget(
        ApiScope(
          locationsApi: api,
          shiftsApi: FakeShiftsApi(),
          productsApi: FakeProductsApi(),
          entryApi: FakeEntryApi(),
          adminUsersApi: FakeAdminUsersApi(),
          child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      api.listGate!.complete();
      await tester.pump();
    });

    testWidgets('renders API-provided locations (not sample data)', (
      tester,
    ) async {
      final api = FakeLocationsApi();
      api.listResponse = _apiLocations;
      await tester.pumpWidget(
        ApiScope(
          locationsApi: api,
          shiftsApi: FakeShiftsApi(),
          productsApi: FakeProductsApi(),
          entryApi: FakeEntryApi(),
          adminUsersApi: FakeAdminUsersApi(),
          child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Площад „Светлина“'), findsOneWidget);
      expect(find.text('Квартален пункт „Младост“'), findsOneWidget);
      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Пункт „Северен“'), findsOneWidget);
      expect(find.text('Пункт „Централен пазар“'), findsNothing);
      expect(find.byType(LocationCard), findsNWidgets(4));
    });

    testWidgets('does not show management controls to anonymous users', (
      tester,
    ) async {
      final api = FakeLocationsApi();
      api.listResponse = _apiLocations;
      await _pumpLocations(tester, api);

      expect(find.byKey(const Key('location-create-button')), findsNothing);
      expect(find.byKey(const Key('location-admin-menu-1')), findsNothing);
      expect(find.text('Нов пункт'), findsNothing);
      expect(find.byType(LocationCard), findsNWidgets(4));
    });

    testWidgets('shows empty server response message', (tester) async {
      final api = FakeLocationsApi();
      api.listResponse = const [];
      await tester.pumpWidget(
        ApiScope(
          locationsApi: api,
          shiftsApi: FakeShiftsApi(),
          productsApi: FakeProductsApi(),
          entryApi: FakeEntryApi(),
          adminUsersApi: FakeAdminUsersApi(),
          child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Няма регистрирани пунктове.'), findsOneWidget);
    });

    testWidgets('shows error message with retry and retries on tap', (
      tester,
    ) async {
      final api = FakeLocationsApi();
      api.listResponse = [_apiLocations[2]];
      api.listError = const ApiException(
        code: 'NETWORK_ERROR',
        message: 'network error',
      );
      await tester.pumpWidget(
        ApiScope(
          locationsApi: api,
          shiftsApi: FakeShiftsApi(),
          productsApi: FakeProductsApi(),
          entryApi: FakeEntryApi(),
          adminUsersApi: FakeAdminUsersApi(),
          child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Няма връзка със сървъра. Проверете интернет връзката.'),
        findsOneWidget,
      );
      expect(find.text('Повтори'), findsOneWidget);
      expect(api.listCalls, 1);

      api.listError = null;
      await tester.tap(find.text('Повтори'));
      await tester.pumpAndSettle();

      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Повтори'), findsNothing);
      expect(api.listCalls, 2);
    });

    testWidgets('local search filters API-provided locations and clears', (
      tester,
    ) async {
      final api = FakeLocationsApi();
      api.listResponse = _apiLocations;
      await tester.pumpWidget(
        ApiScope(
          locationsApi: api,
          shiftsApi: FakeShiftsApi(),
          productsApi: FakeProductsApi(),
          entryApi: FakeEntryApi(),
          adminUsersApi: FakeAdminUsersApi(),
          child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Пловдив');
      await tester.pump();
      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Площад „Светлина“'), findsNothing);

      await tester.tap(find.byTooltip('Изчисти търсенето'));
      await tester.pump();
      expect(find.text('Площад „Светлина“'), findsOneWidget);
      expect(find.text('Пункт „Тракия“'), findsOneWidget);
    });

    testWidgets('clears session on unauthorized error and shows message', (
      tester,
    ) async {
      final api = FakeLocationsApi();
      final sessionApi = FakeAuthApi();
      final controller = SessionController(authApi: sessionApi);
      controller.signInStaff(phone: '+359881000001', password: 'pw');
      api.listError = const ApiException(
        code: 'UNAUTHORIZED',
        statusCode: 401,
        message: 'expired',
      );

      await tester.pumpWidget(
        SessionScope(
          controller: controller,
          child: ApiScope(
            adminUsersApi: FakeAdminUsersApi(),
            locationsApi: api,
            shiftsApi: FakeShiftsApi(),
            productsApi: FakeProductsApi(),
            entryApi: FakeEntryApi(),
            child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.isAuthenticated, isFalse);
      expect(controller.notice, 'Сесията изтече. Влезте отново.');
      expect(find.text('Сесията изтече. Влезте отново.'), findsOneWidget);
    });

    testWidgets('shows controlled error when no API is available', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LocationsScreen())),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Възникна неочаквана грешка. Опитайте отново.'),
        findsOneWidget,
      );
      expect(find.text('Повтори'), findsOneWidget);
    });

    testWidgets(
      'taps location and opens shifts screen with selected location',
      (tester) async {
        final api = FakeLocationsApi();
        api.listResponse = _apiLocations;
        await tester.pumpWidget(
          ApiScope(
            locationsApi: api,
            shiftsApi: FakeShiftsApi(),
            productsApi: FakeProductsApi(),
            entryApi: FakeEntryApi(),
            adminUsersApi: FakeAdminUsersApi(),
            child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Пункт „Тракия“'));
        await tester.pumpAndSettle();

        expect(find.text('Смени за Пункт „Тракия“'), findsOneWidget);
        expect(find.byType(ShiftsScreen), findsOneWidget);
      },
    );

    testWidgets('passes token from session when available', (tester) async {
      final api = FakeLocationsApi();
      final sessionApi = FakeAuthApi();
      final controller = SessionController(authApi: sessionApi);
      await controller.signInStaff(phone: '+359881000001', password: 'pw');

      await tester.pumpWidget(
        SessionScope(
          controller: controller,
          child: ApiScope(
            adminUsersApi: FakeAdminUsersApi(),
            locationsApi: api,
            shiftsApi: FakeShiftsApi(),
            productsApi: FakeProductsApi(),
            entryApi: FakeEntryApi(),
            child: const MaterialApp(home: Scaffold(body: LocationsScreen())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(api.lastToken, 'token-123');
      expect(api.listCalls, 1);
    });
  });

  group('LocationsScreen pull-to-refresh', () {
    testWidgets('triggers a fresh locations load', (tester) async {
      final api = FakeLocationsApi();
      api.listResponse = _apiLocations;
      await _pumpLocations(tester, api);
      expect(api.listCalls, 1);
      expect(find.text('Площад „Светлина“'), findsOneWidget);

      final gate = api.setPending();
      await _pullToRefresh(tester);
      expect(api.listCalls, 2);

      api.listResponse = [_apiLocations[2]];
      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Площад „Светлина“'), findsNothing);
    });

    testWidgets('preserves the search text and filtering', (tester) async {
      final api = FakeLocationsApi();
      api.listResponse = _apiLocations;
      await _pumpLocations(tester, api);

      await tester.enterText(find.byType(TextField).first, 'Пловдив');
      await tester.pump();
      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Площад „Светлина“'), findsNothing);

      final gate = api.setPending();
      await _pullToRefresh(tester);
      expect(api.listCalls, 2);

      gate.complete();
      await tester.pumpAndSettle();

      final searchField = tester.widget<TextField>(
        find.byType(TextField).first,
      );
      expect(searchField.controller?.text, 'Пловдив');
      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Площад „Светлина“'), findsNothing);
      expect(find.byType(LocationCard), findsOneWidget);
    });

    testWidgets('works from the empty state', (tester) async {
      final api = FakeLocationsApi();
      api.listResponse = [];
      await _pumpLocations(tester, api);
      expect(find.text('Няма регистрирани пунктове.'), findsOneWidget);
      expect(api.listCalls, 1);

      final gate = api.setPending();
      await _pullToRefresh(tester);
      expect(api.listCalls, 2);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Няма регистрирани пунктове.'), findsOneWidget);
    });

    testWidgets('a failed refresh shows the error and retry state', (
      tester,
    ) async {
      final api = FakeLocationsApi();
      api.listResponse = _apiLocations;
      await _pumpLocations(tester, api);
      expect(find.text('Площад „Светлина“'), findsOneWidget);

      api.listError = const ApiException(
        code: 'NETWORK_ERROR',
        message: 'network error',
      );
      final gate = api.setPending();
      await _pullToRefresh(tester);
      expect(api.listCalls, 2);

      gate.complete();
      await tester.pumpAndSettle();

      expect(
        find.text('Няма връзка със сървъра. Проверете интернет връзката.'),
        findsOneWidget,
      );
      expect(find.text('Повтори'), findsOneWidget);
      // Current behavior: a failed refresh clears the previous list.
      expect(find.byType(LocationCard), findsNothing);
      expect(find.text('Площад „Светлина“'), findsNothing);
    });
  });
}
