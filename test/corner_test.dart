import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/config/app_config.dart';

void main() {
  test('assigning an occupied corner swaps the two panels', () {
    final c = AppConfig();
    c.assignCorner(OverlaySlot.weather, OverlayCorner.topRight);
    c.assignCorner(OverlaySlot.camera, OverlayCorner.topRight);
    expect(c.camera.corner, OverlayCorner.topRight);
    expect(c.weather.corner, isNot(OverlayCorner.topRight));
  });

  test('no two panels ever share a corner, however they are moved', () {
    final c = AppConfig();
    final slots = OverlaySlot.values;
    final corners = OverlayCorner.values;
    var n = 0;
    for (final slot in [...slots, ...slots, ...slots.reversed]) {
      for (final corner in [...corners, ...corners.reversed]) {
        c.assignCorner(slot, corner);
        final used = slots.map(c.cornerOf).toSet();
        expect(used.length, slots.length, reason: 'clash after $n moves');
        n++;
      }
    }
  });

  test('a config saved with two panels in one corner is separated on load', () {
    final json = AppConfig().toJson();
    (json['weather'] as Map<String, dynamic>)['corner'] = 'bottomLeft';
    (json['nowPlaying'] as Map<String, dynamic>)['corner'] = 'bottomLeft';
    (json['camera'] as Map<String, dynamic>)['corner'] = 'bottomLeft';
    final c = AppConfig.fromJson(json);
    expect(OverlaySlot.values.map(c.cornerOf).toSet().length, 3);
  });
}
