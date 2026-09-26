import 'package:flutter_test/flutter_test.dart';

import 'package:home_canvas/config/app_config.dart';

void main() {
  test('the reader and the timers start at the old shared speech volume', () {
    final s = ShareInboxSettings.fromJson({'speechVolume': 30});
    expect(s.readerVolume, 30);
    expect(s.timerVolume, 30);
  });

  test('each volume is kept on its own', () {
    final s = ShareInboxSettings.fromJson({
      'speechVolume': 30,
      'readerVolume': 55,
      'timerVolume': 70,
      'notificationVolume': 80,
    });
    final back = ShareInboxSettings.fromJson(s.toJson());
    expect(
      [back.speechVolume, back.readerVolume, back.timerVolume],
      [30, 55, 70],
    );
  });

  test('Do Not Disturb mutes them all, and gives them back unchanged', () {
    final s = ShareInboxSettings(
      notificationVolume: 80,
      speechVolume: 40,
      readerVolume: 50,
      timerVolume: 60,
    );
    s.dndMuted = true;
    expect(
      [s.notificationOut, s.speechOut, s.readerOut, s.timerOut],
      [0, 0, 0, 0],
    );
    s.dndMuted = false;
    expect(
      [s.notificationOut, s.speechOut, s.readerOut, s.timerOut],
      [80, 40, 50, 60],
    );
  });
}
