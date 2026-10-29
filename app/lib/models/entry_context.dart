import 'package:flutter/foundation.dart';

import 'location.dart';
import 'shift.dart';

/// The entry-context payload of `GET /api/shifts/:shiftId/entry`.
///
/// Every field matches the backend safe contract exactly; no audit metadata
/// (registrant names/phones, `recorded_by`, `registered_at`) is present.
@immutable
class EntryContext {
  const EntryContext({
    required this.shift,
    required this.canSubmit,
    required this.submissionError,
    required this.entryWindow,
    required this.locations,
    required this.quantities,
  });

  final Shift shift;

  /// Authoritative submission eligibility computed by the backend.
  final bool canSubmit;

  /// Machine reason when [canSubmit] is false, else `null`. One of
  /// `SHIFT_NOT_OPEN`, `REGISTRATION_REQUIRED`, `ENTRY_WINDOW_CLOSED`,
  /// `ROLE_NOT_VOLUNTEER`.
  final String? submissionError;

  final EntryWindow entryWindow;

  /// Active locations of the shift, scoped to the caller.
  final List<Location> locations;

  /// Existing quantity rows for the shift, scoped to the caller.
  final List<QuantityRecord> quantities;
}

/// The volunteer entry window as Sofia-offset ISO strings.
@immutable
class EntryWindow {
  const EntryWindow({required this.opensAt, required this.closesAt});

  final String opensAt;
  final String closesAt;
}

/// A stored collected-quantity row (`{ id, shiftId, locationId, variantId,
/// quantity }`). `shiftId` is `null` for a legacy unlinked row.
@immutable
class QuantityRecord {
  const QuantityRecord({
    required this.id,
    required this.shiftId,
    required this.locationId,
    required this.variantId,
    required this.quantity,
  });

  final int id;
  final int? shiftId;
  final int locationId;
  final int variantId;
  final int quantity;
}
