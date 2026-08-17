import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'unifi_models.dart';

/// One minute of throughput, reduced to what a graph can use.
///
/// Peak as well as mean because they answer different questions: the mean says
/// how much was moved, the peak says whether the line was ever saturated. On a
/// domestic connection the peak is usually the interesting one.
class ThroughputBucket {
  ThroughputBucket(this.minute);

  /// Truncated to the minute, so samples land in the same bucket regardless of
  /// when within it they arrived.
  final DateTime minute;

  double peakTx = 0;
  double peakRx = 0;
  double _sumTx = 0;
  double _sumRx = 0;
  int _count = 0;

  void add(double tx, double rx) {
    peakTx = math.max(peakTx, tx);
    peakRx = math.max(peakRx, rx);
    _sumTx += tx;
    _sumRx += rx;
    _count++;
  }

  double get meanTx => _count == 0 ? 0 : _sumTx / _count;
  double get meanRx => _count == 0 ? 0 : _sumRx / _count;
  int get samples => _count;
}

/// A point ready to plot.
class ThroughputPoint {
  const ThroughputPoint(this.at, this.tx, this.rx);
  final DateTime at;
  final double tx;
  final double rx;
}

/// WAN throughput over time, at two resolutions.
///
/// Its own notifier rather than part of [UnifiService] so that sampling every
/// second rebuilds the graph and nothing else. Sharing the service's notifier
/// would rebuild the client list, the device list and the health panel once a
/// second too, for data none of them use.
///
/// Two resolutions because one cannot serve both ends. A day at one sample a
/// second is 86,400 points, which is both more memory than it deserves and far
/// more than any graph can draw; a day of per-minute buckets is 1,440, which is
/// still more than the pixels available. So recent seconds are kept verbatim
/// for a live trace, completed minutes are aggregated for the history, and the
/// graph asks for however many points it can actually plot.
class ThroughputHistory extends ChangeNotifier {
  ThroughputHistory({this.retention = const Duration(hours: 24)});

  /// How far back to keep minute buckets. Set from configuration.
  Duration retention;

  /// Full-rate samples, for the last few minutes.
  final List<ThroughputPoint> _live = [];

  /// One entry per minute, oldest first.
  final List<ThroughputBucket> _buckets = [];

  /// Ten minutes at one sample a second. Enough for a live trace; beyond this
  /// the buckets take over and the extra precision is invisible.
  static const int _maxLive = 600;

  DateTime? _lastSampleAt;
  DateTime? get lastSampleAt => _lastSampleAt;

  bool get isEmpty => _live.isEmpty && _buckets.isEmpty;

  /// The most recent reading, for the big numbers above the graph.
  ThroughputPoint? get latest => _live.isEmpty ? null : _live.last;

  /// How much history there actually is, which is not the same as the
  /// retention — a panel up for ten minutes has ten minutes.
  Duration get span {
    final first =
        _buckets.isNotEmpty ? _buckets.first.minute : _live.firstOrNull?.at;
    final last = _lastSampleAt;
    if (first == null || last == null) return Duration.zero;
    // Measured between the oldest and newest readings rather than against the
    // wall clock, so a panel that has been asleep does not claim hours of
    // history it never recorded.
    return last.difference(first);
  }

  void add(double txBps, double rxBps, {DateTime? at}) {
    final now = at ?? DateTime.now();
    _lastSampleAt = now;

    _live.add(ThroughputPoint(now, txBps, rxBps));
    if (_live.length > _maxLive) {
      _live.removeRange(0, _live.length - _maxLive);
    }

    final minute = DateTime(now.year, now.month, now.day, now.hour, now.minute);
    if (_buckets.isEmpty || _buckets.last.minute.isBefore(minute)) {
      _buckets.add(ThroughputBucket(minute));
    }
    _buckets.last.add(txBps, rxBps);

    _trim(now);
    notifyListeners();
  }

  void _trim(DateTime now) {
    final cutoff = now.subtract(retention);
    while (_buckets.isNotEmpty && _buckets.first.minute.isBefore(cutoff)) {
      _buckets.removeAt(0);
    }
  }

  /// Points to plot for [window], at most [maxPoints] of them.
  ///
  /// The graph passes its own width, so what comes back is already the
  /// resolution the screen can show — there is no sense handing a 400-pixel
  /// widget 1,440 values and letting it overdraw the same columns.
  ///
  /// Peaks rather than means when downsampling: averaging away a burst makes a
  /// busy evening look quiet, which is the opposite of useful.
  List<ThroughputPoint> series(Duration window, int maxPoints, {DateTime? now}) {
    // The clock is injectable for the same reason FeedService.mix takes one:
    // a window is relative to "now", and a test that cannot say when now is
    // cannot test a window at all.
    final at = now ?? _lastSampleAt ?? DateTime.now();
    final from = at.subtract(window);

    // A short window is served from the live samples, which is what makes the
    // graph move visibly second by second.
    final source = window <= const Duration(minutes: 10)
        ? _live.where((p) => p.at.isAfter(from)).toList()
        : _buckets
            .where((b) => b.minute.isAfter(from))
            .map((b) => ThroughputPoint(b.minute, b.peakTx, b.peakRx))
            .toList();

    if (source.length <= maxPoints || maxPoints <= 1) return source;

    // Reduce by taking the peak of each group, so a spike survives being
    // squeezed into fewer columns.
    final out = <ThroughputPoint>[];
    final per = source.length / maxPoints;
    for (var i = 0; i < maxPoints; i++) {
      final start = (i * per).floor();
      final end = math.min(source.length, ((i + 1) * per).ceil());
      if (start >= end) continue;
      var tx = 0.0, rx = 0.0;
      for (var j = start; j < end; j++) {
        tx = math.max(tx, source[j].tx);
        rx = math.max(rx, source[j].rx);
      }
      out.add(ThroughputPoint(source[start].at, tx, rx));
    }
    return out;
  }

  /// The highest rate seen in [window], for labelling the scale.
  double peak(Duration window, {DateTime? now}) {
    var peak = 0.0;
    for (final p in series(window, 2000, now: now)) {
      peak = math.max(peak, math.max(p.tx, p.rx));
    }
    return peak;
  }

  /// Total moved over [window], from the minute means — a figure the live
  /// samples cannot give, since they only cover the last few minutes.
  ({double txBytes, double rxBytes}) volume(Duration window, {DateTime? now}) {
    final at = now ?? _lastSampleAt ?? DateTime.now();
    final from = at.subtract(window);
    var tx = 0.0, rx = 0.0;
    for (final b in _buckets) {
      if (b.minute.isBefore(from)) continue;
      // Mean bits per second over a minute, as bytes.
      tx += b.meanTx * 60 / 8;
      rx += b.meanRx * 60 / 8;
    }
    return (txBytes: tx, rxBytes: rx);
  }

  void clear() {
    _live.clear();
    _buckets.clear();
    _lastSampleAt = null;
    notifyListeners();
  }
}

/// Bytes as something readable, for the volume line.
String formatBytes(double bytes) {
  if (bytes >= 1e12) return '${(bytes / 1e12).toStringAsFixed(2)} TB';
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(0)} MB';
  if (bytes >= 1e3) return '${(bytes / 1e3).toStringAsFixed(0)} kB';
  return '${bytes.toStringAsFixed(0)} B';
}
