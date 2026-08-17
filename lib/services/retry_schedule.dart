/// How long to wait before trying again.
///
/// The panel starts before the network does — labwc brings the session up and
/// the kiosk with it, while DHCP and the link are still settling — so the first
/// fetch of everything routinely fails. On a plain `Timer.periodic` that meant
/// a widget showed an error for the whole interval: fifteen minutes of "could
/// not reach the server" on a wall display, long after the network came good.
///
/// So the interval is not fixed. With nothing to show it retries quickly and
/// backs off gently; the moment there is content it settles to the ordinary
/// refresh rate. Failing later is a different matter — there is something on
/// screen, it is merely stale, and hammering a server that has just gone down
/// helps nobody.
class RetrySchedule {
  RetrySchedule({
    required this.settled,
    this.first = const Duration(seconds: 4),
    this.ceiling = const Duration(seconds: 60),
  });

  /// The ordinary refresh interval, used once there is something on screen.
  final Duration settled;

  /// How soon to try again after the very first failure. Short, because at
  /// boot the usual cause is a network that is seconds away from working.
  final Duration first;

  /// The longest gap while still empty. Capped rather than doubling forever:
  /// a panel that has been up all night with no content should still be
  /// checking every minute, not every four hours.
  final Duration ceiling;

  int _failures = 0;

  /// How many consecutive empty attempts there have been.
  int get failures => _failures;

  /// The delay before the next attempt.
  ///
  /// [hasContent] is the question that matters — not whether the last fetch
  /// succeeded, but whether there is anything to show. A stale reading is
  /// still a reading; an empty panel is a fault.
  Duration next({required bool hasContent}) {
    if (hasContent) {
      _failures = 0;
      return settled;
    }
    _failures++;
    // Doubling from `first`, capped at `ceiling` — and never longer than the
    // settled interval, since retrying while empty should not be rarer than
    // refreshing while working.
    final grown = first * (1 << (_failures - 1).clamp(0, 16));
    final capped = grown > ceiling ? ceiling : grown;
    return capped > settled ? settled : capped;
  }

  /// Forget the failure history — for a manual retry, or a settings change
  /// that makes the previous failures irrelevant.
  void reset() => _failures = 0;
}
