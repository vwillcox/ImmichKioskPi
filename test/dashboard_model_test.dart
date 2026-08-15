import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/dashboard/dashboard_model.dart';

DashboardWidgetConfig at(int x, int y, int w, int h) => DashboardWidgetConfig(
    id: 'x$x$y', type: 'clock', x: x, y: y, width: w, height: h);

void main() {
  test('overlap is detected in both directions and adjacency is not', () {
    expect(at(0, 0, 2, 2).overlaps(at(1, 1, 2, 2)), isTrue);
    expect(at(1, 1, 2, 2).overlaps(at(0, 0, 2, 2)), isTrue);
    expect(at(0, 0, 2, 2).overlaps(at(2, 0, 2, 2)), isFalse);
    expect(at(0, 0, 2, 2).overlaps(at(0, 2, 2, 2)), isFalse);
  });

  test('a widget off the grid is pulled back on when loaded', () {
    final w = DashboardWidgetConfig.fromJson(
        {'id': 'a', 'type': 'clock', 'x': 99, 'y': 99, 'width': 4, 'height': 3});
    expect(w.x, DashboardGrid.columns - 4);
    expect(w.y, DashboardGrid.rows - 3);
  });

  test('an oversized widget is clamped to the grid', () {
    final w = DashboardWidgetConfig.fromJson(
        {'id': 'a', 'type': 'clock', 'x': 0, 'y': 0, 'width': 99, 'height': 99});
    expect(w.width, DashboardGrid.columns);
    expect(w.height, DashboardGrid.rows);
  });

  test('the first free slot skips occupied cells', () {
    final s = DashboardSettings(widgets: [at(0, 0, 4, 2)]);
    expect(s.firstFreeSlot(4, 2), (x: 4, y: 0));
  });

  test('a full grid reports no free slot', () {
    final s = DashboardSettings(
        widgets: [at(0, 0, DashboardGrid.columns, DashboardGrid.rows)]);
    expect(s.firstFreeSlot(2, 2), isNull);
  });

  test('widgets of an unknown type survive a round trip', () {
    final json = DashboardSettings(widgets: [
      DashboardWidgetConfig(
          id: 'a', type: 'not-built-yet', x: 0, y: 0, width: 2, height: 2,
          options: {'keep': 'me'}),
    ]).toJson();
    final back = DashboardSettings.fromJson(json);
    expect(back.widgets.single.type, 'not-built-yet');
    expect(back.widgets.single.options['keep'], 'me');
  });
}
