import 'package:flutter_test/flutter_test.dart';

import 'package:kupi_i_dari/main.dart';

void main() {
  testWidgets('App renders the Bulgarian placeholder', (WidgetTester tester) async {
    await tester.pumpWidget(const KupiIDariApp());

    expect(find.text('Купи и Дари'), findsWidgets);
    expect(find.text('Скелет на приложението — Фаза 1'), findsOneWidget);
  });
}
