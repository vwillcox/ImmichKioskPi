import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/dashboard/widgets/scrolling_text.dart';

Widget host(String text, double width) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: ScrollingText(
              text,
              style: const TextStyle(fontSize: 20),
              pause: const Duration(milliseconds: 300),
            ),
          ),
        ),
      ),
    );

/// Scoped to the widget under test: MaterialApp and Scaffold bring their own
/// Transforms, so a bare byType finder matches those too.
final scrollTransform = find.descendant(
  of: find.byType(ScrollingText),
  matching: find.byType(Transform),
);

Offset offsetOf(WidgetTester tester) {
  final t = tester.widget<Transform>(scrollTransform.first);
  return Offset(t.transform.storage[12], t.transform.storage[13]);
}

void main() {
  testWidgets('text that fits sits still and is not clipped or animated',
      (tester) async {
    await tester.pumpWidget(host('Short', 600));
    await tester.pump();
    expect(scrollTransform, findsNothing);
    expect(find.text('Short'), findsOneWidget);
  });

  testWidgets('text too wide scrolls right to left, then holds at the end',
      (tester) async {
    await tester.pumpWidget(host(
        'A very long track name that certainly will not fit in this box', 120));
    // Let layout settle and the controller start.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(scrollTransform, findsOneWidget,
        reason: 'an overflowing title should be animated');

    // Held at the start for the pause.
    expect(offsetOf(tester).dx, 0);

    // Then moving left — a negative x offset, increasingly so.
    await tester.pump(const Duration(milliseconds: 500));
    final moving = offsetOf(tester).dx;
    expect(moving, lessThan(0));

    await tester.pump(const Duration(milliseconds: 400));
    expect(offsetOf(tester).dx, lessThan(moving),
        reason: 'it should keep travelling in the same direction');

    // It never scrolls further than the amount that was hidden.
    await tester.pump(const Duration(seconds: 30));
    final painter = TextPainter(
      text: const TextSpan(
        text: 'A very long track name that certainly will not fit in this box',
        style: TextStyle(fontSize: 20),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(offsetOf(tester).dx, greaterThanOrEqualTo(-(painter.width - 120)));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new track re-measures rather than inheriting the old scroll',
      (tester) async {
    await tester.pumpWidget(host('A title far too long for this narrow box', 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(scrollTransform, findsOneWidget);

    await tester.pumpWidget(host('Tiny', 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(scrollTransform, findsNothing,
        reason: 'a short title should stop scrolling');
  });
}
