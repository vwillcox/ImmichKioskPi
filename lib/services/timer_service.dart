import 'dart:async';

import 'package:flutter/foundation.dart';

/// One kitchen timer.
class KioskTimer {
  KioskTimer({
    required this.id,
    required this.label,
    required this.total,
    required DateTime now,
    this.sound = 'none',
    this.speaks = true,
  }) : _endsAt = now.add(total);

  final int id;
  final String label;
  final Duration total;

  /// What it plays when it is done — a [TimerSounds] id — and whether it
  /// then says which timer it was.
  final String sound;
  final bool speaks;

  DateTime? _endsAt;
  Duration? _pausedWith;
  DateTime? finishedAt;

  bool get paused => _pausedWith != null;
  bool get finished => finishedAt != null;

  Duration remaining(DateTime now) {
    if (finished) return Duration.zero;
    if (_pausedWith != null) return _pausedWith!;
    final left = _endsAt!.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Share of the time still to run, 1 at the start and 0 when done.
  double fraction(DateTime now) => total.inMilliseconds <= 0
      ? 0
      : remaining(now).inMilliseconds / total.inMilliseconds;
}

/// Kitchen timers for the dashboard.
///
/// Owned above the dashboard rather than by its widget, so a timer keeps
/// running — and still speaks when it is done — after the panel has gone
/// back to the photos. Ticks only while a timer is running.
class TimerService extends ChangeNotifier {
  TimerService({
    this.speak,
    this.play,
    this.silence,
    this.onFinished,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Says a finished timer out loud. The kiosk's own voice, the one shares
  /// are read in.
  final Future<void> Function(String text)? speak;

  /// Plays a finished timer's sound, returning once it has been heard, so
  /// the voice comes after it rather than on top of it.
  final Future<void> Function(String sound)? play;

  /// Stops a sound part-way, when the timer making it is dismissed.
  final Future<void> Function()? silence;

  /// Brings the panel up when a timer goes off.
  final Future<void> Function()? onFinished;

  final DateTime Function() _clock;

  /// How often a finished timer repeats itself until someone taps it, and
  /// how many times before it gives up.
  static const repeatEvery = Duration(seconds: 30);
  static const maxAnnouncements = 4;

  final List<KioskTimer> _timers = [];
  final Map<int, int> _announced = {};
  Timer? _ticker;
  int _ids = 0;

  List<KioskTimer> get timers => List.unmodifiable(_timers);
  DateTime get now => _clock();

  KioskTimer start(
    Duration length, {
    String label = '',
    String sound = 'none',
    bool speaks = true,
  }) {
    final t = KioskTimer(
      id: ++_ids,
      label: label.trim().isEmpty ? describe(length) : label.trim(),
      total: length,
      now: _clock(),
      sound: sound,
      speaks: speaks,
    );
    _timers.add(t);
    _ensureTicking();
    notifyListeners();
    return t;
  }

  void togglePause(int id) {
    final t = _find(id);
    if (t == null || t.finished) return;
    final now = _clock();
    if (t.paused) {
      t._endsAt = now.add(t._pausedWith!);
      t._pausedWith = null;
    } else {
      t._pausedWith = t.remaining(now);
    }
    _ensureTicking();
    notifyListeners();
  }

  void addTime(int id, Duration extra) {
    final t = _find(id);
    if (t == null) return;
    final now = _clock();
    if (t.finished) {
      // Snoozing a finished timer starts it again with the extra time.
      t.finishedAt = null;
      _announced.remove(id);
      t._endsAt = now.add(extra);
    } else if (t.paused) {
      t._pausedWith = t._pausedWith! + extra;
    } else {
      t._endsAt = t._endsAt!.add(extra);
    }
    _ensureTicking();
    notifyListeners();
  }

  /// Stop and forget one — a cancel while running, a dismissal once done.
  void remove(int id) {
    final t = _find(id);
    // A tap on a ringing timer should stop the ringing, not just the ring.
    if (t != null && t.finished && t.sound != 'none') {
      unawaited(silence?.call());
    }
    _timers.removeWhere((t) => t.id == id);
    _announced.remove(id);
    if (_timers.isEmpty) _stopTicking();
    notifyListeners();
  }

  KioskTimer? _find(int id) {
    for (final t in _timers) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _ensureTicking() {
    _ticker ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => tick(),
    );
  }

  void _stopTicking() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Advances every timer to now. Public so tests can step a fake clock.
  @visibleForTesting
  void tick() {
    final now = _clock();
    for (final t in _timers) {
      if (!t.finished && !t.paused && !t._endsAt!.isAfter(now)) {
        t.finishedAt = now;
        unawaited(onFinished?.call());
      }
      if (t.finished) _maybeAnnounce(t, now);
    }
    // Nothing left counting down, and nothing left to announce: no reason to
    // wake up four times a second.
    final busy = _timers.any(
      (t) =>
          (!t.finished && !t.paused) ||
          (t.finished && (_announced[t.id] ?? 0) < maxAnnouncements),
    );
    if (!busy) _stopTicking();
    notifyListeners();
  }

  void _maybeAnnounce(KioskTimer t, DateTime now) {
    final count = _announced[t.id] ?? 0;
    if (count >= maxAnnouncements) return;
    final due = t.finishedAt!.add(repeatEvery * count);
    if (now.isBefore(due)) return;
    _announced[t.id] = count + 1;
    unawaited(_announce(t));
  }

  /// The sound, then the voice. With no sound, the voice starts at once.
  Future<void> _announce(KioskTimer t) async {
    final play = this.play;
    if (play != null && t.sound != 'none') {
      try {
        await play(t.sound);
      } catch (e) {
        debugPrint('Timer sound: $e');
      }
      // Dismissed while it was ringing: nobody needs telling now.
      if (_find(t.id) == null) return;
    }
    if (t.speaks) await speak?.call(announcement(t));
  }

  static String announcement(KioskTimer t) {
    final name = t.label;
    // "5 minutes" reads badly as "the 5 minutes timer".
    final generic = RegExp(r'^\d').hasMatch(name);
    return generic
        ? 'Your ${name.replaceAll('minutes', 'minute').replaceAll('hours', 'hour')} timer is done.'
        : 'The ${name.toLowerCase()} timer is done.';
  }

  /// "5 minutes", "1 hour 30", "45 seconds".
  static String describe(Duration d) {
    if (d.inMinutes == 0) return '${d.inSeconds} seconds';
    if (d.inHours == 0) {
      return d.inMinutes == 1 ? '1 minute' : '${d.inMinutes} minutes';
    }
    final m = d.inMinutes % 60;
    final h = d.inHours == 1 ? '1 hour' : '${d.inHours} hours';
    return m == 0 ? h : '$h $m';
  }

  @override
  void dispose() {
    _stopTicking();
    super.dispose();
  }
}

/// A preset the widget offers: "Eggs=7" is a timer called Eggs for seven
/// minutes; a bare "10" is ten minutes; "90s" is ninety seconds.
@immutable
class TimerPreset {
  const TimerPreset(this.label, this.length);

  final String label;
  final Duration length;

  static List<TimerPreset> parse(String spec) {
    final out = <TimerPreset>[];
    for (final raw in spec.split(RegExp(r'[,;\n]'))) {
      final part = raw.trim();
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final name = eq < 0 ? '' : part.substring(0, eq).trim();
      final length = _length(eq < 0 ? part : part.substring(eq + 1));
      if (length == null || length <= Duration.zero) continue;
      out.add(TimerPreset(name, length));
    }
    return out;
  }

  static Duration? _length(String s) {
    final m = RegExp(
      r'^\s*(\d+(?:\.\d+)?)\s*(s|sec|secs|m|min|mins|h|hr|hrs)?\s*$',
      caseSensitive: false,
    ).firstMatch(s);
    if (m == null) return null;
    final n = double.parse(m[1]!);
    final unit = (m[2] ?? 'm').toLowerCase();
    final seconds = unit.startsWith('s')
        ? n
        : unit.startsWith('h')
        ? n * 3600
        : n * 60;
    return Duration(seconds: seconds.round());
  }

  /// What the chip says: the name if it has one, else the length.
  String get chip {
    if (label.isNotEmpty) return label;
    // Seconds whenever it is not whole minutes: "1 min" for ninety seconds
    // would be a lie.
    if (length.inSeconds < 60 || length.inSeconds % 60 != 0) {
      return '${length.inSeconds}s';
    }
    if (length.inMinutes < 60 || length.inMinutes % 60 != 0) {
      return '${length.inMinutes} min';
    }
    return '${length.inHours}h';
  }
}
