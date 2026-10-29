import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kupi_i_dari/core/api/api_exception.dart';
import 'package:kupi_i_dari/core/api/api_scope.dart';
import 'package:kupi_i_dari/core/api/shifts_api.dart';
import 'package:kupi_i_dari/core/session/registration_scope.dart';
import 'package:kupi_i_dari/core/session/registration_state_controller.dart';
import 'package:kupi_i_dari/core/session/session_controller.dart';
import 'package:kupi_i_dari/core/session/session_scope.dart';
import 'package:kupi_i_dari/core/statuses.dart';
import 'package:kupi_i_dari/models/entry_context.dart';
import 'package:kupi_i_dari/models/shift.dart';
import 'package:kupi_i_dari/screens/entry_screen.dart';
import 'package:kupi_i_dari/screens/shift_detail_screen.dart';

import 'fakes.dart';

/// Phase 20 — shift registration against the real backend contract
/// (`POST /api/shifts/:shiftId/registrations`).

final Shift openShift = Shift(
  id: 1,
  title: 'Сутрешна смяна',
  description: '',
  date: DateTime(2026, 5, 1),
  startTime: '09:00:00',
  endTime: '13:00:00',
  locationIds: const [],
  status: ShiftStatus.available,
);
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

Future<SessionController> volunteerSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.identifyVolunteer(
    firstName: 'Иван',
    lastName: 'Петров',
    phone: '0888123456',
  );
  return controller;
}

Future<SessionController> staffSession() async {
  final controller = SessionController(authApi: FakeAuthApi());
  await controller.signInStaff(phone: '0888123456', password: 'secret123');
  return controller;
}

void main() {
  group('ShiftDetailScreen registration', () {
    FakeShiftsApi shiftsApi({String? myRegistrationStatus}) {
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

    Future<void> pumpDetail(
      WidgetTester tester, {
      required SessionController session,
      required FakeShiftsApi shiftsApi,
      Shift? shift,
      FakeEntryApi? entryApi,
      RegistrationStateController? registrationState,
    }) async {
      setLargeSurface(tester);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: RegistrationScope(
            controller: registrationState ?? RegistrationStateController(),
            child: ApiScope(
              adminUsersApi: FakeAdminUsersApi(),
              locationsApi: FakeLocationsApi(),
              shiftsApi: shiftsApi,
              productsApi: FakeProductsApi(),
              entryApi: entryApi ?? FakeEntryApi(),
              child: MaterialApp(
                home: ShiftDetailScreen(shift: shift ?? openShift),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('registers the volunteer and confirms the backend response', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.registrationResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'REGISTERED',
      );

      await pumpDetail(tester, session: session, shiftsApi: api);

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

      // The shift detail is reconciled with the server after the confirmation.
      expect(api.detailCalls, greaterThan(1));
    });

    testWidgets('keeps a confirmed registration when the detail is stale', (
      tester,
    ) async {
      final session = await volunteerSession();
      // The refreshed detail never reports a registration.
      final api = shiftsApi();
      api.registrationResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'REGISTERED',
      );

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();
      await settleSnackbar(tester);

      expect(api.detailCalls, greaterThan(1));
      expect(find.text('Записахте се за тази смяна.'), findsOneWidget);
    });

    testWidgets('reconciles an ALREADY_REGISTERED response', (tester) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.registrationError = buildError(409, 'ALREADY_REGISTERED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(find.text('Вече сте записани за тази смяна.'), findsOneWidget);
      expect(find.text('Записахте се успешно.'), findsNothing);

      await settleSnackbar(tester);
      expect(api.detailCalls, greaterThan(1));
    });

    testWidgets('shows the registered banner after a reconciliation', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.registrationError = buildError(409, 'ALREADY_REGISTERED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      // The server reports the registration on the next detail read.
      api.detailResponses[openShift.id] = ShiftDetail(
        shift: openShift,
        locations: const [],
        myRegistration: const ShiftRegistration(status: 'REGISTERED'),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();
      await settleSnackbar(tester);

      expect(find.text('Записахте се за тази смяна.'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsNothing);
    });

    testWidgets('shows a registration-specific message for SHIFT_NOT_OPEN', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.registrationError = buildError(409, 'SHIFT_NOT_OPEN');

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(
        find.text('Записването е възможно само докато смяната е отворена.'),
        findsOneWidget,
      );
      // The quantity-entry wording stays untouched.
      expect(find.text('Смяната не е отворена за отчитане.'), findsNothing);
      expect(find.text('Записахте се успешно.'), findsNothing);
    });

    testWidgets('shows Bulgarian messages for backend failures', (
      tester,
    ) async {
      const cases = <(int, String, String)>[
        (404, 'NOT_FOUND', 'Търсеният ресурс не е намерен.'),
        (
          403,
          'ACCOUNT_DISABLED',
          'Този профил е деактивиран. Обърнете се към организатор.',
        ),
        (
          429,
          'RATE_LIMITED',
          'Твърде много опити. Изчакайте малко и опитайте отново.',
        ),
        (400, 'VALIDATION_ERROR', 'Проверете въведените данни.'),
        (403, 'FORBIDDEN', 'Нямате права да извършите това действие.'),
        (
          0,
          ApiException.networkErrorCode,
          'Няма връзка със сървъра. Проверете интернет връзката.',
        ),
      ];

      for (final testCase in cases) {
        final session = await volunteerSession();
        final api = shiftsApi();
        api.registrationError = buildError(testCase.$1, testCase.$2);

        await pumpDetail(tester, session: session, shiftsApi: api);

        await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
        await tester.pumpAndSettle();

        expect(
          find.text(testCase.$3),
          findsOneWidget,
          reason: 'code ${testCase.$2} must be shown in Bulgarian',
        );
        expect(find.text('Записахте се успешно.'), findsNothing);

        await settleSnackbar(tester);
      }
    });

    testWidgets('clears the session on an unauthorized response', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.registrationError = buildError(401, 'UNAUTHORIZED');

      await pumpDetail(tester, session: session, shiftsApi: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(session.isAuthenticated, isFalse);
      expect(find.text('Записахте се успешно.'), findsNothing);
    });

    testWidgets('keeps the register action disabled while pending', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      final gate = api.setRegistrationPending();
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

      // The action stays visible but disabled, so a second tap is a no-op.
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

    testWidgets('hides the register action for staff and anonymous users', (
      tester,
    ) async {
      final staff = await staffSession();
      await pumpDetail(tester, session: staff, shiftsApi: shiftsApi());
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsNothing);

      final anonymous = SessionController(authApi: FakeAuthApi());
      await pumpDetail(tester, session: anonymous, shiftsApi: shiftsApi());
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsNothing);
    });

    testWidgets('hides the register action for non-open shifts', (
      tester,
    ) async {
      final session = await volunteerSession();
      for (final status in const [
        ShiftStatus.upcoming,
        ShiftStatus.almostFull,
        ShiftStatus.full,
        ShiftStatus.inProcess,
        ShiftStatus.completed,
        ShiftStatus.archived,
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

    testWidgets('keeps the quantity-entry navigation after registering', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.registrationResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'REGISTERED',
      );
      final entryApi =
          FakeEntryApi()
            ..contextResponse = EntryContext(
              shift: openShift,
              canSubmit: true,
              submissionError: null,
              entryWindow: const EntryWindow(
                opensAt: '2026-05-01T09:00:00+03:00',
                closesAt: '2026-05-01T13:30:00+03:00',
              ),
              locations: const [],
              quantities: const [],
            );

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: api,
        entryApi: entryApi,
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();
      await settleSnackbar(tester);

      await tester.tap(find.text('Отчитане на количества'));
      await tester.pumpAndSettle();

      expect(find.byType(EntryScreen), findsOneWidget);
      expect(entryApi.lastShiftId, 1);
    });
  });

  group('ShiftDetailScreen registration state', () {
    FakeShiftsApi shiftsApi({String? myRegistrationStatus}) {
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

    Future<void> pumpDetail(
      WidgetTester tester, {
      required SessionController session,
      required FakeShiftsApi shiftsApi,
      required RegistrationStateController state,
    }) async {
      setLargeSurface(tester);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: RegistrationScope(
            controller: state,
            child: ApiScope(
              adminUsersApi: FakeAdminUsersApi(),
              locationsApi: FakeLocationsApi(),
              shiftsApi: shiftsApi,
              productsApi: FakeProductsApi(),
              entryApi: FakeEntryApi(),
              child: MaterialApp(home: ShiftDetailScreen(shift: openShift)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('publishes a confirmed registration', (tester) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.registrationResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'REGISTERED',
      );
      final state = RegistrationStateController();

      await pumpDetail(tester, session: session, shiftsApi: api, state: state);

      expect(state.isRegistered(1, userId: 1), isFalse);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Запиши се'));
      await tester.pumpAndSettle();

      expect(state.statusFor(1, userId: 1), 'REGISTERED');
      expect(state.isRegistered(1, userId: 1), isTrue);
    });

    testWidgets('publishes the registration reported by the detail', (
      tester,
    ) async {
      final session = await volunteerSession();
      final state = RegistrationStateController();

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: shiftsApi(myRegistrationStatus: 'REGISTERED'),
        state: state,
      );

      expect(state.statusFor(1, userId: 1), 'REGISTERED');
    });

    testWidgets('clears a known state when the detail reports none', (
      tester,
    ) async {
      final session = await volunteerSession();
      final state =
          RegistrationStateController()
            ..setStatus(userId: 1, shiftId: 1, status: 'REGISTERED');

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: shiftsApi(),
        state: state,
      );

      expect(state.statusFor(1, userId: 1), isNull);
      expect(state.isRegistered(1, userId: 1), isFalse);
    });

    testWidgets('never publishes for an anonymous session', (tester) async {
      final state = RegistrationStateController();

      await pumpDetail(
        tester,
        session: SessionController(authApi: FakeAuthApi()),
        shiftsApi: shiftsApi(myRegistrationStatus: 'REGISTERED'),
        state: state,
      );

      expect(state.statusFor(1, userId: 1), isNull);
      expect(state.isRegistered(1, userId: null), isFalse);
    });
  });

  group('ShiftDetailScreen registration cancellation', () {
    const cancelLabel = 'Отказ от записа';
    const mutedNote =
        'Този запис е направен в предишна сесия и не може да бъде отменен от '
        'приложението.';

    FakeShiftsApi shiftsApi({
      String? myRegistrationStatus = 'REGISTERED',
      Shift? shift,
    }) {
      final api = FakeShiftsApi();
      api.detailResponses[openShift.id] = ShiftDetail(
        shift: shift ?? openShift,
        locations: const [],
        myRegistration:
            myRegistrationStatus == null
                ? null
                : ShiftRegistration(status: myRegistrationStatus),
      );
      api.cancelResponse = const RegistrationResult(
        id: 9,
        shiftId: 1,
        userId: 1,
        status: 'CANCELLED',
      );
      return api;
    }

    Future<void> pumpDetail(
      WidgetTester tester, {
      required SessionController session,
      required FakeShiftsApi shiftsApi,
      RegistrationStateController? registrationState,
      Shift? shift,
    }) async {
      setLargeSurface(tester);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: RegistrationScope(
            controller: registrationState ?? RegistrationStateController(),
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
        ),
      );
      await tester.pumpAndSettle();
    }

    /// A volunteer that registered during the current app session: the shared
    /// state knows the status and the registration id.
    RegistrationStateController registeredState() {
      return RegistrationStateController()..setStatus(
        userId: 1,
        shiftId: 1,
        status: 'REGISTERED',
        registrationId: 9,
      );
    }

    Future<void> confirmCancellation(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(OutlinedButton, cancelLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, откажи'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers the cancel action for a registered volunteer', (
      tester,
    ) async {
      final session = await volunteerSession();

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: shiftsApi(),
        registrationState: registeredState(),
      );

      expect(find.text('Записахте се за тази смяна.'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, cancelLabel), findsOneWidget);
    });

    testWidgets('hides the cancel action for staff and anonymous users', (
      tester,
    ) async {
      final staff = await staffSession();
      await pumpDetail(
        tester,
        session: staff,
        shiftsApi: shiftsApi(),
        registrationState: registeredState(),
      );
      expect(find.widgetWithText(OutlinedButton, cancelLabel), findsNothing);

      final anonymous = SessionController(authApi: FakeAuthApi());
      await pumpDetail(
        tester,
        session: anonymous,
        shiftsApi: shiftsApi(),
        registrationState: registeredState(),
      );
      expect(find.widgetWithText(OutlinedButton, cancelLabel), findsNothing);
    });

    testWidgets('hides the cancel action for a non-open shift', (tester) async {
      final session = await volunteerSession();
      final shift = Shift(
        id: 1,
        title: 'Смяна',
        description: '',
        date: DateTime(2026, 5, 1),
        startTime: '09:00:00',
        endTime: '13:00:00',
        locationIds: const [],
        status: ShiftStatus.completed,
      );

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: shiftsApi(shift: shift),
        registrationState: registeredState(),
        shift: shift,
      );

      expect(find.widgetWithText(OutlinedButton, cancelLabel), findsNothing);
      expect(find.text(mutedNote), findsNothing);
    });

    testWidgets('explains an unknown registration id instead of cancelling', (
      tester,
    ) async {
      final session = await volunteerSession();
      final state =
          RegistrationStateController()
            ..setStatus(userId: 1, shiftId: 1, status: 'REGISTERED');

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: shiftsApi(),
        registrationState: state,
      );

      expect(find.widgetWithText(OutlinedButton, cancelLabel), findsNothing);
      expect(find.text(mutedNote), findsOneWidget);
    });

    testWidgets('cancels the registration after the confirmation', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      final state = registeredState();

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: api,
        registrationState: state,
      );

      await confirmCancellation(tester);

      expect(api.cancelCalls, 1);
      expect(api.lastCancelShiftId, 1);
      expect(api.lastCancelRegistrationId, 9);
      expect(api.lastCancelToken, 'vol-token');
      expect(find.text('Отказахте записа си за тази смяна.'), findsOneWidget);

      // The confirmed cancellation is published to the shared state.
      expect(state.statusFor(1, userId: 1), 'CANCELLED');
      expect(state.isRegistered(1, userId: 1), isFalse);
      expect(state.registrationIdFor(1, userId: 1), 9);

      await settleSnackbar(tester);
      expect(find.text('Записахте се за тази смяна.'), findsNothing);
      // The shift is still open, so the volunteer can register again.
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, cancelLabel), findsNothing);
    });

    testWidgets('dismisses the confirmation without a request', (tester) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      final state = registeredState();

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: api,
        registrationState: state,
      );

      await tester.tap(find.widgetWithText(OutlinedButton, cancelLabel));
      await tester.pumpAndSettle();
      expect(find.text('Да, откажи'), findsOneWidget);

      await tester.tap(find.text('Не, оставам'));
      await tester.pumpAndSettle();

      expect(api.cancelCalls, 0);
      expect(find.text('Записахте се за тази смяна.'), findsOneWidget);
      expect(state.statusFor(1, userId: 1), 'REGISTERED');
    });

    testWidgets('keeps the cancel action disabled while pending', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      final gate = api.setCancelPending();

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: api,
        registrationState: registeredState(),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, cancelLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Да, откажи'));
      await tester.pump();

      expect(api.cancelCalls, 1);

      // The action stays visible but disabled, so a second tap is a no-op.
      final pendingButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, cancelLabel),
      );
      expect(pendingButton.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      await tester.tap(find.widgetWithText(OutlinedButton, cancelLabel));
      await tester.pump();
      expect(api.cancelCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Отказахте записа си за тази смяна.'), findsOneWidget);
    });

    testWidgets('keeps the registration when the cancellation fails', (
      tester,
    ) async {
      const cases = <(int, String, String)>[
        (
          409,
          'SHIFT_NOT_OPEN',
          'Отказът на записа е възможен само докато смяната е отворена.',
        ),
        (
          404,
          'NOT_FOUND',
          'Записът не е намерен. Възможно е вече да е отменен.',
        ),
        (
          429,
          'RATE_LIMITED',
          'Твърде много опити. Изчакайте малко и опитайте отново.',
        ),
        (403, 'FORBIDDEN', 'Нямате права да извършите това действие.'),
      ];

      for (final testCase in cases) {
        final session = await volunteerSession();
        final api = shiftsApi();
        api.cancelError = buildError(testCase.$1, testCase.$2);
        final state = registeredState();

        await pumpDetail(
          tester,
          session: session,
          shiftsApi: api,
          registrationState: state,
        );

        await confirmCancellation(tester);

        expect(
          find.text(testCase.$3),
          findsOneWidget,
          reason: 'code ${testCase.$2} must be shown in Bulgarian',
        );
        expect(find.text('Отказахте записа си за тази смяна.'), findsNothing);
        // The shared state is never changed optimistically.
        expect(state.statusFor(1, userId: 1), 'REGISTERED');
        expect(state.isRegistered(1, userId: 1), isTrue);
        expect(find.text('Записахте се за тази смяна.'), findsOneWidget);

        await settleSnackbar(tester);
      }
    });

    testWidgets('reconciles the detail after a failed cancellation', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.cancelError = buildError(409, 'SHIFT_NOT_OPEN');

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: api,
        registrationState: registeredState(),
      );

      final detailCallsBefore = api.detailCalls;

      await confirmCancellation(tester);

      expect(api.detailCalls, greaterThan(detailCallsBefore));
    });

    testWidgets('clears the session on an unauthorized cancellation', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      api.cancelError = buildError(401, 'UNAUTHORIZED');

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: api,
        registrationState: registeredState(),
      );

      await confirmCancellation(tester);

      expect(session.isAuthenticated, isFalse);
      expect(find.text('Отказахте записа си за тази смяна.'), findsNothing);
    });

    testWidgets('a stale detail response cannot resurrect the registration', (
      tester,
    ) async {
      final session = await volunteerSession();
      final api = shiftsApi();
      final state = registeredState();

      await pumpDetail(
        tester,
        session: session,
        shiftsApi: api,
        registrationState: state,
      );

      await confirmCancellation(tester);

      // The detail still reports the old registration, but the confirmed
      // cancellation wins.
      expect(api.detailCalls, greaterThan(1));
      expect(find.text('Записахте се за тази смяна.'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Запиши се'), findsOneWidget);
      expect(state.statusFor(1, userId: 1), 'CANCELLED');
      expect(state.isRegistered(1, userId: 1), isFalse);
    });
  });
}
