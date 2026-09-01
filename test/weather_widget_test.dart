import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/dashboard/widgets/weather_widget.dart';

void main() {
  group('the day label', () {
    test('today is named, not abbreviated', () {
      expect(DashboardWeatherWidget.dayLabel(DateTime.now()), 'Today');
    });

    test('other days get their weekday', () {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      expect(DashboardWeatherWidget.dayLabel(tomorrow), isNot('Today'));
      expect(DashboardWeatherWidget.dayLabel(tomorrow).length, 3);
    });

    test('the same date a year apart is not today', () {
      // Guards the comparison against being made on month and day alone.
      final lastYear = DateTime.now().subtract(const Duration(days: 365));
      expect(DashboardWeatherWidget.dayLabel(lastYear), isNot('Today'));
    });
  });
}
