import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/services/kiosk_browser.dart';
import 'package:immich_kiosk_pi/widgets/incoming_share_overlay.dart'
    show kBrowserCloseGutter;

void main() {
  group('the browser window leaves room for the close button', () {
    const screen = Size(1920, 1200);

    test('the gutter is left clear at the bottom', () {
      final window = KioskBrowser.windowFor(screen, kBrowserCloseGutter)!;
      final bottomOfWindow = screen.height - window.height;
      expect(bottomOfWindow, greaterThanOrEqualTo(kBrowserCloseGutter));
    });

    test('the button fits in what is left', () {
      final window = KioskBrowser.windowFor(screen, kBrowserCloseGutter)!;
      final gap = screen.height - window.height;
      // The button is ~90px tall; anything tighter than this and it would be
      // touching the page above it.
      expect(gap, greaterThan(120));
    });

    test('the window still fills most of the screen', () {
      final window = KioskBrowser.windowFor(screen, kBrowserCloseGutter)!;
      expect(window.width / screen.width, greaterThan(0.9));
      expect(window.height / screen.height, greaterThan(0.75));
    });

    test('an unknown screen asks for no particular geometry', () {
      expect(KioskBrowser.windowFor(null, kBrowserCloseGutter), isNull);
    });

    test('a gutter taller than the screen gives back nothing', () {
      // Rather than a negative height, which Firefox stores and then opens at
      // some minimum of its own — covering the button it was meant to spare.
      expect(KioskBrowser.windowFor(screen, 5000), isNull);
      expect(KioskBrowser.windowFor(const Size(100, 100), 100), isNull);
    });
  });

  group('the Firefox profile', () {
    test('sets touch events explicitly rather than leaving them automatic', () {
      // "auto" decides from hardware detection and gets it wrong on this
      // panel; 1 is the value that makes the touchscreen work.
      expect(KioskBrowser.prefs,
          contains('user_pref("dom.w3c_touch_events.enabled", 1);'));
    });

    test('asks for touch-sized toolbars', () {
      expect(KioskBrowser.prefs, contains('"browser.uidensity", 2'));
    });

    test('rejects cookie banners rather than accepting them', () {
      // Mode 2 is reject; mode 1 would accept, which is the wrong default for
      // a screen nobody is standing at.
      expect(KioskBrowser.prefs, contains('"cookiebanners.service.mode", 2'));
      expect(KioskBrowser.prefs,
          contains('"cookiebanners.service.enableGlobalRules", true'));
    });

    test('turns tracking protection all the way up', () {
      expect(KioskBrowser.prefs, contains('"browser.contentblocking.category", "strict"'));
      expect(KioskBrowser.prefs,
          contains('"privacy.trackingprotection.enabled", true'));
    });

    test('suppresses the first-run pages that would hide a shared link', () {
      expect(KioskBrowser.prefs, contains('"browser.aboutwelcome.enabled", false'));
      expect(KioskBrowser.prefs, contains('"datareporting.policy.firstRunURL", ""'));
    });

    test('never offers to remember a password on a shared screen', () {
      expect(KioskBrowser.prefs, contains('"signon.rememberSignons", false'));
    });
  });

  group('the chrome-less stylesheet', () {
    test('collapses the toolbars rather than removing them from layout', () {
      // display:none on these leaves a blank window on this Firefox build.
      expect(KioskBrowser.userChrome, contains('#nav-bar'));
      expect(KioskBrowser.userChrome, contains('#TabsToolbar'));
      expect(KioskBrowser.userChrome, contains('visibility: collapse'));
      expect(KioskBrowser.userChrome, isNot(contains('#nav-bar { display: none')));
    });
  });
}
