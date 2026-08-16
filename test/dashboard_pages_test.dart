import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/dashboard/dashboard_model.dart';

DashboardWidgetConfig w(String id, {int page = 0, int x = 0, int y = 0}) =>
    DashboardWidgetConfig(
        id: id, type: 'clock', x: x, y: y, width: 2, height: 2, page: page);

void main() {
  group('pages', () {
    test('a config with no pages is one page', () {
      final s = DashboardSettings(widgets: [w('a'), w('b', x: 4)]);
      expect(s.pageCount, 1);
      expect(s.widgetsOn(0).length, 2);
    });

    test('page count follows the highest page in use', () {
      final s = DashboardSettings(widgets: [w('a'), w('b', page: 2)]);
      expect(s.pageCount, 3);
      expect(s.widgetsOn(1), isEmpty);
      expect(s.widgetsOn(2).single.id, 'b');
    });

    test('an empty dashboard still has one page', () {
      expect(DashboardSettings().pageCount, 1);
    });

    test('widgets on different pages never overlap', () {
      // Identical cells, different pages — they are never on screen together,
      // so treating this as a clash would block a perfectly good layout.
      final a = w('a', page: 0);
      final b = w('b', page: 1);
      expect(a.overlaps(b), isFalse);

      final c = w('c', page: 1);
      expect(b.overlaps(c), isTrue);
    });

    test('a free slot is found per page', () {
      final s = DashboardSettings(widgets: [w('a', x: 0, y: 0)]);
      // Page 0's top-left is taken...
      expect(s.firstFreeSlot(2, 2), isNot((x: 0, y: 0)));
      // ...but the same cell on page 1 is free.
      expect(s.firstFreeSlot(2, 2, page: 1), (x: 0, y: 0));
    });
  });

  group('paging settings survive a round trip', () {
    test('interval and tap-to-flip are kept', () {
      final s = DashboardSettings(pageSeconds: 30, tapToFlip: true);
      final back = DashboardSettings.fromJson(s.toJson());
      expect(back.pageSeconds, 30);
      expect(back.tapToFlip, isTrue);
    });

    test('a widget remembers its page', () {
      final s = DashboardSettings(widgets: [w('a', page: 3)]);
      final back = DashboardSettings.fromJson(s.toJson());
      expect(back.widgets.single.page, 3);
      expect(back.pageCount, 4);
    });

    test('an absent interval means manual', () {
      expect(DashboardSettings.fromJson({}).pageSeconds, 0);
      expect(DashboardSettings.fromJson({}).tapToFlip, isFalse);
    });

    test('a too-fast interval is floored rather than obeyed', () {
      // A config saying 1 would flip the panel faster than it can be read.
      expect(DashboardSettings.fromJson({'pageSeconds': 1}).pageSeconds, 3);
      expect(DashboardSettings.fromJson({'pageSeconds': -5}).pageSeconds, 0);
      expect(DashboardSettings.fromJson({'pageSeconds': 99999}).pageSeconds, 3600);
    });

    test('a config written before pages existed loads as page one', () {
      final legacy = {
        'widgets': [
          {'id': 'a', 'type': 'clock', 'x': 0, 'y': 0, 'width': 2, 'height': 2},
        ],
      };
      final back = DashboardSettings.fromJson(legacy);
      expect(back.widgets.single.page, 0);
      expect(back.pageCount, 1);
    });
  });
}
