import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/session/registration_state_controller.dart';

/// Phase 21 — the shared, in-memory registration state cache.
void main() {
  group('RegistrationStateController', () {
    test('knows nothing before a backend response is observed', () {
      final controller = RegistrationStateController();

      expect(controller.statusFor(1, userId: 1), isNull);
      expect(controller.isRegistered(1, userId: 1), isFalse);
      expect(controller.statusFor(1, userId: null), isNull);
      expect(controller.isRegistered(1, userId: null), isFalse);
    });

    test('stores a confirmed status per user and shift', () {
      final controller = RegistrationStateController();

      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');
      controller.setStatus(userId: 1, shiftId: 11, status: 'CANCELLED');

      expect(controller.statusFor(10, userId: 1), 'REGISTERED');
      expect(controller.statusFor(11, userId: 1), 'CANCELLED');
      expect(controller.isRegistered(10, userId: 1), isTrue);
    });

    test('only an exact REGISTERED counts as registered', () {
      final controller = RegistrationStateController();

      controller.setStatus(userId: 1, shiftId: 10, status: 'CANCELLED');
      expect(controller.isRegistered(10, userId: 1), isFalse);

      controller.setStatus(userId: 1, shiftId: 10, status: 'registered');
      expect(controller.isRegistered(10, userId: 1), isFalse);
    });

    test('never leaks a state into another user', () {
      final controller = RegistrationStateController();

      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');

      expect(controller.statusFor(10, userId: 2), isNull);
      expect(controller.isRegistered(10, userId: 2), isFalse);
      expect(controller.statusFor(10, userId: null), isNull);
    });

    test('a null status removes the known state', () {
      final controller = RegistrationStateController();

      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');
      controller.setStatus(userId: 1, shiftId: 10, status: null);

      expect(controller.statusFor(10, userId: 1), isNull);
      expect(controller.isRegistered(10, userId: 1), isFalse);
    });

    test('notifies only when the state really changes', () {
      final controller = RegistrationStateController();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');
      expect(notifications, 1);

      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');
      expect(notifications, 1);

      controller.setStatus(userId: 1, shiftId: 10, status: 'CANCELLED');
      expect(notifications, 2);

      controller.setStatus(userId: 1, shiftId: 10, status: null);
      expect(notifications, 3);

      // Nothing is known for that user, so nothing changes.
      controller.setStatus(userId: 1, shiftId: 10, status: null);
      expect(notifications, 3);
    });

    test('clear removes every known state', () {
      final controller = RegistrationStateController();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');
      controller.setStatus(userId: 2, shiftId: 11, status: 'REGISTERED');

      controller.clear();

      expect(controller.statusFor(10, userId: 1), isNull);
      expect(controller.statusFor(11, userId: 2), isNull);
      expect(notifications, 3);

      // Clearing an empty state notifies nobody.
      controller.clear();
      expect(notifications, 3);
    });

    test('knows no registration id before one is observed', () {
      final controller = RegistrationStateController();

      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');

      expect(controller.registrationIdFor(10, userId: 1), isNull);
      expect(controller.registrationIdFor(10, userId: null), isNull);
    });

    test('stores the registration id of a confirmed registration', () {
      final controller = RegistrationStateController();

      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 42,
      );

      expect(controller.statusFor(10, userId: 1), 'REGISTERED');
      expect(controller.registrationIdFor(10, userId: 1), 42);
      expect(controller.isRegistered(10, userId: 1), isTrue);
    });

    test('keeps a known id when a status arrives without one', () {
      final controller = RegistrationStateController();

      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 42,
      );
      // A shift detail reports the status alone.
      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');

      expect(controller.registrationIdFor(10, userId: 1), 42);
      expect(controller.statusFor(10, userId: 1), 'REGISTERED');
    });

    test('keeps a known id when the registration is cancelled', () {
      final controller = RegistrationStateController();

      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 42,
      );
      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'CANCELLED',
        registrationId: 42,
      );

      expect(controller.statusFor(10, userId: 1), 'CANCELLED');
      expect(controller.isRegistered(10, userId: 1), isFalse);
      expect(controller.registrationIdFor(10, userId: 1), 42);
    });

    test('a null status removes the status and the id', () {
      final controller = RegistrationStateController();

      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 42,
      );
      controller.setStatus(userId: 1, shiftId: 10, status: null);

      expect(controller.statusFor(10, userId: 1), isNull);
      expect(controller.registrationIdFor(10, userId: 1), isNull);
    });

    test('notifies when the id changes and not when it does not', () {
      final controller = RegistrationStateController();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 42,
      );
      expect(notifications, 1);

      // The same status and the same id change nothing.
      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 42,
      );
      expect(notifications, 1);

      // A status without an id keeps the known id, so nothing changes.
      controller.setStatus(userId: 1, shiftId: 10, status: 'REGISTERED');
      expect(notifications, 1);

      // A new id is a real change.
      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 43,
      );
      expect(notifications, 2);
    });

    test('never leaks a registration id into another user', () {
      final controller = RegistrationStateController();

      controller.setStatus(
        userId: 1,
        shiftId: 10,
        status: 'REGISTERED',
        registrationId: 42,
      );

      expect(controller.registrationIdFor(10, userId: 2), isNull);
      expect(controller.registrationIdFor(10, userId: null), isNull);
      expect(controller.statusFor(10, userId: 2), isNull);
    });
  });
}
