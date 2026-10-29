import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/api/auth_api.dart';
import 'package:kupi_i_dari/core/api/locations_api.dart';
import 'package:kupi_i_dari/core/api/shifts_api.dart';
import 'package:kupi_i_dari/core/session/auth_session.dart';
import 'package:kupi_i_dari/core/session/registration_scope.dart';
import 'package:kupi_i_dari/core/session/registration_state_controller.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/models/app_user.dart';
import 'package:kupi_i_dari/models/location.dart';
import 'package:kupi_i_dari/models/shift.dart';
import 'package:kupi_i_dari/core/statuses.dart';
import 'package:kupi_i_dari/screens/shifts_screen.dart';
import 'package:kupi_i_dari/screens/volunteer_identification_screen.dart';
import 'package:kupi_i_dari/widgets/shift_card.dart';

import 'fakes.dart';

class _DummyLocationsApi implements LocationsApi {
  @override
  Future<List<Location>> list({String? token}) async => const [];

  @override
  Future<Location> createLocation({
    required String name,
    required String address,
    String? token,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Location> updateLocation(
    int locationId, {
    required String name,
    required String address,
    String? token,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Location> setLocationStatus(
    int locationId, {
    required bool isActive,
    String? token,
  }) async {
    throw UnimplementedError();
  }
}

class _DummyAuthApi implements AuthApi {
  @override
  Future<AuthSession> login({
    required String phone,
    required String password,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> registerVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
    required UserRole role,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> loginVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> identifyVolunteer({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AppUser> me({required String token}) async {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> logout({required String token}) async {}
}

Widget _wrap(
  Widget child, {
  FakeShiftsApi? shiftsApi,
  SessionController? controller,
  RegistrationStateController? registrationState,
}) {
  final sessionController =
      controller ?? SessionController(authApi: _DummyAuthApi());
  final api = shiftsApi ?? FakeShiftsApi();
  return SessionScope(
    controller: sessionController,
    child: RegistrationScope(
      controller: registrationState ?? RegistrationStateController(),
      child: ApiScope(
        adminUsersApi: FakeAdminUsersApi(),
        locationsApi: _DummyLocationsApi(),
        shiftsApi: api,
        productsApi: FakeProductsApi(),
        entryApi: FakeEntryApi(),
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    ),
  );
}

Future<SessionController> volunteerSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.identifyVolunteer(
    firstName: 'Иван',
    lastName: 'Петров',
    phone: '0888123456',
  );
  return controller;
}

/// The shifts endpoint needs a bearer token, so the list is read with an
/// authenticated session.
Future<Widget> _wrapAuthenticated(
  Widget child, {
  FakeShiftsApi? shiftsApi,
  RegistrationStateController? registrationState,
}) async {
  return _wrap(
    child,
    shiftsApi: shiftsApi,
    controller: await volunteerSession(),
    registrationState: registrationState,
  );
}

Future<SessionController> staffSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.signInStaff(phone: '0888123456', password: 'secret123');
  return controller;
}

/// Pulls the visible refreshable list down far enough to trigger its
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

Shift _shift(int id, String title, String statusKey) {
  return Shift(
    id: id,
    title: title,
    description: '',
    date: DateTime(2026, 5, 1),
    startTime: '09:00:00',
    endTime: '13:00:00',
    locationIds: const [],
    status: switch (statusKey) {
      'OPEN' => ShiftStatus.available,
      'CLOSED' => ShiftStatus.completed,
      'CANCELLED' => ShiftStatus.archived,
      'DRAFT' => ShiftStatus.draft,
      _ => ShiftStatus.upcoming,
    },
  );
}

void main() {
  group('ShiftsScreen', () {
    testWidgets('shows loading then list', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Сутрешна смяна', 'OPEN')];
      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Сутрешна смяна'), findsOneWidget);
    });

    testWidgets('empty response shows empty state', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [];
      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('Няма намерени смени.'), findsOneWidget);
    });

    testWidgets('search filters by title', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [
        _shift(1, 'Вечерна смяна', 'OPEN'),
        _shift(2, 'Утринна смяна', 'OPEN'),
      ];
      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вечерна смяна'), findsOneWidget);
      expect(find.text('Утринна смяна'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'утрин');
      await tester.pumpAndSettle();
      expect(find.text('Вечерна смяна'), findsNothing);
      expect(find.text('Утринна смяна'), findsOneWidget);
    });

    testWidgets('status filter works', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [
        _shift(1, 'Смяна А', 'OPEN'),
        _shift(2, 'Смяна Б', 'CLOSED'),
      ];
      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('Смяна А'), findsOneWidget);
      expect(find.text('Смяна Б'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, 'Завършена'));
      await tester.pumpAndSettle();
      expect(find.text('Смяна А'), findsNothing);
      expect(find.text('Смяна Б'), findsOneWidget);
    });

    testWidgets('error shows retry and retries', (tester) async {
      final api = FakeShiftsApi();
      api.listError = const ApiException(code: 'HTTP_ERROR', message: 'fail');
      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('Повтори'), findsOneWidget);
      api.listError = null;
      api.listResponse = [_shift(1, 'Нова', 'OPEN')];
      await tester.tap(find.text('Повтори'));
      await tester.pumpAndSettle();
      expect(find.text('Нова'), findsOneWidget);
    });

    testWidgets('location filter uses detail locations', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [
        _shift(1, 'Смяна А', 'OPEN'),
        _shift(2, 'Смяна Б', 'OPEN'),
      ];
      api.detailResponses[1] = ShiftDetail(
        shift: _shift(1, 'Смяна А', 'OPEN'),
        locations: const [
          ShiftDetailLocation(
            id: 10,
            name: 'Пункт X',
            address: 'Адрес 1',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      api.detailResponses[2] = ShiftDetail(
        shift: _shift(2, 'Смяна Б', 'OPEN'),
        locations: const [
          ShiftDetailLocation(
            id: 20,
            name: 'Пункт Y',
            address: 'Адрес 2',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      final location = const Location(
        id: 10,
        name: 'Пункт X',
        address: 'Адрес 1',
      );
      await tester.pumpWidget(
        await _wrapAuthenticated(
          ShiftsScreen(location: location),
          shiftsApi: api,
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Смяна А'), findsOneWidget);
      expect(find.text('Смяна Б'), findsNothing);
    });

    testWidgets('failed detail excludes shift from location filter', (
      tester,
    ) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      api.detailErrors[1] = const ApiException(code: 'NOT_FOUND', message: 'x');
      final location = const Location(
        id: 10,
        name: 'Пункт X',
        address: 'Адрес 1',
      );
      await tester.pumpWidget(
        await _wrapAuthenticated(
          ShiftsScreen(location: location),
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Няма намерени смени.'), findsOneWidget);
    });

    testWidgets('navigates to detail', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      api.detailResponses[1] = ShiftDetail(
        shift: _shift(1, 'Смяна А', 'OPEN'),
        locations: const [
          ShiftDetailLocation(
            id: 1,
            name: 'Център',
            address: 'ул. Х',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Смяна А'));
      await tester.pumpAndSettle();
      expect(find.text('Детайли за смяната'), findsOneWidget);
    });
  });

  group('ShiftsScreen identification', () {
    testWidgets('asks an anonymous visitor to identify instead of reading', (
      tester,
    ) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];

      await tester.pumpWidget(_wrap(const ShiftsScreen(), shiftsApi: api));
      await tester.pumpAndSettle();

      expect(
        find.text('Идентифицирайте се, за да виждате смените.'),
        findsOneWidget,
      );
      // `OutlinedButton.icon` builds a private subtype, so the label is the
      // stable finder.
      expect(find.text('Идентифицирайте се'), findsOneWidget);
      // The shifts endpoint needs a bearer token: no request is sent.
      expect(api.listCalls, 0);
      expect(find.byType(ShiftCard), findsNothing);
    });

    testWidgets('opens the identification screen from the prompt', (
      tester,
    ) async {
      final api = FakeShiftsApi();

      await tester.pumpWidget(_wrap(const ShiftsScreen(), shiftsApi: api));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Идентифицирайте се'));
      await tester.pumpAndSettle();

      expect(find.byType(VolunteerIdentificationScreen), findsOneWidget);
      expect(api.listCalls, 0);
    });

    testWidgets('reads the shifts of an identified visitor', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];

      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();

      expect(api.listCalls, 1);
      expect(api.lastToken, 'vol-token');
      expect(find.text('Смяна А'), findsOneWidget);
      expect(
        find.text('Идентифицирайте се, за да виждате смените.'),
        findsNothing,
      );
    });
  });

  group('ShiftsScreen pull-to-refresh', () {
    testWidgets('triggers a fresh shifts load', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];

      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('Смяна А'), findsOneWidget);
      expect(api.listCalls, 1);

      final gate = api.setPending();
      await _pullToRefresh(tester);
      expect(api.listCalls, 2);

      api.listResponse = [_shift(2, 'Смяна Б', 'OPEN')];
      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Смяна Б'), findsOneWidget);
      expect(find.text('Смяна А'), findsNothing);
    });

    testWidgets('preserves the search text and status filter', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [
        _shift(1, 'Смяна А', 'OPEN'),
        _shift(2, 'Смяна Б', 'CLOSED'),
      ];

      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Смяна');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, 'Завършена'));
      await tester.pumpAndSettle();
      expect(find.text('Смяна Б'), findsOneWidget);
      expect(find.text('Смяна А'), findsNothing);

      final gate = api.setPending();
      await _pullToRefresh(tester);
      expect(api.listCalls, 2);

      api.listResponse = [_shift(3, 'Смяна В', 'CLOSED')];
      gate.complete();
      await tester.pumpAndSettle();

      final searchField = tester.widget<TextField>(
        find.byType(TextField).first,
      );
      expect(searchField.controller?.text, 'Смяна');
      final statusChip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Завършена'),
      );
      expect(statusChip.selected, isTrue);
      expect(find.text('Смяна В'), findsOneWidget);
      expect(find.text('Смяна Б'), findsNothing);
      expect(find.text('Смяна А'), findsNothing);
    });

    testWidgets('works from the empty state', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [];

      await tester.pumpWidget(
        await _wrapAuthenticated(const ShiftsScreen(), shiftsApi: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('Няма намерени смени.'), findsOneWidget);
      expect(api.listCalls, 1);

      final gate = api.setPending();
      await _pullToRefresh(tester);
      expect(api.listCalls, 2);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Няма намерени смени.'), findsOneWidget);
    });

    testWidgets('an anonymous pull gesture never calls the API', (
      tester,
    ) async {
      final api = FakeShiftsApi();

      await tester.pumpWidget(_wrap(const ShiftsScreen(), shiftsApi: api));
      await tester.pumpAndSettle();

      expect(api.listCalls, 0);
      expect(find.byType(RefreshIndicator), findsNothing);

      await tester.drag(
        find.text('Идентифицирайте се, за да виждате смените.'),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();

      expect(api.listCalls, 0);
      expect(find.byType(RefreshIndicator), findsNothing);
    });
  });

  group('ShiftsScreen stale responses', () {
    testWidgets('an older list response cannot replace a newer list', (
      tester,
    ) async {
      final controller = await volunteerSession();
      final api = FakeShiftsApi();
      api.listResponse = [_shift(2, 'Актуална смяна', 'OPEN')];
      final oldGate = api.setPending();
      api.queueListResult([_shift(1, 'Стара смяна', 'OPEN')]);

      await tester.pumpWidget(
        _wrap(const ShiftsScreen(), shiftsApi: api, controller: controller),
      );
      await tester.pump();
      expect(api.listCalls, 1);

      await controller.signOut();
      await tester.pump();
      await controller.signInStaff(phone: '0888123456', password: 'secret123');
      final newGate = api.setPending();
      await tester.pump();
      expect(api.listCalls, 2);

      newGate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Актуална смяна'), findsOneWidget);

      oldGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Актуална смяна'), findsOneWidget);
      expect(find.text('Стара смяна'), findsNothing);
    });

    testWidgets(
      'an older error cannot clear a newer session or show an error',
      (tester) async {
        final controller = await volunteerSession();
        final api = FakeShiftsApi();
        api.listResponse = [_shift(2, 'Актуална смяна', 'OPEN')];
        final oldGate = api.setPending();
        api.queueListResult(
          const ApiException(
            statusCode: 401,
            code: 'UNAUTHORIZED',
            message: 'expired',
          ),
        );

        await tester.pumpWidget(
          _wrap(const ShiftsScreen(), shiftsApi: api, controller: controller),
        );
        await tester.pump();
        expect(api.listCalls, 1);

        await controller.signOut();
        await tester.pump();
        await controller.signInStaff(
          phone: '0888123456',
          password: 'secret123',
        );
        final newGate = api.setPending();
        await tester.pump();
        expect(api.listCalls, 2);

        newGate.complete();
        await tester.pumpAndSettle();
        expect(find.text('Актуална смяна'), findsOneWidget);

        oldGate.complete();
        await tester.pumpAndSettle();

        expect(controller.isAuthenticated, isTrue);
        expect(find.text('Актуална смяна'), findsOneWidget);
        expect(find.text('Повтори'), findsNothing);
        expect(
          find.text('Идентифицирайте се, за да виждате смените.'),
          findsNothing,
        );
      },
    );

    testWidgets('an older detail response cannot replace newer locations', (
      tester,
    ) async {
      const location = Location(id: 10, name: 'Пункт X', address: 'Адрес 1');
      final shift = _shift(1, 'Смяна А', 'OPEN');
      final controller = await volunteerSession();
      final api = FakeShiftsApi();
      api.listResponse = [shift];
      final oldDetailGate = api.queueDetailPending(1);
      api.queueDetailResult(
        1,
        ShiftDetail(
          shift: shift,
          locations: const [
            ShiftDetailLocation(
              id: 20,
              name: 'Друг пункт',
              address: 'Адрес 2',
              isActive: true,
            ),
          ],
          myRegistration: null,
        ),
      );

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(location: location),
          shiftsApi: api,
          controller: controller,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(api.detailCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await controller.signOut();
      await tester.pump();
      await controller.signInStaff(phone: '0888123456', password: 'secret123');
      final newDetailGate = api.queueDetailPending(1);
      api.queueDetailResult(
        1,
        ShiftDetail(
          shift: shift,
          locations: const [
            ShiftDetailLocation(
              id: 10,
              name: 'Пункт X',
              address: 'Адрес 1',
              isActive: true,
            ),
          ],
          myRegistration: null,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(api.detailCalls, 2);

      newDetailGate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Смяна А'), findsOneWidget);

      oldDetailGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Смяна А'), findsOneWidget);
      expect(find.text('Няма намерени смени.'), findsNothing);
    });
  });

  group('ShiftsScreen registration chip', () {
    testWidgets('marks a shift with a confirmed registration', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      final state =
          RegistrationStateController()
            ..setStatus(userId: 1, shiftId: 1, status: 'REGISTERED');

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Записани сте'), findsOneWidget);
      // The chip never triggers an extra request.
      expect(api.detailCalls, 0);
      expect(api.listCalls, 1);
    });

    testWidgets('hides the chip for a cancelled registration', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      final state =
          RegistrationStateController()
            ..setStatus(userId: 1, shiftId: 1, status: 'CANCELLED');

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Записани сте'), findsNothing);
    });

    testWidgets('hides the chip for an unknown status', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      // Only the exact backend status "REGISTERED" counts as a registration.
      final state =
          RegistrationStateController()
            ..setStatus(userId: 1, shiftId: 1, status: 'PENDING');

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Записани сте'), findsNothing);
    });

    testWidgets('hides the chip for another user', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      final state =
          RegistrationStateController()
            ..setStatus(userId: 99, shiftId: 1, status: 'REGISTERED');

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Записани сте'), findsNothing);
    });

    testWidgets('hides the chip for staff and anonymous sessions', (
      tester,
    ) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      final state =
          RegistrationStateController()
            ..setStatus(userId: 1, shiftId: 1, status: 'REGISTERED');

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await staffSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Записани сте'), findsNothing);

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: SessionController(authApi: _DummyAuthApi()),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Записани сте'), findsNothing);
    });

    testWidgets('rebuilds when the registration state changes', (tester) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      final state = RegistrationStateController();

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Записани сте'), findsNothing);

      state.setStatus(userId: 1, shiftId: 1, status: 'REGISTERED');
      await tester.pump();

      expect(find.text('Записани сте'), findsOneWidget);
      // The list is never reloaded because of the registration state.
      expect(api.listCalls, 1);
      expect(api.detailCalls, 0);

      state.setStatus(userId: 1, shiftId: 1, status: 'CANCELLED');
      await tester.pump();

      expect(find.text('Записани сте'), findsNothing);
      expect(api.listCalls, 1);
    });

    testWidgets('publishes the state of the location-filter detail response', (
      tester,
    ) async {
      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      api.detailResponses[1] = ShiftDetail(
        shift: _shift(1, 'Смяна А', 'OPEN'),
        locations: const [
          ShiftDetailLocation(
            id: 10,
            name: 'Пункт X',
            address: 'Адрес 1',
            isActive: true,
          ),
        ],
        myRegistration: const ShiftRegistration(status: 'REGISTERED'),
      );
      final state = RegistrationStateController();
      const location = Location(id: 10, name: 'Пункт X', address: 'Адрес 1');

      await tester.pumpWidget(
        _wrap(
          ShiftsScreen(location: location),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();

      expect(state.isRegistered(1, userId: 1), isTrue);
      expect(find.text('Записани сте'), findsOneWidget);
      // The state is published from the detail response the location filter
      // already needed - no extra request is issued for the registration.
      expect(api.listCalls, 1);
      expect(api.detailCalls, 1);
    });

    testWidgets('shows the chip after returning from a registration', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      api.detailResponses[1] = ShiftDetail(
        shift: _shift(1, 'Смяна А', 'OPEN'),
        locations: const [],
        myRegistration: null,
      );
      api.registrationResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'REGISTERED',
      );
      final state = RegistrationStateController();

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Записани сте'), findsNothing);

      await tester.tap(find.text('Смяна А'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      expect(find.text('Записани сте'), findsOneWidget);
      // The registration state never triggers an extra list request.
      expect(api.listCalls, 1);
    });

    testWidgets('hides the chip after a confirmed cancellation', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = FakeShiftsApi();
      api.listResponse = [_shift(1, 'Смяна А', 'OPEN')];
      api.detailResponses[1] = ShiftDetail(
        shift: _shift(1, 'Смяна А', 'OPEN'),
        locations: const [],
        myRegistration: null,
      );
      api.registrationResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'REGISTERED',
      );
      api.cancelResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'CANCELLED',
      );
      final state = RegistrationStateController();

      await tester.pumpWidget(
        _wrap(
          const ShiftsScreen(),
          shiftsApi: api,
          controller: await volunteerSession(),
          registrationState: state,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Записани сте'), findsNothing);

      await tester.tap(find.text('Смяна А'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();
      expect(state.isRegistered(1, userId: 1), isTrue);

      // The registration id is known, so the cancellation is offered.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Отказ от записа'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, откажи'));
      await tester.pumpAndSettle();

      expect(api.cancelCalls, 1);
      expect(state.statusFor(1, userId: 1), 'CANCELLED');

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      expect(find.text('Записани сте'), findsNothing);
      // The cancelled registration never triggers an extra list request.
      expect(api.listCalls, 1);
    });
  });
}
