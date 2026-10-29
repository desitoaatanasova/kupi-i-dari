import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kupi_i_dari/main.dart';

void main() {
  testWidgets('App renders the Bulgarian start screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const KupiIDariApp());

    expect(find.text('Купи и Дари'), findsWidgets);
    expect(find.text('Даряване, което стига до хората.'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Вход'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Регистрация'), findsOneWidget);
    expect(find.text('Разгледай демо съдържанието'), findsOneWidget);
    expect(find.text('Скелет на приложението — Фаза 1'), findsNothing);
  });
}
