import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/indoor_sensor_service.dart';

/// Home Assistant returns a state change every few seconds for this sensor, so
/// a 24-hour window is thousands of points. Thinning them keeps the chart's
/// painter sane without changing what it shows.
void main() {
  final t0 = DateTime(2026, 8, 3, 12);
  MapEntry<DateTime, double> at(int minutes, double v) =>
      MapEntry(t0.add(Duration(minutes: minutes)), v);

  test('thins dense points to roughly one per ten minutes', () {
    final dense = [for (var i = 0; i < 120; i++) at(i, 20 + i * 0.1)];
    final out = IndoorSensorService.downsample(dense);
    expect(out.length, 12);
    expect(out.first.key, t0);
  });

  test('keeps sparse points untouched', () {
    final sparse = [at(0, 20), at(30, 21), at(75, 22)];
    expect(IndoorSensorService.downsample(sparse), sparse);
  });

  test('always keeps the first point', () {
    // MapEntry has no value equality, so compare the parts.
    final only = IndoorSensorService.downsample([at(0, 20)]).single;
    expect(only.key, t0);
    expect(only.value, 20);
  });

  test('handles an empty series', () {
    expect(IndoorSensorService.downsample([]), isEmpty);
  });
}
