import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// Opens web pages in a real browser window on the kiosk's screen.
///
/// Firefox is preferred over Chromium, for two reasons that matter on a panel
/// nobody sits in front of: its tracking protection is stronger by default,
/// and it can dismiss cookie banners by itself. A consent dialog on a wall
/// display is worse than an annoyance — there is often nobody there to answer
/// it, and the page underneath stays unusable until somebody does.
///
/// Chromium remains as a fallback so an install without Firefox keeps working.
///
/// ## Touch
///
/// Firefox is launched as a native Wayland client, which is what makes the
/// touchscreen work at all. The usual advice for this — `MOZ_USE_XINPUT2=1` —
/// applies to X11 and does nothing here; under XWayland the touch events
/// simply never arrive. `MOZ_ENABLE_WAYLAND=1` is set explicitly rather than
/// relying on Firefox's own default, which varies by build and would fail
/// silently and confusingly if it ever changed.
class KioskBrowser {
  KioskBrowser._();

  /// Firefox's window has no equivalent of Chromium's `--app`, and its
  /// `--window-size` is for screenshots only, so geometry is seeded into the
  /// profile instead. Re-seeded on every launch so a window the user dragged
  /// or resized does not become the permanent shape.
  static const String _mainWindow = 'chrome://browser/content/browser.xhtml';

  static String? _cached;
  static bool _looked = false;

  /// The browser to use, or null if neither is installed.
  static Future<String?> resolve() async {
    if (_looked) return _cached;
    _looked = true;
    for (final candidate in ['firefox', 'chromium']) {
      try {
        final found = await Process.run('which', [candidate]);
        if (found.exitCode == 0) {
          _cached = candidate;
          break;
        }
      } catch (_) {
        // `which` itself missing is not worth failing over; try the next.
      }
    }
    debugPrint('KioskBrowser: using ${_cached ?? "no browser"}');
    return _cached;
  }

  @visibleForTesting
  static void resetForTest({String? browser, bool looked = false}) {
    _cached = browser;
    _looked = looked;
  }

  /// Opens [url] in its own window and returns the process, or null if no
  /// browser is installed or it would not start.
  ///
  /// [profile] names an isolated browser profile. Both browsers are otherwise
  /// single-instance: without one of their own they hand the URL to whatever
  /// window happens to be open already, ignore every option here, and leave
  /// nothing to kill when the page should close.
  ///
  /// [bottomGutter] is a strip of screen kept clear beneath the window for the
  /// kiosk's own close button. Firefox's real `--kiosk` flag is deliberately
  /// not used: it takes the entire screen and ignores any geometry asked of
  /// it, which would bury the one control that closes it. Hiding the browser's
  /// own chrome with [chromeless] gives the same uncluttered result while
  /// leaving that strip free.
  static Future<Process?> open(
    String url, {
    required String profile,
    Size? screen,
    double bottomGutter = 0,
    bool chromeless = false,
  }) async {
    final browser = await resolve();
    if (browser == null) {
      debugPrint('KioskBrowser: no browser installed, cannot open $url');
      return null;
    }

    final home = Platform.environment['HOME'];
    final dir = home == null
        ? null
        : '$home/.cache/immich_kiosk_pi/$browser-$profile';

    final window = windowFor(screen, bottomGutter);

    try {
      if (browser == 'firefox') {
        if (dir != null) {
          await _writeProfile(dir,
              window: window, screen: screen, chromeless: chromeless);
        }
        return await Process.start(
          'firefox',
          [
            // Without this the URL is handed to any Firefox already running,
            // which on this panel would be a different viewer entirely.
            '--new-instance',
            if (dir != null) ...['--profile', dir],
            url,
          ],
          environment: const {'MOZ_ENABLE_WAYLAND': '1'},
        );
      }

      return await Process.start('chromium', [
        // Chromium's app mode is already chrome-less, so it needs no
        // equivalent of the stylesheet Firefox gets.
        chromeless ? '--app=$url' : '--new-window',
        if (!chromeless) url,
        '--ozone-platform=wayland',
        // Chromium otherwise blocks on a GNOME-Keyring password prompt that
        // has nothing to do with the page being opened.
        '--password-store=basic',
        if (window != null)
          '--window-size=${window.width.round()},${window.height.round()}',
        if (dir != null) '--user-data-dir=$dir',
      ]);
    } catch (e) {
      debugPrint('KioskBrowser: could not open $url: $e');
      return null;
    }
  }

  /// A narrow margin at the sides and top; the interesting gap is the one
  /// below, which is sized by the caller to fit its close button.
  static const double _edgeMargin = 24;

  /// The window to ask for on a [screen], leaving [bottomGutter] clear.
  ///
  /// Returns null when the screen size is not known yet, in which case the
  /// browser picks its own size rather than being given a nonsense one.
  @visibleForTesting
  static Size? windowFor(Size? screen, double bottomGutter) {
    if (screen == null) return null;
    final width = screen.width - _edgeMargin * 2;
    final height = screen.height - _edgeMargin - bottomGutter;
    // A gutter larger than the screen would ask for a window of negative
    // height, which Firefox stores and then opens at some minimum of its own,
    // covering the button anyway. Better to give back nothing.
    if (width <= 0 || height <= 0) return null;
    return Size(width, height);
  }

  /// Writes the profile's preferences, chrome stylesheet and window geometry.
  ///
  /// `user.js` rather than `prefs.js` because Firefox re-applies it on every
  /// start: a preference added in a later version of this app then takes
  /// effect on an existing profile, instead of only on a fresh one.
  static Future<void> _writeProfile(String dir,
      {Size? window, Size? screen, bool chromeless = false}) async {
    try {
      await Directory(dir).create(recursive: true);
      await File('$dir/user.js')
          .writeAsString(chromeless ? '$_prefs\n$_chromelessPrefs' : _prefs);

      // Firefox has no equivalent of Chromium's --app, and its --kiosk takes
      // the whole screen, so the chrome is hidden with a stylesheet instead.
      final chromeDir = Directory('$dir/chrome');
      if (chromeless) {
        await chromeDir.create(recursive: true);
        await File('$dir/chrome/userChrome.css').writeAsString(_userChrome);
      } else if (await chromeDir.exists()) {
        // A profile reused after this changed would otherwise keep hiding the
        // toolbars for good.
        await chromeDir.delete(recursive: true);
      }

      if (window != null) {
        // Centred horizontally, and pinned near the top so the gutter stays
        // whole at the bottom. labwc will not centre a window that asks for
        // its own geometry, so it is worked out here.
        final x = screen == null
            ? 0
            : ((screen.width - window.width) / 2).round().clamp(0, 1 << 20);
        await File('$dir/xulstore.json').writeAsString(
          '{"$_mainWindow":{"main-window":{'
          '"screenX":"$x","screenY":"${_edgeMargin.round()}",'
          '"width":"${window.width.round()}","height":"${window.height.round()}",'
          '"sizemode":"normal"}}}',
        );
      }
    } catch (e) {
      // A profile that cannot be written is not fatal — Firefox will make its
      // own with default settings. Worth knowing about, though, since the
      // touch and privacy preferences are what this is for.
      debugPrint('KioskBrowser: could not write profile $dir: $e');
    }
  }

  /// The preferences that make Firefox usable on this panel.
  ///
  /// Grouped by what they are for rather than alphabetically, because the
  /// reason a line is here is the part worth knowing when one stops working.
  @visibleForTesting
  static const String prefs = _prefs;

  static const String _prefs = '''
// Written by ImmichKioskPi. Edits here are overwritten on the next launch.

// --- Touch ---------------------------------------------------------------
// Set explicitly rather than left at Firefox's "auto", which decides from
// hardware detection and gets it wrong on this DSI panel often enough to be
// worth not relying on.
user_pref("dom.w3c_touch_events.enabled", 1);
user_pref("apz.allow_zooming", true);
user_pref("apz.allow_double_tap_zooming", true);
// Touch layout: bigger toolbar targets, which is the difference between the
// browser's own buttons being usable with a finger and not.
user_pref("browser.uidensity", 2);
user_pref("general.smoothScroll", true);

// --- Tracking protection --------------------------------------------------
user_pref("browser.contentblocking.category", "strict");
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);
user_pref("privacy.trackingprotection.fingerprinting.enabled", true);
user_pref("privacy.trackingprotection.cryptomining.enabled", true);
user_pref("privacy.globalprivacycontrol.enabled", true);

// --- Cookie banners -------------------------------------------------------
// Mode 2 rejects everything it can rather than accepting to make the banner
// go away. On a wall panel there is usually nobody there to answer one.
user_pref("cookiebanners.service.mode", 2);
user_pref("cookiebanners.service.mode.privateBrowsing", 2);
user_pref("cookiebanners.bannerClicking.enabled", true);
// Without the global rules Firefox only handles sites on its own curated
// list, which is short — most banners survive. These generalise it. Even
// so it is far from complete; see the README on uBlock Origin, which is
// what actually catches a first visit to a site Firefox has no rule for.
user_pref("cookiebanners.service.enableGlobalRules", true);
user_pref("cookiebanners.service.enableGlobalRules.subFrames", true);

// --- Nothing that interrupts a kiosk --------------------------------------
// Every one of these is a first-run or periodic interstitial that would
// otherwise appear instead of the page somebody just shared.
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("extensions.pocket.enabled", false);
user_pref("browser.translations.automaticallyPopup", false);
user_pref("app.update.auto", false);
// No password prompts on a screen anyone walking past can see.
user_pref("signon.rememberSignons", false);
''';

  /// Only for chrome-less windows: without this Firefox ignores
  /// `userChrome.css` entirely, and the toolbars stay put with no error.
  static const String _chromelessPrefs = '''
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
''';

  /// Hides the browser's own furniture so the page fills the window — the
  /// look of kiosk mode, without kiosk mode's insistence on the whole screen.
  ///
  /// `visibility: collapse` rather than `display: none` on the toolbars:
  /// Firefox measures these during startup, and removing them from layout
  /// outright has a habit of leaving a blank window on this build.
  @visibleForTesting
  static const String userChrome = _userChrome;

  static const String _userChrome = '''
/* Written by ImmichKioskPi. Edits here are overwritten on the next launch. */
#TabsToolbar { visibility: collapse !important; }
#nav-bar { visibility: collapse !important; }
#sidebar-box, #sidebar-splitter { display: none !important; }
/* The findbar is still reachable by keyboard and is worth keeping usable. */
#browser { border: 0 !important; }
''';
}
