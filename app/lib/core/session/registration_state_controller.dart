import 'package:flutter/foundation.dart';

/// In-memory cache of the caller's own shift registrations.
///
/// Only states that were actually observed in confirmed backend responses are
/// stored: the `myRegistration.status` of `GET /api/shifts/:shiftId` and the
/// `status` of a confirmed `POST /api/shifts/:shiftId/registrations`. Nothing
/// is fetched here, nothing is persisted and no sample data is used.
///
/// The backend list endpoint does not expose `myRegistration`, so the state is
/// intentionally partial: only shifts whose registration state was observed
/// during the current app session are known.
///
/// The registration id is stored next to the status whenever a confirmed
/// response provides it. The id is required to cancel a registration and the
/// backend only returns it in the registration response, so it is known only
/// for registrations made during the current app session.
///
/// State is keyed by the backend user id first, so one volunteer's
/// registrations can never leak into another user's view.
class RegistrationStateController extends ChangeNotifier {
  /// user id -> shift id -> known registration state.
  final Map<int, Map<int, _RegistrationState>> _byUser =
      <int, Map<int, _RegistrationState>>{};

  /// The known registration status of [shiftId] for [userId].
  ///
  /// Returns `null` when nothing is known about that registration, including
  /// when there is no [userId] (anonymous session).
  String? statusFor(int shiftId, {required int? userId}) {
    if (userId == null) return null;
    return _byUser[userId]?[shiftId]?.status;
  }

  /// True only when the stored status is exactly `REGISTERED`.
  ///
  /// A `CANCELLED` registration is not a registration: the backend allows the
  /// volunteer to register again, which reactivates the cancelled row.
  bool isRegistered(int shiftId, {required int? userId}) =>
      statusFor(shiftId, userId: userId) == 'REGISTERED';

  /// The known registration id of [shiftId] for [userId].
  ///
  /// The id is known only when a confirmed registration response provided it.
  /// It is `null` for a registration that was observed through a shift detail
  /// (the backend reports the status only) and for an anonymous session.
  int? registrationIdFor(int shiftId, {required int? userId}) {
    if (userId == null) return null;
    return _byUser[userId]?[shiftId]?.registrationId;
  }

  /// Stores [status] for the given user and shift.
  ///
  /// A `null` status removes the known state for that user and shift,
  /// including its registration id.
  ///
  /// [registrationId] is optional: an observation that does not carry an id
  /// (a shift detail) never erases an id that was learned from a confirmed
  /// registration response.
  ///
  /// Listeners are notified only when the stored state actually changes.
  void setStatus({
    required int userId,
    required int shiftId,
    required String? status,
    int? registrationId,
  }) {
    final existing = _byUser[userId]?[shiftId];

    if (status == null) {
      if (existing == null) return;
      final user = _byUser[userId];
      if (user == null) return;
      user.remove(shiftId);
      if (user.isEmpty) _byUser.remove(userId);
      notifyListeners();
      return;
    }

    // An observation without an id keeps a previously known id.
    final effectiveId = registrationId ?? existing?.registrationId;
    if (existing != null &&
        existing.status == status &&
        existing.registrationId == effectiveId) {
      return;
    }

    (_byUser[userId] ??= <int, _RegistrationState>{})[shiftId] =
        _RegistrationState(status: status, registrationId: effectiveId);
    notifyListeners();
  }

  /// Removes every known registration state.
  void clear() {
    if (_byUser.isEmpty) return;
    _byUser.clear();
    notifyListeners();
  }
}

/// The known state of a single registration.
@immutable
class _RegistrationState {
  const _RegistrationState({
    required this.status,
    required this.registrationId,
  });

  final String status;
  final int? registrationId;
}
