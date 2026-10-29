import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kupi_i_dari/core/statuses.dart';
import 'package:kupi_i_dari/models/shift.dart';
import 'package:kupi_i_dari/widgets/shift_card.dart';
import 'package:kupi_i_dari/widgets/volunteer_count_badge.dart';

/// Phase 23 — the backend never exposes a registration count or a capacity, so
/// the app must not invent them. An unknown count hides the badge entirely.

Shift _shift({int? registeredCount, int? capacity}) {
  return Shift(
    id: 1,
    title: 'Сутрешна смяна',
    date: DateTime(2026, 5, 1),
    startTime: '09:00:00',
    endTime: '13:00:00',
    locationIds: const [],
    status: ShiftStatus.available,
    registeredCount: registeredCount,
    capacity: capacity,
  );
}

Future<void> _pumpBadge(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  group('VolunteerCountBadge', () {
    testWidgets('shows the counts when both are known', (tester) async {
      await _pumpBadge(
        tester,
        const VolunteerCountBadge(registered: 3, capacity: 10),
      );

      expect(find.text('3 / 10'), findsOneWidget);
    });

    testWidgets('shows a full shift', (tester) async {
      await _pumpBadge(
        tester,
        const VolunteerCountBadge(registered: 10, capacity: 10),
      );

      expect(find.text('10 / 10'), findsOneWidget);
    });

    testWidgets('renders nothing when the counts are unknown', (tester) async {
      await _pumpBadge(
        tester,
        const VolunteerCountBadge(registered: null, capacity: null),
      );

      expect(find.byType(Text), findsNothing);
      expect(tester.getSize(find.byType(VolunteerCountBadge)).width, 0);
    });

    testWidgets('renders nothing for an unusable capacity', (tester) async {
      await _pumpBadge(
        tester,
        const VolunteerCountBadge(registered: 0, capacity: 0),
      );

      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders nothing for a negative count', (tester) async {
      await _pumpBadge(
        tester,
        const VolunteerCountBadge(registered: -1, capacity: 10),
      );

      expect(find.byType(Text), findsNothing);
    });
  });

  group('ShiftCard', () {
    testWidgets('shows no count for an API-backed shift', (tester) async {
      await _pumpBadge(tester, ShiftCard(shift: _shift()));

      expect(find.byType(VolunteerCountBadge), findsOneWidget);
      expect(find.textContaining('/'), findsNothing);
    });

    testWidgets('shows the counts of a shift that has them', (tester) async {
      await _pumpBadge(
        tester,
        ShiftCard(shift: _shift(registeredCount: 2, capacity: 8)),
      );

      expect(find.text('2 / 8'), findsOneWidget);
    });
  });

  group('Shift counts', () {
    test('treats missing counts as unknown', () {
      final shift = _shift();

      expect(shift.registeredCount, isNull);
      expect(shift.capacity, isNull);
      expect(shift.isFull, isFalse);
      expect(shift.remaining, isNull);
    });

    test('computes the free places from known counts', () {
      final shift = _shift(registeredCount: 2, capacity: 8);

      expect(shift.isFull, isFalse);
      expect(shift.remaining, 6);
    });

    test('reports a full shift', () {
      final shift = _shift(registeredCount: 8, capacity: 8);

      expect(shift.isFull, isTrue);
      expect(shift.remaining, 0);
    });
  });
}
