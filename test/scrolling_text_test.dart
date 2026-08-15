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
/// Positioned widgets, so a bare byType finder matches those too.
final scrollTransform = find.descendant(
  of: find.byType(ScrollingText),
  matching: find.byType(Positioned),
);

/// How far along the text has been slid, and how wide it was allowed to be.
({double left, double width}) offsetOf(WidgetTester tester) {
  final p = tester.widget<Positioned>(scrollTransform.first);
  return (left: p.left!, width: p.width!);
}

/// Both copies of the text — the one on screen and the one a lap behind.
List<double> lefts(WidgetTester tester) => tester
    .widgetList<Positioned>(scrollTransform)
    .map((p) => p.left!)
    .toList();

void main() {
  testWidgets('text that fits sits still and is not clipped or animated',
      (tester) async {
    await tester.pumpWidget(host('Short', 600));
    await tester.pump();
    expect(scrollTransform, findsNothing);
    expect(find.text('Short'), findsOneWidget);
  });

  testWidgets('text too wide scrolls right to left and loops round',
      (tester) async {
    await tester.pumpWidget(host(
        'A very long track name that certainly will not fit in this box', 120));
    // Let layout settle and the controller start.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(scrollTransform, findsNWidgets(2),
        reason: 'a second copy trails a lap behind so the wrap has no seam');

    // Held at the start for the pause.
    expect(offsetOf(tester).left, 0);

    // Then moving left — a negative x offset, increasingly so.
    await tester.pump(const Duration(milliseconds: 500));
    final moving = offsetOf(tester).left;
    expect(moving, lessThan(0));

    await tester.pump(const Duration(milliseconds: 400));
    expect(offsetOf(tester).left, lessThan(moving),
        reason: 'it should keep travelling in the same direction');

    // The whole string is laid out, not merely the part that fits. This is
    // the bug this replaced: an oversized box is still bound by the width
    // coming down from the tile, so the text was truncated before it moved
    // and sliding it along revealed the blank it had been cut to.
    expect(offsetOf(tester).width, greaterThan(120 * 2),
        reason: 'the text should be laid out at its full length');

    // The trailing copy is exactly one lap ahead, which is what makes the
    // wrap seamless.
    final pair = lefts(tester);
    final lap = pair[1] - pair[0];
    expect(lap, greaterThan(offsetOf(tester).width),
        reason: 'a lap is the text plus the gap after it');

    // It scrolls the whole text off to the left rather than stopping once
    // the last character shows.
    // Long enough to cover a whole lap: at the default speed this title
    // takes the better part of a minute to come round.
    var furthest = 0.0;
    for (var i = 0; i < 140; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final l = lefts(tester)[0];
      if (l < furthest) furthest = l;
    }
    expect(furthest, lessThan(-offsetOf(tester).width),
        reason: 'the text should leave the left edge entirely');

    // And it keeps going rather than stopping at the end.
    await tester.pump(const Duration(milliseconds: 500));
    expect(lefts(tester).first, lessThanOrEqualTo(0.0));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new track re-measures rather than inheriting the old scroll',
      (tester) async {
    await tester.pumpWidget(host('A title far too long for this narrow box', 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(scrollTransform, findsNWidgets(2));

    await tester.pumpWidget(host('Tiny', 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(scrollTransform, findsNothing,
        reason: 'a short title should stop scrolling');
  });
}
