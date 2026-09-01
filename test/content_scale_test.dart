import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/dashboard/widget_registry.dart';

DashboardWidgetType typeOf({int w = 4, int h = 3}) => DashboardWidgetType(
      type: 't',
      name: 'T',
      description: '',
      glyph: '*',
      defaultWidth: w,
      defaultHeight: h,
      build: (_, __) => const SizedBox.shrink(),
    );

void main() {
  group('content scales to the tile it is given', () {
    test('a widget at its design size is left alone', () {
      expect(typeOf(w: 4, h: 3).contentScale(4, 3), 1.0);
    });

    test('half the size means half the text', () {
      expect(typeOf(w: 4, h: 4).contentScale(2, 2), 0.5);
    });

    test('the dimension that shrank most decides it', () {
      // Full width but a third of the height: fitting the width would still
      // leave the content overflowing downwards.
      expect(typeOf(w: 3, h: 3).contentScale(3, 1), closeTo(0.45, 0.001));
      expect(typeOf(w: 4, h: 2).contentScale(2, 2), 0.5);
    });

    test('it never grows, however large the tile', () {
      // Widgets that should fill a big tile already do it themselves; scaling
      // their fixed sizes up as well would overflow layouts that were fine.
      expect(typeOf(w: 2, h: 2).contentScale(12, 8), 1.0);
      expect(typeOf(w: 1, h: 1).contentScale(6, 6), 1.0);
    });

    test('it is floored rather than shrinking to nothing', () {
      // Past a point smaller text is not readable, and clipping something
      // legible beats rendering everything at two points.
      expect(typeOf(w: 12, h: 8).contentScale(1, 1), 0.45);
    });

    test('1x1 is handled for every default size', () {
      for (final d in [1, 2, 3, 4, 6, 12]) {
        final s = typeOf(w: d, h: d).contentScale(1, 1);
        expect(s, greaterThanOrEqualTo(0.45));
        expect(s, lessThanOrEqualTo(1.0));
      }
    });

    test('a zero default cannot divide by zero', () {
      expect(typeOf(w: 0, h: 0).contentScale(2, 2), 1.0);
    });
  });
}
