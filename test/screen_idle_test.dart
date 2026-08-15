import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/config/app_config.dart';
import 'package:immich_kiosk_pi/services/screen_idle_service.dart';

/// The service's decision to switch off is the part worth testing; the HTTP
/// call it makes to do so is `screen_control.py`'s business, and unreachable
/// from a test anyway. [ScreenIdleService.shouldSwitchOff] is the decision on
/// its own.
void main() {
  final settings = ScreenSettings(
    autoOffEnabled: true,
    idleMinutes: 10,
    wakeOnMusic: true,
  );

  const longIdle = Duration(minutes: 30);
  const shortIdle = Duration(minutes: 1);

  group('what keeps the panel awake', () {
    test('an idle kiosk with nothing on it switches off', () {
      expect(
        ScreenIdleService.shouldSwitchOff(
          settings: settings,
          idleFor: longIdle,
          playing: false,
          slideshowRunning: false,
          dashboardShowing: false,
        ),
        isTrue,
      );
    });

    test('the dashboard keeps it on however long nobody touches it', () {
      // The point of the change: a dashboard is read from across the room and
      // deliberately never touched, so "idle" is exactly when it is working.
      expect(
        ScreenIdleService.shouldSwitchOff(
          settings: settings,
          idleFor: longIdle,
          playing: false,
          slideshowRunning: false,
          dashboardShowing: true,
        ),
        isFalse,
      );
    });

    test('a slideshow still keeps it on', () {
      expect(
        ScreenIdleService.shouldSwitchOff(
          settings: settings,
          idleFor: longIdle,
          playing: false,
          slideshowRunning: true,
          dashboardShowing: false,
        ),
        isFalse,
      );
    });

    test('music still keeps it on', () {
      expect(
        ScreenIdleService.shouldSwitchOff(
          settings: settings,
          idleFor: longIdle,
          playing: true,
          slideshowRunning: false,
          dashboardShowing: false,
        ),
        isFalse,
      );
    });

    test('nothing switches off before the timeout', () {
      expect(
        ScreenIdleService.shouldSwitchOff(
          settings: settings,
          idleFor: shortIdle,
          playing: false,
          slideshowRunning: false,
          dashboardShowing: false,
        ),
        isFalse,
      );
    });

    test('the setting off means never, dashboard or not', () {
      final off = ScreenSettings(
        autoOffEnabled: false,
        idleMinutes: 10,
        wakeOnMusic: true,
      );
      for (final onDashboard in [true, false]) {
        expect(
          ScreenIdleService.shouldSwitchOff(
            settings: off,
            idleFor: longIdle,
            playing: false,
            slideshowRunning: false,
            dashboardShowing: onDashboard,
          ),
          isFalse,
        );
      }
    });
  });
}
