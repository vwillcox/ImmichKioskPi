import 'package:flutter_test/flutter_test.dart';

import 'package:kiosk_share/main.dart';

void main() {
  testWidgets('App shell builds', (WidgetTester tester) async {
    await tester.pumpWidget(const KioskShareApp());
    await tester.pump();
    expect(find.text('Kiosk Share'), findsOneWidget);
  });
}
