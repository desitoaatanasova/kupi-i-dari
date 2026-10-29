import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/api/shifts_api.dart';
import 'package:kupi_i_dari/core/auth/auth_messages.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/core/statuses.dart';
import 'package:kupi_i_dari/models/app_user.dart';
import 'package:kupi_i_dari/models/location.dart';
import 'package:kupi_i_dari/models/shift.dart';
import 'package:kupi_i_dari/screens/shift_detail_screen.dart';
import 'package:kupi_i_dari/screens/shift_editor_screen.dart';
import 'package:kupi_i_dari/screens/shifts_screen.dart';

import 'fakes.dart';

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

Future<SessionController> volunteerSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.identifyVolunteer(
    firstName: 'Иван',
    lastName: 'Петров',
    phone: '0888123456',
  );
  return controller;
}

Shift buildShift({
  int id = 1,
  String title = 'Тестова смяна',
  ShiftStatus status = ShiftStatus.draft,
}) {
  return Shift(
    id: id,
    title: title,
    description: '',
    date: DateTime(2026, 5, 1),
    startTime: '09:00:00',
    endTime: '13:00:00',
    locationIds: const [1],
    status: status,
  );
}

Widget wrap({
  required Widget home,
  required SessionController session,
  required FakeShiftsApi shiftsApi,
  FakeLocationsApi? locationsApi,
}) {
  return SessionScope(
    controller: session,
    child: ApiScope(
      adminUsersApi: FakeAdminUsersApi(),
      locationsApi: locationsApi ?? FakeLocationsApi(),
      shiftsApi: shiftsApi,
      productsApi: FakeProductsApi(),
      entryApi: FakeEntryApi(),
      child: MaterialApp(home: home),
    ),
  );
}

FakeShiftsApi apiFor(
  Shift shift, {
  List<ShiftDetailLocation> locations = const [
    ShiftDetailLocation(
      id: 1,
      name: 'Център',
      address: 'ул. Х 1',
      isActive: true,
    ),
  ],
}) {
  final api = FakeShiftsApi();
  api.detailResponses[shift.id] = ShiftDetail(
    shift: shift,
    locations: locations,
    myRegistration: null,
  );
  return api;
}

Future<void> pumpDetail(
  WidgetTester tester,
  SessionController session,
  FakeShiftsApi api,
  Shift shift,
) async {
  setLargeSurface(tester);
  await tester.pumpWidget(
    wrap(
      home: ShiftDetailScreen(shift: shift),
      session: session,
      shiftsApi: api,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('admin shift creation', () {
    testWidgets('is offered only to admins', (tester) async {
      for (final role in [UserRole.volunteer, UserRole.responsible]) {
        final authApi =
            FakeAuthApi()
              ..loginResponse = buildSession(role: role, token: 'role-token');
        final controller = SessionController(authApi: authApi);
        await controller.signInStaff(
          phone: '0888123456',
          password: 'secret123',
        );
        final api = FakeShiftsApi()..listResponse = [];
        setLargeSurface(tester);
        await tester.pumpWidget(
          wrap(
            home: Scaffold(body: const ShiftsScreen()),
            session: controller,
            shiftsApi: api,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Нова смяна'), findsNothing);
      }
    });

    testWidgets('admin creates a shift with active locations', (tester) async {
      final api = FakeShiftsApi()..listResponse = [];
      final created = buildShift(title: 'Нова тестова смяна');
      api.createShiftResponse = ShiftDetail(
        shift: Shift(
          id: 9,
          title: 'Нова тестова смяна',
          description: '',
          date: DateTime(2026, 5, 10),
          startTime: '09:00:00',
          endTime: '13:00:00',
          locationIds: const [1],
          status: ShiftStatus.draft,
        ),
        locations: const [
          ShiftDetailLocation(
            id: 1,
            name: 'Център',
            address: 'ул. Х 1',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: Scaffold(body: const ShiftsScreen()),
          session: session,
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Нова смяна'));
      await tester.pumpAndSettle();
      expect(find.text('Създай смяна'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('shift-title-field')),
        'Нова тестова смяна',
      );
      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-05-10',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '09:00',
      );
      await tester.enterText(find.byKey(const Key('shift-end-field')), '13:00');
      await tester.tap(find.text('Площад „Светлина“'));
      await tester.pump();

      api.listResponse = [created];
      await tester.tap(find.text('Създай смяна'));
      await tester.pumpAndSettle();

      expect(api.createShiftCalls, 1);
      expect(api.lastCreateTitle, 'Нова тестова смяна');
      expect(api.lastCreateDate, DateTime(2026, 5, 10));
      expect(api.lastCreateStartTime, '09:00');
      expect(api.lastCreateEndTime, '13:00');
      expect(api.lastCreateLocationIds, [1]);
      expect(api.lastCreateToken, 'token-123');
      expect(find.text('Нова тестова смяна'), findsOneWidget);
      expect(api.listCalls, 2);
    });

    testWidgets('explains a creation hidden by the location filter', (
      tester,
    ) async {
      const location = Location(
        id: 1,
        name: 'Площад „Светлина“',
        address: 'ул. Централна 12, София',
      );
      final existing = buildShift(
        id: 1,
        title: 'Съществуваща смяна',
        status: ShiftStatus.available,
      );
      final created = buildShift(id: 9, title: 'Нова извън пункта');
      final api = FakeShiftsApi()..listResponse = [existing];
      api.detailResponses[1] = ShiftDetail(
        shift: existing,
        locations: const [
          ShiftDetailLocation(
            id: 1,
            name: 'Площад „Светлина“',
            address: 'ул. Централна 12, София',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      api.createShiftResponse = ShiftDetail(
        shift: created,
        locations: const [
          ShiftDetailLocation(
            id: 2,
            name: 'Квартален пункт „Младост“',
            address: 'бул. Александър Малинов 45, София',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      api.detailResponses[9] = ShiftDetail(
        shift: created,
        locations: const [
          ShiftDetailLocation(
            id: 2,
            name: 'Квартален пункт „Младост“',
            address: 'бул. Александър Малинов 45, София',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: Scaffold(body: ShiftsScreen(location: location)),
          session: session,
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Съществуваща смяна'), findsOneWidget);

      await tester.tap(find.text('Нова смяна'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('shift-title-field')),
        'Нова извън пункта',
      );
      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-05-10',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '09:00',
      );
      await tester.enterText(find.byKey(const Key('shift-end-field')), '13:00');
      await tester.tap(find.text('Квартален пункт „Младост“'));
      await tester.tap(find.text('Площад „Светлина“'));
      await tester.pump();

      api.listResponse = [existing, created];
      await tester.tap(find.text('Създай смяна'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Смяната е създадена, но не е за избрания пункт и не се показва в '
          'този списък.',
        ),
        findsOneWidget,
      );
      expect(find.text('Нова извън пункта'), findsNothing);
      expect(find.text('Виж новата'), findsOneWidget);

      await tester.tap(find.text('Виж новата'));
      await tester.pumpAndSettle();
      expect(find.text('Детайли за смяната'), findsOneWidget);
    });

    testWidgets('disables a second create submission while one is pending', (
      tester,
    ) async {
      final api = FakeShiftsApi()..listResponse = [];
      final createdShift = buildShift(id: 9, title: 'Нова смяна');
      api.createShiftResponse = ShiftDetail(
        shift: createdShift,
        locations: const [
          ShiftDetailLocation(
            id: 1,
            name: 'Център',
            address: 'ул. Х 1',
            isActive: true,
          ),
        ],
        myRegistration: null,
      );
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: Scaffold(body: const ShiftsScreen()),
          session: session,
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Нова смяна'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('shift-title-field')),
        'Нова смяна',
      );
      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-05-10',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '09:00',
      );
      await tester.enterText(find.byKey(const Key('shift-end-field')), '13:00');
      await tester.tap(find.text('Площад „Светлина“'));
      await tester.pump();

      final gate = api.setCreateShiftPending();
      await tester.tap(find.text('Създай смяна'));
      await tester.pump();
      await tester.tap(find.text('Създай смяна'));
      await tester.pump();
      expect(api.createShiftCalls, 1);

      api.listResponse = [createdShift];
      gate.complete();
      await tester.pumpAndSettle();
      expect(api.createShiftCalls, 1);
    });

    testWidgets('requires at least one location before sending', (
      tester,
    ) async {
      final api = FakeShiftsApi()..listResponse = [];
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: Scaffold(body: const ShiftsScreen()),
          session: session,
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Нова смяна'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-05-10',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '09:00',
      );
      await tester.enterText(find.byKey(const Key('shift-end-field')), '13:00');
      await tester.tap(find.text('Създай смяна'));
      await tester.pump();

      expect(find.text('Изберете поне един пункт.'), findsOneWidget);
      expect(api.createShiftCalls, 0);
    });

    testWidgets('rejects more than 100 selected locations before sending', (
      tester,
    ) async {
      final api = FakeShiftsApi()..listResponse = [];
      final locationsApi =
          FakeLocationsApi()
            ..listResponse = List<Location>.generate(
              101,
              (index) => Location(
                id: index + 1,
                name: 'Пункт ${index + 1}',
                address: 'Адрес ${index + 1}',
              ),
            );
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: const ShiftEditorScreen(),
          session: session,
          shiftsApi: api,
          locationsApi: locationsApi,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-05-10',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '09:00',
      );
      await tester.enterText(find.byKey(const Key('shift-end-field')), '13:00');
      final tiles = tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect(tiles.length, 101);
      for (final tile in tiles) {
        tile.onChanged!(true);
      }
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Създай смяна'),
        1000,
        maxScrolls: 20,
        scrollable:
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Създай смяна'));
      await tester.pump();

      expect(find.text('Може да изберете до 100 пункта.'), findsOneWidget);
      expect(api.createShiftCalls, 0);
    });

    testWidgets('validates the time range locally', (tester) async {
      final api = FakeShiftsApi()..listResponse = [];
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: Scaffold(body: const ShiftsScreen()),
          session: session,
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Нова смяна'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-05-10',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '13:00',
      );
      await tester.enterText(find.byKey(const Key('shift-end-field')), '09:00');
      await tester.tap(find.text('Площад „Светлина“'));
      await tester.tap(find.text('Създай смяна'));
      await tester.pump();

      expect(
        find.text('Краят на смяната трябва да е след началото.'),
        findsOneWidget,
      );
      expect(api.createShiftCalls, 0);
    });

    testWidgets('validates the date, time and title before sending', (
      tester,
    ) async {
      final api = FakeShiftsApi()..listResponse = [];
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: Scaffold(body: const ShiftsScreen()),
          session: session,
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Нова смяна'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Площад „Светлина“'));
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-02-30',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '09:00',
      );
      await tester.enterText(find.byKey(const Key('shift-end-field')), '13:00');
      await tester.tap(find.text('Създай смяна'));
      await tester.pump();
      expect(
        find.text('Въведете валидна дата във формат ГГГГ-ММ-ДД.'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('shift-date-field')),
        '2026-05-10',
      );
      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '9:00',
      );
      await tester.tap(find.text('Създай смяна'));
      await tester.pump();
      expect(
        find.text('Въведете валиден час във формат ЧЧ:ММ.'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('shift-start-field')),
        '09:00',
      );
      final titleField = tester.widget<TextFormField>(
        find.byKey(const Key('shift-title-field')),
      );
      titleField.controller!.text = 'З' * 121;
      await tester.pump();
      await tester.tap(find.text('Създай смяна'));
      await tester.pump();
      expect(find.text('Заглавието може да е до 120 знака.'), findsOneWidget);
      expect(api.createShiftCalls, 0);
    });
  });

  group('admin shift management', () {
    testWidgets('draft shift can be edited and then published', (tester) async {
      final shift = buildShift();
      final api = apiFor(shift);
      final updated = buildShift(title: 'Обновена смяна');
      api.updateShiftResponse = updated;
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      expect(find.text('Публикувай'), findsOneWidget);
      expect(find.text('Затвори смяната'), findsNothing);

      await tester.tap(find.text('Редактирай данните'));
      await tester.pumpAndSettle();
      expect(find.text('Редактиране на смяна'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('shift-title-field')),
        'Обновена смяна',
      );
      api.detailResponses[shift.id] = ShiftDetail(
        shift: updated,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );
      await tester.tap(find.text('Запази промените'));
      await tester.pumpAndSettle();

      expect(api.updateShiftCalls, 1);
      expect(api.lastUpdateShiftId, 1);
      expect(api.lastUpdateTitle, 'Обновена смяна');
      expect(api.lastUpdateDate, DateTime(2026, 5, 1));
      expect(find.text('Обновена смяна'), findsOneWidget);
      expect(find.text('Промените по смяната са запазени.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));

      final openShift = buildShift(
        title: 'Обновена смяна',
        status: ShiftStatus.available,
      );
      api.setStatusResponse = openShift;
      api.detailResponses[shift.id] = ShiftDetail(
        shift: openShift,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );
      await tester.tap(find.text('Публикувай'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 1);
      expect(api.lastSetStatusShiftId, 1);
      expect(api.lastSetStatus, 'OPEN');
      expect(find.text('Смяната е публикувана.'), findsOneWidget);
      expect(find.text('Затвори смяната'), findsOneWidget);
      expect(find.text('Публикувай'), findsNothing);
    });

    testWidgets('closing asks for confirmation and is backend-confirmed', (
      tester,
    ) async {
      final shift = buildShift(status: ShiftStatus.available);
      final api = apiFor(shift);
      final closed = buildShift(status: ShiftStatus.completed);
      api.setStatusResponse = closed;
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);
      api.detailResponses[shift.id] = ShiftDetail(
        shift: closed,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );

      await tester.tap(find.text('Затвори смяната'));
      await tester.pumpAndSettle();
      expect(find.text('Затваряне на смяната'), findsOneWidget);
      await tester.tap(find.text('Не, остава отворена'));
      await tester.pumpAndSettle();
      expect(api.setStatusCalls, 0);

      await tester.tap(find.text('Затвори смяната'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, затвори'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 1);
      expect(api.lastSetStatus, 'CLOSED');
      expect(find.text('Смяната е затворена.'), findsOneWidget);
      expect(find.text('Редактирай данните'), findsNothing);
      expect(find.text('Затвори смяната'), findsNothing);
    });

    testWidgets('cancelling a draft removes all management actions', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      final cancelled = buildShift(status: ShiftStatus.archived);
      api.setStatusResponse = cancelled;
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);
      api.detailResponses[shift.id] = ShiftDetail(
        shift: cancelled,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );

      await tester.tap(find.text('Отмени смяната'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, отмени'));
      await tester.pumpAndSettle();

      expect(api.lastSetStatus, 'CANCELLED');
      expect(find.text('Смяната е отменена.'), findsOneWidget);
      expect(find.text('Управление на смяната'), findsNothing);
      expect(find.text('Редактирай данните'), findsNothing);
    });

    testWidgets('cancelling can be dismissed without a request', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Отмени смяната'));
      await tester.pumpAndSettle();
      expect(find.text('Отмяна на смяната'), findsOneWidget);

      await tester.tap(find.text('Не, запази смяната'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 0);
      expect(find.text('Отмени смяната'), findsOneWidget);
      expect(find.text('Управление на смяната'), findsOneWidget);
    });

    testWidgets('closed and cancelled shifts are read-only', (tester) async {
      for (final status in [ShiftStatus.completed, ShiftStatus.archived]) {
        final shift = buildShift(status: status);
        final api = apiFor(shift);
        setLargeSurface(tester);
        await tester.pumpWidget(
          wrap(
            home: ShiftDetailScreen(shift: shift),
            session: await adminSession(),
            shiftsApi: api,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Управление на смяната'), findsNothing);
        expect(find.text('Редактирай данните'), findsNothing);
        expect(find.text('Промени пунктовете'), findsNothing);
        expect(find.text('Затвори смяната'), findsNothing);
        expect(find.text('Отмени смяната'), findsNothing);
      }
    });

    testWidgets('volunteers never see management controls', (tester) async {
      final shift = buildShift(status: ShiftStatus.available);
      final api = apiFor(shift);
      await pumpDetail(tester, await volunteerSession(), api, shift);

      expect(find.text('Управление на смяната'), findsNothing);
      expect(find.text('Редактирай данните'), findsNothing);
      expect(find.text('Промени пунктовете'), findsNothing);
      expect(find.text('Затвори смяната'), findsNothing);
      expect(find.text('Отмени смяната'), findsNothing);
    });

    testWidgets('reports an invalid status transition in Bulgarian', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      api.setStatusError = const ApiException(
        statusCode: 409,
        code: 'INVALID_STATUS_TRANSITION',
        message: 'not allowed',
      );
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Публикувай'));
      await tester.pumpAndSettle();

      expect(
        find.text('Тази промяна на статуса не е разрешена.'),
        findsOneWidget,
      );
      expect(find.text('Публикувай'), findsOneWidget);
    });

    testWidgets('a 401 status change clears the session', (tester) async {
      final shift = buildShift();
      final api = apiFor(shift);
      api.setStatusError = const ApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'expired',
      );
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Публикувай'));
      await tester.pumpAndSettle();

      expect(session.isAuthenticated, isFalse);
      expect(find.text('Смяната е публикувана.'), findsNothing);
    });

    testWidgets('an edit cannot be submitted twice while pending', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      final updated = buildShift(title: 'Обновена смяна');
      api.updateShiftResponse = updated;
      api.detailResponses[shift.id] = ShiftDetail(
        shift: updated,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Редактирай данните'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('shift-title-field')),
        'Обновена смяна',
      );
      final gate = api.setUpdateShiftPending();
      await tester.tap(find.text('Запази промените'));
      await tester.pump();
      await tester.tap(find.text('Запази промените'));
      await tester.pump();
      expect(api.updateShiftCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(api.updateShiftCalls, 1);
    });

    testWidgets('a status change cannot be submitted twice while pending', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      final published = buildShift(status: ShiftStatus.available);
      api.setStatusResponse = published;
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);
      api.detailResponses[shift.id] = ShiftDetail(
        shift: published,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );

      final gate = api.setSetStatusPending();
      await tester.tap(find.text('Публикувай'));
      await tester.pump();
      await tester.tap(find.text('Публикувай'));
      await tester.pump();
      expect(api.setStatusCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(api.setStatusCalls, 1);
    });

    testWidgets('a failed edit keeps the editor open in Bulgarian', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      const error = ApiException(code: 'HTTP_ERROR', message: 'failed');
      api.updateShiftError = error;
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Редактирай данните'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запази промените'));
      await tester.pumpAndSettle();

      expect(api.updateShiftCalls, 1);
      expect(find.text('Редактиране на смяна'), findsOneWidget);
      expect(find.text(AuthMessages.forException(error)), findsOneWidget);
    });

    testWidgets('a failed close keeps the shift manageable', (tester) async {
      final shift = buildShift(status: ShiftStatus.available);
      final api = apiFor(shift);
      api.setStatusError = const ApiException(
        statusCode: 409,
        code: 'INVALID_STATUS_TRANSITION',
        message: 'not allowed',
      );
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Затвори смяната'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, затвори'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 1);
      expect(
        find.text('Тази промяна на статуса не е разрешена.'),
        findsOneWidget,
      );
      expect(find.text('Затвори смяната'), findsOneWidget);
      expect(find.text('Редактирай данните'), findsOneWidget);
    });

    testWidgets('a failed cancel keeps the shift manageable', (tester) async {
      final shift = buildShift();
      final api = apiFor(shift);
      api.setStatusError = const ApiException(
        statusCode: 409,
        code: 'INVALID_STATUS_TRANSITION',
        message: 'not allowed',
      );
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Отмени смяната'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, отмени'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 1);
      expect(
        find.text('Тази промяна на статуса не е разрешена.'),
        findsOneWidget,
      );
      expect(find.text('Отмени смяната'), findsOneWidget);
      expect(find.text('Управление на смяната'), findsOneWidget);
    });

    testWidgets('an older detail response cannot replace a newer status', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      final updated = buildShift(title: 'Обновена смяна');
      api.updateShiftResponse = updated;
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Редактирай данните'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('shift-title-field')),
        'Обновена смяна',
      );

      final oldReloadGate = api.queueDetailPending(shift.id);
      api.queueDetailResult(
        shift.id,
        ShiftDetail(
          shift: updated,
          locations: api.detailResponses[shift.id]!.locations,
          myRegistration: null,
        ),
      );
      await tester.tap(find.text('Запази промените'));
      await tester.pump();
      await tester.pump();

      expect(api.updateShiftCalls, 1);
      expect(api.detailCalls, 2);

      final openShift = buildShift(
        title: 'Обновена смяна',
        status: ShiftStatus.available,
      );
      api.setStatusResponse = openShift;
      api.detailResponses[shift.id] = ShiftDetail(
        shift: openShift,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );
      await tester.tap(find.text('Публикувай'));
      await tester.pumpAndSettle();

      expect(api.setStatusCalls, 1);
      expect(find.text('Затвори смяната'), findsOneWidget);
      expect(find.text('Публикувай'), findsNothing);

      oldReloadGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Затвори смяната'), findsOneWidget);
      expect(find.text('Публикувай'), findsNothing);
    });

    testWidgets('location replacement sends the complete active set', (
      tester,
    ) async {
      final shift = buildShift(status: ShiftStatus.available);
      final api = apiFor(
        shift,
        locations: const [
          ShiftDetailLocation(
            id: 1,
            name: 'Център',
            address: 'ул. Х 1',
            isActive: true,
          ),
          ShiftDetailLocation(
            id: 99,
            name: 'Стар архив',
            address: 'ул. Стара 2',
            isActive: false,
          ),
        ],
      );
      api.replaceLocationsResponse = const [
        ShiftDetailLocation(
          id: 1,
          name: 'Център',
          address: 'ул. Х 1',
          isActive: true,
        ),
        ShiftDetailLocation(
          id: 2,
          name: 'Квартален пункт „Младост“',
          address: 'бул. Александър Малинов 45, София',
          isActive: true,
        ),
      ];
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Промени пунктовете'));
      await tester.pumpAndSettle();

      expect(find.text('Стар архив'), findsOneWidget);
      expect(
        find.textContaining('при запазване ще бъде премахнат'),
        findsOneWidget,
      );
      final archivedTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Стар архив'),
      );
      expect(archivedTile.enabled, isFalse);

      await tester.tap(find.text('Квартален пункт „Младост“'));
      api.detailResponses[shift.id] = ShiftDetail(
        shift: shift,
        locations: api.replaceLocationsResponse!,
        myRegistration: null,
      );
      await tester.tap(find.text('Запази пунктовете'));
      await tester.pumpAndSettle();

      expect(api.replaceLocationsCalls, 1);
      expect(api.lastReplaceLocationsShiftId, 1);
      expect(api.lastReplaceLocationIds, [1, 2]);
      expect(api.lastReplaceLocationsToken, 'token-123');
      expect(find.text('Пунктовете на смяната са обновени.'), findsOneWidget);
    });

    testWidgets('reports a non-editable shift and reloads the detail', (
      tester,
    ) async {
      final shift = buildShift();
      final api = apiFor(shift);
      api.replaceLocationsError = const ApiException(
        statusCode: 409,
        code: 'SHIFT_NOT_EDITABLE',
        message: 'closed',
      );
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);
      final detailCallsBefore = api.detailCalls;

      await tester.tap(find.text('Промени пунктовете'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запази пунктовете'));
      await tester.pumpAndSettle();

      expect(
        find.text('Тази смяна вече не може да бъде редактирана.'),
        findsOneWidget,
      );
      expect(api.detailCalls, greaterThan(detailCallsBefore));
    });

    testWidgets('reports an invalid location selection', (tester) async {
      final shift = buildShift();
      final api = apiFor(shift);
      api.replaceLocationsError = const ApiException(
        statusCode: 400,
        code: 'INVALID_LOCATION',
        message: 'missing',
      );
      final session = await adminSession();
      await pumpDetail(tester, session, api, shift);

      await tester.tap(find.text('Промени пунктовете'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запази пунктовете'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Един или повече избрани пунктове липсват или са архивирани.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('notifies the list after a confirmed mutation', (tester) async {
      final shift = buildShift(status: ShiftStatus.available);
      final api = apiFor(shift);
      api.listResponse = [shift];
      final closed = buildShift(status: ShiftStatus.completed);
      api.setStatusResponse = closed;
      final session = await adminSession();
      setLargeSurface(tester);
      await tester.pumpWidget(
        wrap(
          home: Scaffold(body: const ShiftsScreen()),
          session: session,
          shiftsApi: api,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Тестова смяна'));
      await tester.pumpAndSettle();
      final listCallsBefore = api.listCalls;
      api.detailResponses[shift.id] = ShiftDetail(
        shift: closed,
        locations: api.detailResponses[shift.id]!.locations,
        myRegistration: null,
      );

      await tester.tap(find.text('Затвори смяната'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, затвори'));
      await tester.pumpAndSettle();

      expect(api.listCalls, greaterThan(listCallsBefore));
    });
  });

  group('admin error messages', () {
    test('the documented codes have exact Bulgarian messages', () {
      expect(
        AuthMessages.forCode('INVALID_LOCATION'),
        'Един или повече избрани пунктове липсват или са архивирани.',
      );
      expect(
        AuthMessages.forCode('SHIFT_NOT_EDITABLE'),
        'Тази смяна вече не може да бъде редактирана.',
      );
      expect(
        AuthMessages.forCode('INVALID_STATUS_TRANSITION'),
        'Тази промяна на статуса не е разрешена.',
      );
    });
  });
}
