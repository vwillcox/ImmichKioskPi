import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/screens/shared_text_screen.dart';

void main() {
  group('a shared note is sized to be read across the room', () {
    test('a short note gets the largest type', () {
      expect(SharedTextScreen.fontSizeFor('Back in 10'), 88);
    });

    test('type shrinks as the note grows, but never below a floor', () {
      final short = SharedTextScreen.fontSizeFor('a' * 30);
      final medium = SharedTextScreen.fontSizeFor('a' * 200);
      final long = SharedTextScreen.fontSizeFor('a' * 2000);

      expect(short, greaterThan(medium));
      expect(medium, greaterThan(long));
      // The floor is the point: a very long note stays legible and scrolls
      // rather than being shrunk until it fits.
      expect(long, greaterThanOrEqualTo(38));
      expect(SharedTextScreen.fontSizeFor('a' * 100000), long);
    });

    test('surrounding whitespace does not push a short note into small type',
        () {
      expect(
        SharedTextScreen.fontSizeFor('   Dinner is ready   \n\n'),
        SharedTextScreen.fontSizeFor('Dinner is ready'),
      );
    });

    test('every note is larger than the 32px it used to be', () {
      for (final n in [1, 40, 41, 120, 121, 320, 321, 5000]) {
        expect(SharedTextScreen.fontSizeFor('a' * n), greaterThan(32),
            reason: 'a $n-character note should be bigger than the old size');
      }
    });
  });

  testWidgets('there is a large OK button that dismisses the note',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const SharedTextScreen(
                text: 'Dinner is ready', sender: 'Jo Fluff'),
          )),
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Dinner is ready'), findsOneWidget);
    expect(find.text('From Jo Fluff'), findsOneWidget);

    final ok = find.widgetWithText(InkWell, 'OK');
    expect(ok, findsOneWidget);

    // Comfortably past the usual 48px minimum — this is tapped in passing,
    // from a distance, and should not need aiming.
    final box = tester.getSize(ok);
    expect(box.height, greaterThan(70));
    expect(box.width, greaterThan(180));

    await tester.tap(ok);
    await tester.pumpAndSettle();
    expect(find.text('Dinner is ready'), findsNothing);
  });

  testWidgets('a very long note scrolls rather than overflowing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SharedTextScreen(
        text: List.filled(120, 'a rather long sentence').join(' '),
        sender: 'Jo Fluff',
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    // The button stays put while the note scrolls under it.
    expect(find.widgetWithText(InkWell, 'OK'), findsOneWidget);
  });
}
