import 'package:flutter/material.dart';

import '../core/statuses.dart';

@immutable
class Shift {
  const Shift({
    required this.id,
    required this.title,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.locationIds,
    required this.status,
    this.registeredCount,
    this.capacity,
    this.description = '',
  });

  final int id;
  final String title;
  final String description;
  final DateTime date;
  final String startTime;
  final String endTime;
  final List<int> locationIds;
  final ShiftStatus status;

  /// Number of registered volunteers.
  ///
  /// The backend safe shift shape never exposes a count, so this is `null`
  /// for every API-backed shift. `null` means "unknown", never "zero".
  final int? registeredCount;

  /// Capacity of the shift.
  ///
  /// `null` means "unknown" — the backend does not expose a capacity, so no
  /// free-place or full-shift claim may be derived from it.
  final int? capacity;

  String get timeRange => '$startTime – $endTime';

  /// Whether the shift is known to be full.
  ///
  /// Without both counts the answer is unknown, so a shift is never reported
  /// as full.
  bool get isFull {
    final registered = registeredCount;
    final max = capacity;
    if (registered == null || max == null) return false;
    return registered >= max;
  }

  /// The free places, or `null` when the counts are unknown.
  int? get remaining {
    final registered = registeredCount;
    final max = capacity;
    if (registered == null || max == null) return null;
    return max - registered;
  }

  String get dateLabel {
    const months = <String>[
      'януари',
      'февруари',
      'март',
      'април',
      'май',
      'юни',
      'юли',
      'август',
      'септември',
      'октомври',
      'ноември',
      'декември',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year} г.';
  }

  String get weekdayLabel {
    const weekdays = <String>[
      'понеделник',
      'вторник',
      'сряда',
      'четвъртък',
      'петък',
      'събота',
      'неделя',
    ];
    return weekdays[date.weekday - 1];
  }
}
