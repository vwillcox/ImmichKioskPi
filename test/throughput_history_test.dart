import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/services/throughput_history.dart';

void main() {
  group('sampling', () {
    test('the newest sample is what the big numbers read', () {
      final h = ThroughputHistory();
      h.add(1000, 2000);
      h.add(3000, 4000);
      expect(h.latest!.tx, 3000);
      expect(h.latest!.rx, 4000);
    });

    test('a day at one sample a second does not keep 86,400 points', () {
      // The reason buckets exist. Two hours of seconds is 7,200 samples; the
      // live buffer holds ten minutes and the rest becomes minute buckets.
      final h = ThroughputHistory(retention: const Duration(hours: 24));
      final start = DateTime(2026, 1, 1, 12);
      for (var i = 0; i < 7200; i++) {
        h.add(1000, 2000, at: start.add(Duration(seconds: i)));
      }
      // 120 minutes of buckets, not 7,200 samples.
      expect(
          h
              .series(const Duration(hours: 2), 10000,
                  now: start.add(const Duration(seconds: 7200)))
              .length,
          lessThanOrEqualTo(121));
    });

    test('history older than the retention is dropped', () {
      final h = ThroughputHistory(retention: const Duration(minutes: 10));
      final start = DateTime(2026, 1, 1, 12);
      for (var i = 0; i < 60; i++) {
        h.add(1000, 1000, at: start.add(Duration(minutes: i)));
      }
      // The last sample sets "now" for trimming, so only the final ten
      // minutes of buckets survive.
      expect(
          h
              .series(const Duration(hours: 1), 1000,
                  now: start.add(const Duration(minutes: 59)))
              .length,
          lessThanOrEqualTo(11));
    });
  });

  group('downsampling to what a graph can draw', () {
    final start = DateTime(2026, 1, 1, 6);
    DateTime endOf(int count) => start.add(Duration(minutes: count));

    ThroughputHistory withMinutes(int count, {double Function(int)? rx}) {
      final h = ThroughputHistory(retention: const Duration(hours: 24));
      for (var i = 0; i < count; i++) {
        h.add(1000, rx?.call(i) ?? 1000, at: start.add(Duration(minutes: i)));
      }
      return h;
    }

    test('never returns more points than asked for', () {
      final h = withMinutes(600);
      expect(h.series(const Duration(hours: 24), 100, now: endOf(600)).length,
          lessThanOrEqualTo(100));
    });

    test('a spike survives being squeezed into fewer columns', () {
      // Averaging would hide this, which is the whole point: a busy evening
      // must not be smoothed into a quiet one.
      final h = withMinutes(600, rx: (i) => i == 300 ? 900000000 : 1000);
      final points =
          h.series(const Duration(hours: 24), 50, now: endOf(600));
      final peak = points.map((p) => p.rx).reduce((a, b) => a > b ? a : b);
      expect(peak, 900000000);
    });

    test('asking for fewer points than exist still yields a usable series', () {
      final h = withMinutes(600);
      expect(h.series(const Duration(hours: 24), 2, now: endOf(600)).length,
          greaterThan(1));
    });

    test('an empty history yields nothing rather than throwing', () {
      final h = ThroughputHistory();
      expect(h.series(const Duration(hours: 1), 100), isEmpty);
      expect(h.peak(const Duration(hours: 1)), 0);
      expect(h.latest, isNull);
      expect(h.isEmpty, isTrue);
    });
  });

  group('volume', () {
    test('adds up from the minute means', () {
      final h = ThroughputHistory(retention: const Duration(hours: 24));
      final start = DateTime(2026, 1, 1, 6);
      // 8 Mb/s for 10 minutes = 1 MB/s × 600s = 600 MB.
      for (var i = 0; i < 10; i++) {
        h.add(0, 8000000, at: start.add(Duration(minutes: i)));
      }
      final v = h.volume(const Duration(hours: 1),
          now: start.add(const Duration(minutes: 10)));
      expect(v.rxBytes, closeTo(600000000, 1000000));
      expect(v.txBytes, 0);
    });
  });

  group('formatting', () {
    test('bytes read as a person would say them', () {
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1500), '2 kB');
      expect(formatBytes(5000000), '5 MB');
      expect(formatBytes(2500000000), '2.5 GB');
      expect(formatBytes(3000000000000), '3.00 TB');
    });
  });
}
