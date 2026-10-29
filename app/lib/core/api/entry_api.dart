import '../../models/entry_context.dart';
import '../../models/location.dart';
import '../../models/shift.dart';
import '../statuses.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// Typed access to the backend shift entry endpoints (Phase 8).
///
/// Endpoint paths are relative to [ApiClient.baseUrl] (which already ends in
/// `/api`). Both routes require a Bearer token.
class EntryApi {
  EntryApi(this._client);

  final ApiClient _client;

  /// `GET /api/shifts/:shiftId/entry` — the role-shaped entry context.
  ///
  /// Returns exactly `{ shift, canSubmit, submissionError, entryWindow,
  /// locations, quantities }`. `canSubmit`/`submissionError` are authoritative:
  /// eligibility is never inferred from the local clock.
  Future<EntryContext> getEntryContext(int shiftId, {String? token}) async {
    if (shiftId <= 0) throw malformedResponse();
    final payload = await _client.get('/shifts/$shiftId/entry', token: token);
    return _parseContext(payload);
  }

  /// `PUT /api/shifts/:shiftId/quantities` — absolute, all-or-nothing batch.
  ///
  /// [items] is the exact `quantities` array (`{ variantId, quantity }`);
  /// variants omitted from [items] are left untouched by the backend. Success
  /// returns every stored quantity row for the `(shift, location)` pair,
  /// ordered by `variantId`.
  Future<List<QuantityRecord>> submitQuantities(
    int shiftId, {
    required int locationId,
    required List<({int variantId, int quantity})> items,
    String? token,
  }) async {
    if (shiftId <= 0 || locationId <= 0) throw malformedResponse();
    final payload = await _client.put(
      '/shifts/$shiftId/quantities',
      token: token,
      body: {
        'locationId': locationId,
        'quantities': [
          for (final item in items)
            {'variantId': item.variantId, 'quantity': item.quantity},
        ],
      },
    );
    if (payload is! Map || payload['quantities'] is! List) {
      throw malformedResponse();
    }
    final records = payload['quantities'] as List;
    final quantities = <QuantityRecord>[];
    for (final record in records) {
      quantities.add(_parseQuantity(record));
    }
    return quantities;
  }

  static EntryContext _parseContext(Object? payload) {
    if (payload is! Map) throw malformedResponse();

    final shift = payload['shift'];
    final canSubmit = payload['canSubmit'];
    final submissionError = payload['submissionError'];
    final entryWindow = payload['entryWindow'];
    final locations = payload['locations'];
    final quantities = payload['quantities'];

    if (shift is! Map) throw malformedResponse();
    if (canSubmit is! bool) throw malformedResponse();
    if (submissionError != null && submissionError is! String) {
      throw malformedResponse();
    }
    if (entryWindow is! Map) throw malformedResponse();
    if (locations is! List) throw malformedResponse();
    if (quantities is! List) throw malformedResponse();

    final parsedShift = _parseShift(shift);
    final parsedWindow = _parseWindow(entryWindow);

    final parsedLocations = <Location>[];
    for (final record in locations) {
      parsedLocations.add(_parseLocation(record));
    }

    final parsedQuantities = <QuantityRecord>[];
    for (final record in quantities) {
      parsedQuantities.add(_parseQuantity(record));
    }

    return EntryContext(
      shift: parsedShift,
      canSubmit: canSubmit,
      submissionError: submissionError as String?,
      entryWindow: parsedWindow,
      locations: parsedLocations,
      quantities: parsedQuantities,
    );
  }

  static EntryWindow _parseWindow(Object? payload) {
    if (payload is! Map) throw malformedResponse();
    final opensAt = payload['opensAt'];
    final closesAt = payload['closesAt'];
    if (opensAt is! String || opensAt.isEmpty) throw malformedResponse();
    if (closesAt is! String || closesAt.isEmpty) throw malformedResponse();
    return EntryWindow(opensAt: opensAt, closesAt: closesAt);
  }

  static Shift _parseShift(Map<dynamic, dynamic> record) {
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

    return Shift(
      id: id,
      title: title ?? '',
      description: '',
      date: _parseDate(date),
      startTime: startTime,
      endTime: endTime,
      locationIds: const [],
      status: _mapStatus(status),
    );
  }

  static Location _parseLocation(Object? record) {
    if (record is! Map) throw malformedResponse();
    final id = record['id'];
    final name = record['name'];
    final address = record['address'];
    final isActive = record['isActive'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (name is! String || name.isEmpty) throw malformedResponse();
    if (address is! String) throw malformedResponse();
    if (isActive is! bool) throw malformedResponse();

    return Location(id: id, name: name, address: address, isActive: isActive);
  }

  static QuantityRecord _parseQuantity(Object? record) {
    if (record is! Map) throw malformedResponse();
    final id = record['id'];
    final shiftId = record['shiftId'];
    final locationId = record['locationId'];
    final variantId = record['variantId'];
    final quantity = record['quantity'];

    if (id is! int || id <= 0) throw malformedResponse();
    if (shiftId != null && shiftId is! int) throw malformedResponse();
    if (locationId is! int || locationId <= 0) throw malformedResponse();
    if (variantId is! int || variantId <= 0) throw malformedResponse();
    if (quantity is! int || quantity < 0) throw malformedResponse();

    return QuantityRecord(
      id: id,
      shiftId: shiftId as int?,
      locationId: locationId,
      variantId: variantId,
      quantity: quantity,
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
    final dt = DateTime(year, month, day);
    if (dt.year != year || dt.month != month || dt.day != day) {
      throw malformedResponse();
    }
    return dt;
  }

  static ShiftStatus _mapStatus(String status) {
    switch (status) {
      case 'OPEN':
        return ShiftStatus.available;
      case 'CLOSED':
        return ShiftStatus.completed;
      case 'CANCELLED':
        return ShiftStatus.archived;
      case 'DRAFT':
        return ShiftStatus.draft;
      default:
        return ShiftStatus.upcoming;
    }
  }

  static ApiException malformedResponse() => const ApiException(
    code: 'UNEXPECTED_RESPONSE',
    message: 'The server returned an unexpected response.',
  );
}
