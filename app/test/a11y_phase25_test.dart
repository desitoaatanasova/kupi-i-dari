import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupi_i_dari/core/statuses.dart';
import 'package:kupi_i_dari/core/theme/app_colors.dart';
import 'package:kupi_i_dari/widgets/product_sticker_card.dart';
import 'package:kupi_i_dari/widgets/search_field.dart';

double _linearize(double channel) {
  return channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color color) {
  return 0.2126 * _linearize(color.r) +
      0.7152 * _linearize(color.g) +
      0.0722 * _linearize(color.b);
}

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = _relativeLuminance(foreground);
  final backgroundLuminance = _relativeLuminance(background);
  final lighter = math.max(foregroundLuminance, backgroundLuminance);
  final darker = math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

Finder _iconButtonIn(String tooltip) {
  return find.descendant(
    of: find.byTooltip(tooltip),
    matching: find.byType(IconButton),
  );
}

Future<void> _pumpSticker(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ProductStickerCard.labelled(
            name: 'Шампоан',
            unitLabel: 'бр',
            quantity: 0,
            onIncrease: () {},
            onDecrease: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('Phase 25 contrast', () {
    test('textTertiary meets AA on the white background', () {
      expect(
        _contrastRatio(AppColors.textTertiary, AppColors.background),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('textTertiary meets AA on the secondary background', () {
      expect(
        _contrastRatio(AppColors.textTertiary, AppColors.backgroundSecondary),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('every shift status chip meets AA', () {
      for (final status in ShiftStatus.values) {
        expect(
          _contrastRatio(status.textColor, status.backgroundColor),
          greaterThanOrEqualTo(4.5),
          reason: '${status.name} must expose readable text',
        );
      }
    });

    test('the saved marker meets AA on the screen background', () {
      expect(
        _contrastRatio(AppColors.success, AppColors.background),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('Phase 25 quantity controls', () {
    testWidgets('minus and plus expose at least 48x48 hit targets', (
      tester,
    ) async {
      await _pumpSticker(tester);

      for (final tooltip in const ['Намали', 'Увеличи']) {
        final size = tester.getSize(_iconButtonIn(tooltip));
        expect(
          size.width,
          greaterThanOrEqualTo(48),
          reason: '$tooltip must be at least 48 logical pixels wide',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(48),
          reason: '$tooltip must be at least 48 logical pixels tall',
        );
      }
    });

    testWidgets('minus and plus expose meaningful button semantics', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpSticker(tester);

      for (final tooltip in const ['Намали', 'Увеличи']) {
        final finder = find.bySemanticsLabel(RegExp(tooltip));
        expect(finder, findsOneWidget);
        final node = tester.getSemantics(finder);
        expect(node.label, contains(tooltip));
        expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      }

      semantics.dispose();
    });
  });

  group('Phase 25 search clear', () {
    testWidgets('the clear action exposes its label and button semantics', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchField(
              controller: controller,
              onClear: controller.clear,
            ),
          ),
        ),
      );

      controller.text = 'Пловдив';
      await tester.pump();

      final finder = find.bySemanticsLabel(RegExp('Изчисти търсенето'));
      expect(finder, findsOneWidget);
      final node = tester.getSemantics(finder);
      expect(node.label, contains('Изчисти търсенето'));
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);

      semantics.dispose();
    });
  });
}
