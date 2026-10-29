import 'package:flutter/foundation.dart';

import '../../models/shift.dart';
import '../statuses.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// Typed access to the backend shift endpoints.
///
/// Endpoint paths are relative to [ApiClient.baseUrl] (which already ends in
/// `/api`). The backend contract (Phases 7–8) is strict: list/detail do not
/// include location IDs, registered counts, capacity or descriptions.
class ShiftsApi {
  ShiftsApi(this._client);

  final ApiClient _client;

  /// `GET /api/shifts` — authenticated list. Volunteers do not see DRAFT.
  ///
  /// [status] and [date] are passed as query parameters when provided.
  Future<List<Shift>> list({
    String? token,
    String? status,
    String? date,
  }) async {
    final query = <String, String>{};
    if (status != null && status.isNotEmpty) {
      query['status'] = status;
    }
    if (date != null && date.isNotEmpty) {
      query['date'] = date;
    }

    final path = query.isEmpty ? '/shifts' : '/shifts?${_encodeQuery(query)}';
    final payload = await _client.get(path, token: token);

    if (payload is! Map || payload['shifts'] is! List) {
      throw malformedResponse();
    }

    final records = payload['shifts'] as List;
    final shifts = <Shift>[];
    for (final record in records) {
      final shift = _parseListRecord(record);
      shifts.add(shift);
    }
    return shifts;
  }

  /// `GET /api/shifts/:shiftId` — authenticated detail with locations and
  /// [myRegistration].
  Future<ShiftDetail> getDetail(int shiftId, {String? token}) async {
    if (shiftId <= 0) {
      throw malformedResponse();
    }
    final payload = await _client.get('/shifts/$shiftId', token: token);
    return _parseDetail(payload);
  }

  /// `POST /api/shifts` — an admin creates a `DRAFT` shift together with its
  /// active location set.
  ///
  /// The backend returns the safe shift with its `locations`; the same parser
  /// as the detail endpoint is used because the shapes are compatible (the
  /// create response carries no `myRegistration`).
  Future<ShiftDetail> createShift({
    required String? title,
    required DateTime date,
    required String startTime,
    required String endTime,
    required List<int> locationIds,
    String? token,
  }) async {
    _validateLocationIds(locationIds);
    final body = <String, Object?>{
      'date': _formatDate(date),
      'startTime': startTime,
      'endTime': endTime,
      'locationIds': locationIds,
    };
    if (title != null) body['title'] = title;
    final payload = await _client.post('/shifts', body: body, token: token);
    return _parseDetail(payload);
  }

  /// `PATCH /api/shifts/:shiftId` — an admin updates the shift metadata while
  /// it is `DRAFT` or `OPEN`.
  ///
  /// The client always sends the full editable metadata so clearing the title
  /// is an explicit `null`.
  Future<Shift> updateShift(
    int shiftId, {
    required String? title,
    required DateTime date,
    required String startTime,
    required String endTime,
    String? token,
  }) async {
    if (shiftId <= 0) throw malformedResponse();
    final payload = await _client.patch(
      '/shifts/$shiftId',
      body: <String, Object?>{
        'title': title,
        'date': _formatDate(date),
        'startTime': startTime,
        'endTime': endTime,
      },
      token: token,
    );
    return _parseListRecord(payload);
  }

  /// `PATCH /api/shifts/:shiftId/status` — an admin performs one of the
  /// backend-supported lifecycle transitions.
  Future<Shift> setShiftStatus(
    int shiftId,
    String status, {
    String? token,
  }) async {
    if (shiftId <= 0) throw malformedResponse();
    if (!const ['OPEN', 'CLOSED', 'CANCELLED'].contains(status)) {
      throw malformedResponse();
    }
    final payload = await _client.patch(
      '/shifts/$shiftId/status',
      body: <String, Object?>{'status': status},
      token: token,
    );
    return _parseListRecord(payload);
  }

  /// `PUT /api/shifts/:shiftId/locations` — an admin atomically replaces the
  /// complete location set while the shift is `DRAFT` or `OPEN`.
  Future<List<ShiftDetailLocation>> replaceShiftLocations(
    int shiftId, {
    required List<int> locationIds,
    String? token,
  }) async {
    if (shiftId <= 0) throw malformedResponse();
    _validateLocationIds(locationIds);
    final payload = await _client.put(
      '/shifts/$shiftId/locations',
      body: <String, Object?>{'locationIds': locationIds},
      token: token,
    );
    if (payload is! Map || payload['locations'] is! List) {
      throw malformedResponse();
    }
    final locations = <ShiftDetailLocation>[];
    for (final record in payload['locations'] as List) {
      locations.add(_parseDetailLocation(record));
    }
    return List<ShiftDetailLocation>.unmodifiable(locations);
  }

  /// `POST /api/shifts/:shiftId/registrations` — a volunteer registers for an
  /// OPEN shift.
  ///
  /// The backend accepts no request body ([body] is omitted entirely so no
  /// `Content-Type` is sent). Returns the safe registration on `201` (new) or
  /// `200` (reactivation of a previously cancelled registration); both are
  /// indistinguishable here and parsed identically.
  Future<RegistrationResult> registerSelf(int shiftId, {String? token}) async {
    if (shiftId <= 0) {
      throw malformedResponse();
    }
    final payload = await _client.post(
      '/shifts/$shiftId/registrations',
      token: token,
    );
    return _parseRegistrationResult(payload);
  }

  /// `PATCH /api/shifts/:shiftId/registrations/:registrationId/cancel` — the
  /// caller cancels their own registration for an OPEN shift.
  ///
  /// The backend accepts no request body, so none is sent. The registration id
  /// is known only when it was observed in a confirmed registration response;
  /// the shift detail never exposes it.
  ///
  /// The backend answers `200` with the safe registration (also when the
  /// registration was already cancelled), `404` when the registration does not
  /// exist or belongs to somebody else and `409` when the shift is no longer
  /// open.
  Future<RegistrationResult> cancelSelf(
    int shiftId,
    int registrationId, {
    String? token,
  }) async {
    if (shiftId <= 0 || registrationId <= 0) {
      throw malformedResponse();
    }
    final payload = await _client.patch(
      '/shifts/$shiftId/registrations/$registrationId/cancel',
      token: token,
    );
    return _parseRegistrationResult(payload);
  }

  static RegistrationResult _parseRegistrationResult(Object? payload) {
    if (payload is! Map) throw malformedResponse();

    final id = payload['id'];
    final shiftId = payload['shiftId'];
    final userId = payload['userId'];
    final status = payload['status'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (shiftId is! int || shiftId <= 0) throw malformedResponse();
    if (userId is! int || userId <= 0) throw malformedResponse();
    if (status is! String || status.isEmpty) throw malformedResponse();

    return RegistrationResult(
      id: id,
      shiftId: shiftId,
      userId: userId,
      status: status,
    );
  }

  static Shift _parseListRecord(Object? record) {
    if (record is! Map) throw malformedResponse();

    final id = record['id'];
    final title = record['title'];
    final date = record['date'];
    final startTime = record['startTime'];
    final endTime = record['endTime'];
    final status = record['status'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (title != null && title is! String) throw malformedResponse();
    if (date is! String || date.isEmpty) throw malformedResponse();
    if (startTime is! String || startTime.isEmpty) throw malformedResponse();
    if (endTime is! String || endTime.isEmpty) throw malformedResponse();
    if (status is! String || status.isEmpty) throw malformedResponse();

    final parsedDate = _parseDate(date);
    final uiStatus = _mapStatus(status);

    // The backend list does not provide locationIds, registered counts,
    // capacity or description. The counts stay unknown (`null`) so no
    // capacity/registration claim is invented.
    return Shift(
      id: id,
      title: title ?? '',
      description: '',
      date: parsedDate,
      startTime: startTime,
      endTime: endTime,
      locationIds: const [],
      status: uiStatus,
    );
  }

  static ShiftDetail _parseDetail(Object? payload) {
    if (payload is! Map) throw malformedResponse();

    final id = payload['id'];
    final title = payload['title'];
    final date = payload['date'];
    final startTime = payload['startTime'];
    final endTime = payload['endTime'];
    final status = payload['status'];
    final locations = payload['locations'];
    final myRegistration = payload['myRegistration'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (title != null && title is! String) throw malformedResponse();
    if (date is! String || date.isEmpty) throw malformedResponse();
    if (startTime is! String || startTime.isEmpty) throw malformedResponse();
    if (endTime is! String || endTime.isEmpty) throw malformedResponse();
    if (status is! String || status.isEmpty) throw malformedResponse();
    if (locations is! List) throw malformedResponse();

    final parsedDate = _parseDate(date);
    final uiStatus = _mapStatus(status);

    final detailLocations = <ShiftDetailLocation>[];
    for (final record in locations) {
      detailLocations.add(_parseDetailLocation(record));
    }

    ShiftRegistration? registration;
    if (myRegistration == null) {
      registration = null;
    } else if (myRegistration is Map) {
      final regStatus = myRegistration['status'];
      if (regStatus is! String || regStatus.isEmpty) {
        throw malformedResponse();
      }
      registration = ShiftRegistration(status: regStatus);
    } else {
      throw malformedResponse();
    }

    // Capacity/count/description are not provided by the backend; the counts
    // stay unknown (`null`) instead of being invented.
    final shift = Shift(
      id: id,
      title: title ?? '',
      description: '',
      date: parsedDate,
      startTime: startTime,
      endTime: endTime,
      locationIds: detailLocations.map((l) => l.id).toList(),
      status: uiStatus,
    );

    return ShiftDetail(
      shift: shift,
      locations: detailLocations,
      myRegistration: registration,
    );
  }

  static ShiftDetailLocation _parseDetailLocation(Object? record) {
    if (record is! Map) throw malformedResponse();
    final id = record['id'];
    final name = record['name'];
    final address = record['address'];
    final isActive = record['isActive'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (name is! String || name.isEmpty) throw malformedResponse();
    if (address is! String) throw malformedResponse();
    if (isActive is! bool) throw malformedResponse();

    return ShiftDetailLocation(
      id: id,
      name: name,
      address: address,
      isActive: isActive,
    );
  }

  static DateTime _parseDate(String value) {
    final parts = value.split('-');
    if (parts.length != 3) throw malformedResponse();
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) {
      throw malformedResponse();
    }
    // Validate calendar date
    final dt = DateTime(year, month, day);
    if (dt.year != year || dt.month != month || dt.day != day) {
      throw malformedResponse();
    }
    return dt;
  }

  /// Centralized mapping from backend status to UI status.
  ///
  /// Backend: DRAFT/OPEN/CLOSED/CANCELLED
  /// UI: upcoming/available/almostFull/full/inProcess/completed/archived
  ///
  /// Counts/capacity are not available from backend, so we cannot determine
  /// almostFull/full accurately. We map conservatively to avoid implying
  /// known capacity.
  static ShiftStatus _mapStatus(String status) {
    switch (status) {
      case 'OPEN':
        // Open for registration; without counts we map to available
        return ShiftStatus.available;
      case 'CLOSED':
        return ShiftStatus.completed;
      case 'CANCELLED':
        return ShiftStatus.archived;
      case 'DRAFT':
        // DRAFT is hidden from volunteers by backend; staff may see it.
        return ShiftStatus.draft;
      default:
        // Unknown status - fall back to upcoming rather than guessing
        return ShiftStatus.upcoming;
    }
  }

  static String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static void _validateLocationIds(List<int> locationIds) {
    if (locationIds.isEmpty || locationIds.length > 100) {
      throw malformedResponse();
    }
    final seen = <int>{};
    for (final id in locationIds) {
      if (id <= 0 || !seen.add(id)) throw malformedResponse();
    }
  }

  static String _encodeQuery(Map<String, String> query) {
    final parts = <String>[];
    query.forEach((key, value) {
      parts.add(
        '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}',
      );
    });
    return parts.join('&');
  }

  static ApiException malformedResponse() => const ApiException(
    code: 'UNEXPECTED_RESPONSE',
    message: 'The server returned an unexpected response.',
  );
}

@immutable
class ShiftDetail {
  const ShiftDetail({
    required this.shift,
    required this.locations,
    required this.myRegistration,
  });

  final Shift shift;
  final List<ShiftDetailLocation> locations;
  final ShiftRegistration? myRegistration;
}

@immutable
class ShiftDetailLocation {
  const ShiftDetailLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.isActive,
  });

  final int id;
  final String name;
  final String address;
  final bool isActive;
}

@immutable
class ShiftRegistration {
  const ShiftRegistration({required this.status});

  final String status;
}

/// The safe registration returned by `POST /api/shifts/:shiftId/registrations`.
///
/// Full safe shape `{ id, shiftId, userId, status }`. This is deliberately
/// separate from [ShiftRegistration] (which is the status-only shape embedded
/// in a shift detail's `myRegistration`).
@immutable
class RegistrationResult {
  const RegistrationResult({
    required this.id,
    required this.shiftId,
    required this.userId,
    required this.status,
  });

  final int id;
  final int shiftId;
  final int userId;
  final String status;
}
