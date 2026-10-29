import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/api/shifts_api.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/core/statuses.dart';
import 'package:kupi_i_dari/data/sample_data.dart';
import 'package:kupi_i_dari/main.dart';
import 'package:kupi_i_dari/models/catalog_product.dart';
import 'package:kupi_i_dari/models/entry_context.dart';
import 'package:kupi_i_dari/models/location.dart';
import 'package:kupi_i_dari/models/shift.dart';
import 'package:kupi_i_dari/screens/entry_screen.dart';
import 'package:kupi_i_dari/screens/locations_screen.dart';
import 'package:kupi_i_dari/screens/login_screen.dart';
import 'package:kupi_i_dari/screens/shift_detail_screen.dart';
import 'package:kupi_i_dari/screens/shifts_screen.dart';
import 'package:kupi_i_dari/screens/volunteer_identification_screen.dart';
import 'package:kupi_i_dari/widgets/category_card.dart';
import 'package:kupi_i_dari/widgets/quantity_input.dart';
import 'package:kupi_i_dari/widgets/shift_card.dart';
import 'package:kupi_i_dari/widgets/status_chip.dart';

import 'fakes.dart';

void setLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> settleSnackbar(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump();
}

Future<void> pumpBody(WidgetTester tester, Widget body) async {
  setLargeSurface(tester);
  await tester.pumpWidget(
    SessionScope(
      controller: await authenticatedVolunteerSession(),
      child: ApiScope(
        adminUsersApi: FakeAdminUsersApi(),
        locationsApi: FakeLocationsApi(),
        shiftsApi: FakeShiftsApi(),
        productsApi: FakeProductsApi(),
        entryApi: FakeEntryApi(),
        child: MaterialApp(home: Scaffold(body: body)),
      ),
    ),
  );
}

Future<SessionController> authenticatedVolunteerSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.identifyVolunteer(
    firstName: 'Иван',
    lastName: 'Петров',
    phone: '0888123456',
  );
  return controller;
}

Future<SessionController> authenticatedStaffSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.signInStaff(phone: '0888123456', password: 'secret123');
  return controller;
}

final openShift = Shift(
  id: 1,
  title: 'Сутрешна смяна',
  description: '',
  date: DateTime(2026, 5, 1),
  startTime: '09:00:00',
  endTime: '13:00:00',
  locationIds: const [],
  status: ShiftStatus.available,
);

void main() {
  group('ShiftStatus', () {
    test('exposes Bulgarian labels for all eight statuses', () {
      expect(ShiftStatus.values.map((status) => status.label), [
        'Чернова',
        'Предстояща',
        'Отворена за записване',
        'Почти пълна',
        'Пълна',
        'В процес',
        'Завършена',
        'Архивирана',
      ]);
    });

    test('fromKey resolves keys and rejects unknown ones', () {
      expect(ShiftStatus.fromKey('almost_full'), ShiftStatus.almostFull);
      expect(ShiftStatus.fromKey('available'), ShiftStatus.available);
      expect(ShiftStatus.fromKey('unknown'), isNull);
    });

    testWidgets('StatusChip renders the status label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: StatusChip(status: ShiftStatus.inProcess)),
          ),
        ),
      );
      expect(find.text('В процес'), findsOneWidget);
    });
  });

  group('QuantityInput validator', () {
    final validate = QuantityInput.validator();

    test('accepts empty values and whole numbers within range', () {
      expect(validate(null), isNull);
      expect(validate(''), isNull);
      expect(validate('0'), isNull);
      expect(validate('5'), isNull);
      expect(validate('2147483647'), isNull);
    });

    test('rejects non-integers and out-of-range values', () {
      expect(validate('abc'), 'Въведете цяло число.');
      expect(validate('-1'), 'Въведете цяло число.');
      expect(validate('1.5'), 'Въведете цяло число.');
      expect(validate('2147483648'), 'Твърде голямо число.');
    });

    testWidgets('renders a numeric text field', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: QuantityInput(labelText: 'Количество')),
        ),
      );
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.text('Количество'), findsOneWidget);
    });
  });

  group('LoginScreen', () {
    testWidgets('validates phone and password before signing in', (
      tester,
    ) async {
      setLargeSurface(tester);
      final api = FakeAuthApi();
      final locApi = FakeLocationsApi();
      await tester.pumpWidget(
        SessionScope(
          controller: SessionController(authApi: api),
          child: ApiScope(
            adminUsersApi: FakeAdminUsersApi(),
            locationsApi: locApi,
            shiftsApi: FakeShiftsApi(),
            productsApi: FakeProductsApi(),
            entryApi: FakeEntryApi(),
            child: const MaterialApp(home: LoginScreen()),
          ),
        ),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pump();
      expect(find.text('Въведете телефонен номер.'), findsOneWidget);
      expect(find.text('Въведете парола.'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(0), '123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pump();
      expect(find.text('Въведете валиден телефонен номер.'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(0), '0888123456');
      await tester.enterText(find.byType(TextFormField).at(1), 'secret123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pumpAndSettle();
      expect(api.loginCalls, 1);
      expect(find.text('Пунктове за събиране'), findsOneWidget);
    });

    testWidgets('start screen navigates to volunteer/staff login and demo', (
      tester,
    ) async {
      setLargeSurface(tester);
      await tester.pumpWidget(KupiIDariApp(locationsApi: FakeLocationsApi()));

      await tester.tap(find.widgetWithText(ElevatedButton, 'Вход'));
      await tester.pumpAndSettle();
      expect(find.byType(VolunteerIdentificationScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Служебен вход'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Разгледай демо съдържанието'));
      await tester.pumpAndSettle();
      expect(find.text('Пунктове за събиране'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('LocationsScreen', () {
    Future<void> pumpLocations(
      WidgetTester tester,
      FakeLocationsApi api,
    ) async {
      setLargeSurface(tester);
      await tester.pumpWidget(
        SessionScope(
          controller: await authenticatedVolunteerSession(),
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
    }

    testWidgets('lists active locations and hides archived ones', (
      tester,
    ) async {
      await pumpLocations(tester, FakeLocationsApi());

      expect(find.text('Пунктове за събиране'), findsOneWidget);
      expect(find.text('Площад „Светлина“'), findsOneWidget);
      expect(find.text('Квартален пункт „Младост“'), findsOneWidget);
      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Пункт „Северен“'), findsOneWidget);
      expect(find.text('Пункт „Централен пазар“'), findsNothing);
    });

    testWidgets('search filters locations and clear restores them', (
      tester,
    ) async {
      await pumpLocations(tester, FakeLocationsApi());

      await tester.enterText(find.byType(TextField).first, 'Пловдив');
      await tester.pump();
      expect(find.text('Пункт „Тракия“'), findsOneWidget);
      expect(find.text('Площад „Светлина“'), findsNothing);

      await tester.tap(find.byTooltip('Изчисти търсенето'));
      await tester.pump();
      expect(find.text('Площад „Светлина“'), findsOneWidget);
      expect(find.text('Пункт „Северен“'), findsOneWidget);
    });

    testWidgets('opens the location shift list', (tester) async {
      await pumpLocations(tester, FakeLocationsApi());

      await tester.tap(find.text('Пункт „Тракия“'));
      await tester.pumpAndSettle();
      expect(find.text('Смени за Пункт „Тракия“'), findsOneWidget);
      expect(find.byType(ShiftCard), findsWidgets);
    });
  });

  group('ShiftsScreen', () {
    testWidgets('shows all shifts sorted with a registerable one first', (
      tester,
    ) async {
      await pumpBody(tester, const ShiftsScreen());
      await tester.pump();

      expect(find.text('Всички смени'), findsOneWidget);
      expect(find.byType(ShiftCard), findsNWidgets(8));

      final firstCard = tester.widget<ShiftCard>(find.byType(ShiftCard).first);
      expect(firstCard.shift.status, ShiftStatus.available);
    });

    testWidgets('search, status filter and reset work together', (
      tester,
    ) async {
      await pumpBody(tester, const ShiftsScreen());

      await tester.enterText(find.byType(TextField).first, 'Пловдив');
      await tester.pump();
      expect(find.byType(ShiftCard), findsOneWidget);
      expect(find.text('Нулирай филтрите'), findsOneWidget);

      await tester.tap(find.text('Нулирай филтрите'));
      await tester.pump();
      expect(find.byType(ShiftCard), findsNWidgets(8));
      expect(find.text('Нулирай филтрите'), findsNothing);

      await tester.tap(find.widgetWithText(FilterChip, 'Пълна'));
      await tester.pump();
      expect(find.byType(ShiftCard), findsOneWidget);
      expect(find.text('Нулирай филтрите'), findsOneWidget);

      await tester.tap(find.text('Нулирай филтрите'));
      await tester.pump();
      expect(find.byType(ShiftCard), findsNWidgets(8));
    });
  });

  group('ShiftDetailScreen', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required SessionController session,
      required FakeShiftsApi shiftsApi,
      Shift? shift,
    }) async {
      setLargeSurface(tester);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: ApiScope(
            adminUsersApi: FakeAdminUsersApi(),
            locationsApi: FakeLocationsApi(),
            shiftsApi: shiftsApi,
            productsApi: FakeProductsApi(),
            entryApi: FakeEntryApi(),
            child: MaterialApp(
              home: ShiftDetailScreen(shift: shift ?? openShift),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    FakeShiftsApi shiftsApiWithDetail({String? myRegistrationStatus}) {
      final api = FakeShiftsApi();
      api.detailResponses[openShift.id] = ShiftDetail(
        shift: openShift,
        locations: const [],
        myRegistration:
            myRegistrationStatus == null
                ? null
                : ShiftRegistration(status: myRegistrationStatus),
      );
      return api;
    }

    testWidgets('registers a volunteer for an open shift', (tester) async {
      final session = await authenticatedVolunteerSession();
      final api =
          shiftsApiWithDetail()
            ..registrationResponse = const RegistrationResult(
              id: 9,
              shiftId: 1,
              userId: 1,
              status: 'REGISTERED',
            );

      await pumpDetail(tester, session: session, shiftsApi: api);

      expect(find.text('Детайли за смяната'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(api.registrationCalls, 1);
      expect(api.lastRegistrationShiftId, 1);
      expect(api.lastRegistrationToken, 'vol-token');
      expect(find.text('Записахте се успешно.'), findsOneWidget);
      await settleSnackbar(tester);
      expect(find.text('Записахте се за тази смяна.'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsNothing);
    });

    testWidgets('shows the registered state from detail data', (tester) async {
      final session = await authenticatedVolunteerSession();
      final api = shiftsApiWithDetail(myRegistrationStatus: 'REGISTERED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      expect(find.text('Записахте се за тази смяна.'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsNothing);
      expect(api.registrationCalls, 0);
    });

    testWidgets('treats a cancelled registration as not registered', (
      tester,
    ) async {
      final session = await authenticatedVolunteerSession();
      final api = shiftsApiWithDetail(myRegistrationStatus: 'CANCELLED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsOneWidget);
    });

    testWidgets('prevents duplicate taps while a request is pending', (
      tester,
    ) async {
      final session = await authenticatedVolunteerSession();
      final api = shiftsApiWithDetail();
      final gate = Completer<void>();
      api.registrationGate = gate;
      api.registrationResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'REGISTERED',
      );

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pump();
      expect(api.registrationCalls, 1);

      // While pending the button is disabled (no label), so a second attempt
      // must not issue another request.
      final pendingButton = tester.widget<ElevatedButton>(
        find.byType(ElevatedButton),
      );
      expect(pendingButton.onPressed, isNull);
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(api.registrationCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Записахте се успешно.'), findsOneWidget);
    });

    testWidgets('reconciles an ALREADY_REGISTERED response', (tester) async {
      final session = await authenticatedVolunteerSession();
      final api =
          shiftsApiWithDetail()
            ..registrationError = buildError(409, 'ALREADY_REGISTERED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(find.text('Вече сте записани за тази смяна.'), findsOneWidget);
      expect(find.text('Записахте се успешно.'), findsNothing);

      // Reconciliation reloads the detail; now the server reports REGISTERED.
      await settleSnackbar(tester);
      expect(api.detailCalls, greaterThan(1));
    });

    testWidgets('shows a registration-specific message for SHIFT_NOT_OPEN', (
      tester,
    ) async {
      final session = await authenticatedVolunteerSession();
      final api =
          shiftsApiWithDetail()
            ..registrationError = buildError(409, 'SHIFT_NOT_OPEN');

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(
        find.text('Записването е възможно само докато смяната е отворена.'),
        findsOneWidget,
      );
      expect(find.text('Записахте се успешно.'), findsNothing);
    });

    testWidgets('shows a Bulgarian FORBIDDEN message', (tester) async {
      final session = await authenticatedVolunteerSession();
      final api =
          shiftsApiWithDetail()
            ..registrationError = buildError(403, 'FORBIDDEN');

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(
        find.text('Нямате права да извършите това действие.'),
        findsOneWidget,
      );
    });

    testWidgets('clears the session on an unauthorized response', (
      tester,
    ) async {
      final session = await authenticatedVolunteerSession();
      final api =
          shiftsApiWithDetail()
            ..registrationError = buildError(401, 'UNAUTHORIZED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(session.isAuthenticated, isFalse);
      expect(find.text('Записахте се успешно.'), findsNothing);
    });

    testWidgets('hides the register button for staff users', (tester) async {
      final session = await authenticatedStaffSession();
      final api = shiftsApiWithDetail();

      await pumpDetail(tester, session: session, shiftsApi: api);

      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsNothing);
    });

    testWidgets('hides the register button for anonymous users', (
      tester,
    ) async {
      final session = SessionController(authApi: FakeAuthApi());
      final api = shiftsApiWithDetail();

      await pumpDetail(tester, session: session, shiftsApi: api);

      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsNothing);
    });

    testWidgets('hides the register button for non-open shifts', (
      tester,
    ) async {
      final session = await authenticatedVolunteerSession();
      for (final status in const [
        ShiftStatus.completed,
        ShiftStatus.archived,
        ShiftStatus.upcoming,
      ]) {
        final shift = Shift(
          id: 1,
          title: 'Смяна',
          description: '',
          date: DateTime(2026, 5, 1),
          startTime: '09:00:00',
          endTime: '13:00:00',
          locationIds: const [],
          status: status,
        );
        final api = FakeShiftsApi();
        api.detailResponses[1] = ShiftDetail(
          shift: shift,
          locations: const [],
          myRegistration: null,
        );

        await pumpDetail(
          tester,
          session: session,
          shiftsApi: api,
          shift: shift,
        );
        expect(
          find.widgetWithText(ElevatedButton, 'Запиши се'),
          findsNothing,
          reason: 'status ${status.name} must not offer registration',
        );
      }
    });

    testWidgets('keeps the quantity-entry navigation', (tester) async {
      final session = await authenticatedVolunteerSession();
      final api = shiftsApiWithDetail(myRegistrationStatus: 'REGISTERED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      // `OutlinedButton.icon` builds a private subtype, so the label is the
      // stable finder.
      await tester.tap(find.text('Отчитане на количества'));
      await tester.pumpAndSettle();
      expect(find.byType(EntryScreen), findsOneWidget);
    });
  });

  group('EntryScreen', () {
    Future<SessionController> volunteerSession() async {
      final auth = FakeAuthApi();
      final controller = SessionController(authApi: auth);
      await controller.identifyVolunteer(
        firstName: 'Иван',
        lastName: 'Петров',
        phone: '0888123456',
      );
      return controller;
    }

    EntryContext buildContext({
      bool canSubmit = true,
      String? submissionError,
      List<Location>? locations,
      List<QuantityRecord> quantities = const [],
    }) {
      return EntryContext(
        shift: Shift(
          id: 5,
          title: 'Смяна в центъра',
          description: '',
          date: DateTime(2026, 3, 2),
          startTime: '09:00:00',
          endTime: '13:00:00',
          locationIds: const [1, 2],
          status: ShiftStatus.available,
        ),
        canSubmit: canSubmit,
        submissionError: submissionError,
        entryWindow: const EntryWindow(
          opensAt: '2026-03-02T09:00:00+02:00',
          closesAt: '2026-03-02T13:30:00+02:00',
        ),
        locations:
            locations ??
            const [
              Location(
                id: 1,
                name: 'Център',
                address: 'ул. Витоша 1',
                isActive: true,
              ),
            ],
        quantities: quantities,
      );
    }

    FakeProductsApi buildProducts() {
      return FakeProductsApi(
        products: const [
          CatalogProduct(
            id: 10,
            name: 'Шампоан',
            category: 'Хигиена',
            isActive: true,
          ),
          CatalogProduct(
            id: 11,
            name: 'Сапун',
            category: 'Хигиена',
            isActive: true,
          ),
          CatalogProduct(
            id: 12,
            name: 'Ориз',
            category: 'Храна',
            isActive: true,
          ),
          CatalogProduct(
            id: 13,
            name: 'Без категория продукт',
            category: null,
            isActive: true,
          ),
        ],
        variants: const {
          10: [
            CatalogVariant(
              id: 100,
              productId: 10,
              unitLabel: 'бутилка',
              unitValue: 0.5,
              isActive: true,
            ),
          ],
          11: [
            CatalogVariant(
              id: 110,
              productId: 11,
              unitLabel: 'бр',
              unitValue: null,
              isActive: true,
            ),
          ],
          12: [
            CatalogVariant(
              id: 120,
              productId: 12,
              unitLabel: 'кг',
              unitValue: null,
              isActive: true,
            ),
          ],
          13: [
            CatalogVariant(
              id: 130,
              productId: 13,
              unitLabel: 'бр',
              unitValue: null,
              isActive: true,
            ),
          ],
        },
      );
    }

    Future<void> pumpEntry(
      WidgetTester tester, {
      required SessionController session,
      required FakeEntryApi entryApi,
      required FakeProductsApi productsApi,
      EntryScreen screen = const EntryScreen(shiftId: 5),
    }) async {
      setLargeSurface(tester);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: ApiScope(
            adminUsersApi: FakeAdminUsersApi(),
            locationsApi: FakeLocationsApi(),
            shiftsApi: FakeShiftsApi(),
            productsApi: productsApi,
            entryApi: entryApi,
            child: MaterialApp(home: screen),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('loads the entry context and catalog from the API', (
      tester,
    ) async {
      final session = await volunteerSession();
      final entryApi = FakeEntryApi()..contextResponse = buildContext();
      final productsApi = buildProducts();

      await pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: productsApi,
      );

      expect(entryApi.contextCalls, 1);
      expect(entryApi.lastShiftId, 5);
      expect(entryApi.lastToken, 'vol-token');
      expect(productsApi.listCalls, 1);
      expect(find.text('Смяна в центъра'), findsOneWidget);
      expect(find.text('Продукти — 2 бр.'), findsOneWidget);
      expect(find.text('Шампоан'), findsOneWidget);
      expect(find.text('Сапун'), findsOneWidget);
    });

    testWidgets(
      'groups products by category and shows the uncategorised group',
      (tester) async {
        final session = await volunteerSession();
        final entryApi = FakeEntryApi()..contextResponse = buildContext();

        await pumpEntry(
          tester,
          session: session,
          entryApi: entryApi,
          productsApi: buildProducts(),
        );

        expect(find.widgetWithText(CategoryCard, 'Хигиена'), findsOneWidget);
        expect(find.widgetWithText(CategoryCard, 'Храна'), findsOneWidget);
        expect(
          find.widgetWithText(CategoryCard, 'Без категория'),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(CategoryCard, 'Храна'));
        await tester.pumpAndSettle();
        expect(find.text('Продукти — 1 бр.'), findsOneWidget);
        expect(find.text('Ориз'), findsOneWidget);
        expect(find.text('Шампоан'), findsNothing);
      },
    );

    testWidgets('shows no sample data when there is no shift id', (
      tester,
    ) async {
      final session = await volunteerSession();
      final entryApi = FakeEntryApi();
      final productsApi = FakeProductsApi();

      await pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: productsApi,
        screen: const EntryScreen(),
      );

      expect(
        find.text(
          'Изберете смяна от екрана с детайли, за да отчетете количества.',
        ),
        findsOneWidget,
      );
      expect(entryApi.contextCalls, 0);
      expect(productsApi.listCalls, 0);
    });

    testWidgets('requires an explicit location when several exist', (
      tester,
    ) async {
      final session = await volunteerSession();
      final entryApi =
          FakeEntryApi()
            ..contextResponse = buildContext(
              locations: const [
                Location(
                  id: 1,
                  name: 'Център',
                  address: 'ул. Витоша 1',
                  isActive: true,
                ),
                Location(
                  id: 2,
                  name: 'Студентски',
                  address: 'ул. Гущера 5',
                  isActive: true,
                ),
              ],
            );

      await pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: buildProducts(),
      );

      await tester.tap(find.byTooltip('Увеличи').first);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Изпрати'));
      await tester.pump();
      expect(find.text('Изберете пункт, преди да изпратите.'), findsOneWidget);
      expect(entryApi.submitCalls, 0);
      await settleSnackbar(tester);
    });

    testWidgets('submits entered quantities and preserves them on failure', (
      tester,
    ) async {
      final session = await volunteerSession();
      final entryApi = FakeEntryApi()..contextResponse = buildContext();

      await pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: buildProducts(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Изпрати'));
      await tester.pump();
      expect(find.text('Въведете поне едно количество.'), findsOneWidget);
      await settleSnackbar(tester);

      await tester.tap(find.byTooltip('Увеличи').first);
      await tester.pump();

      entryApi.submitError = buildError(409, 'ENTRY_WINDOW_CLOSED');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Изпрати'));
      await tester.pumpAndSettle();

      expect(entryApi.submitCalls, 1);
      expect(entryApi.lastLocationId, 1);
      expect(
        find.text('Времето за отчитане на тази смяна е изтекло.'),
        findsOneWidget,
      );

      // The entered quantity survives the failure and can be retried.
      await settleSnackbar(tester);
      expect(find.text('1'), findsWidgets);

      entryApi.submitError = null;
      entryApi.submitResponse = const [
        QuantityRecord(
          id: 1,
          shiftId: 5,
          locationId: 1,
          variantId: 100,
          quantity: 1,
        ),
      ];
      await tester.tap(find.widgetWithText(ElevatedButton, 'Изпрати'));
      await tester.pumpAndSettle();
      expect(find.text('Количествата са записани успешно.'), findsOneWidget);
      expect(find.text('Записано на сървъра'), findsOneWidget);
    });

    testWidgets('explains a required registration without auto-retrying', (
      tester,
    ) async {
      final session = await volunteerSession();
      final entryApi =
          FakeEntryApi()
            ..contextResponse = buildContext(
              canSubmit: false,
              submissionError: 'REGISTRATION_REQUIRED',
            );

      await pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: buildProducts(),
      );

      expect(
        find.text(
          'Трябва да сте записани за тази смяна, за да отчетете количества.',
        ),
        findsOneWidget,
      );
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Изпрати'),
      );
      expect(button.onPressed, isNull);
      expect(entryApi.contextCalls, 1);
      expect(entryApi.submitCalls, 0);
    });

    testWidgets('surfaces a catalog loading error with a retry action', (
      tester,
    ) async {
      final session = await volunteerSession();
      final entryApi = FakeEntryApi()..contextResponse = buildContext();
      final productsApi =
          buildProducts()..listError = buildError(500, 'INTERNAL_ERROR');

      await pumpEntry(
        tester,
        session: session,
        entryApi: entryApi,
        productsApi: productsApi,
      );

      expect(find.text('Повтори'), findsOneWidget);
      expect(find.text('Шампоан'), findsNothing);
    });
  });

  group('AppShell', () {
    testWidgets('switches between the two tabs', (tester) async {
      setLargeSurface(tester);
      await tester.pumpWidget(KupiIDariApp(locationsApi: FakeLocationsApi()));

      await tester.tap(find.text('Разгледай демо съдържанието'));
      await tester.pumpAndSettle();
      expect(find.text('Пунктове за събиране'), findsOneWidget);

      await tester.tap(find.text('Смени'));
      await tester.pumpAndSettle();
      expect(find.text('Всички смени'), findsOneWidget);

      expect(find.text('Отчитане'), findsNothing);
    });
  });

  group('SampleData', () {
    test('uses known shift statuses and keeps counts within capacity', () {
      final statuses = SampleData.shifts.map((shift) => shift.status).toSet();
      expect(statuses.difference(ShiftStatus.values.toSet()), isEmpty);

      for (final shift in SampleData.shifts) {
        expect(shift.registeredCount, isNotNull);
        expect(shift.capacity, isNotNull);
        expect(shift.registeredCount!, lessThanOrEqualTo(shift.capacity!));
        expect(shift.locationIds, isNotEmpty);
      }
    });

    test('every shift location exists in the location catalogue', () {
      final ids = SampleData.locations.map((location) => location.id).toSet();
      for (final shift in SampleData.shifts) {
        for (final id in shift.locationIds) {
          expect(ids, contains(id));
        }
      }
    });

    test('every product belongs to a known category', () {
      final ids = SampleData.categories.map((category) => category.id).toSet();
      for (final product in SampleData.products) {
        expect(ids, contains(product.categoryId));
      }
    });
  });
}
