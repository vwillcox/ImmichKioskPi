import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/services/retry_schedule.dart';

void main() {
  RetrySchedule fresh() => RetrySchedule(
        settled: const Duration(minutes: 15),
        first: const Duration(seconds: 4),
        ceiling: const Duration(seconds: 60),
      );

  group('while there is nothing to show', () {
    test('the first retry is soon, not a whole interval away', () {
      // The fault this exists for: a panel that started before the network
      // sat on an error for fifteen minutes.
      expect(fresh().next(hasContent: false), const Duration(seconds: 4));
    });

    test('it backs off rather than hammering', () {
      final r = fresh();
      final delays = [
        for (var i = 0; i < 5; i++) r.next(hasContent: false).inSeconds,
      ];
      expect(delays, [4, 8, 16, 32, 60]);
    });

    test('it never backs off past the ceiling', () {
      final r = fresh();
      for (var i = 0; i < 30; i++) {
        r.next(hasContent: false);
      }
      expect(r.next(hasContent: false), const Duration(seconds: 60));
    });

    test('retrying is never rarer than the ordinary refresh', () {
      // A short settled interval must not be overtaken by the backoff — an
      // empty panel should not check less often than a working one.
      final r = RetrySchedule(
        settled: const Duration(seconds: 10),
        first: const Duration(seconds: 4),
        ceiling: const Duration(minutes: 5),
      );
      for (var i = 0; i < 10; i++) {
        expect(r.next(hasContent: false).inSeconds, lessThanOrEqualTo(10));
      }
    });
  });

  group('once there is content', () {
    test('it settles to the ordinary interval', () {
      final r = fresh();
      r.next(hasContent: false);
      r.next(hasContent: false);
      expect(r.next(hasContent: true), const Duration(minutes: 15));
    });

    test('the backoff is forgotten, so a later outage starts short again', () {
      final r = fresh();
      for (var i = 0; i < 6; i++) {
        r.next(hasContent: false);
      }
      r.next(hasContent: true);
      // Back to the beginning rather than resuming at a minute.
      expect(r.next(hasContent: false), const Duration(seconds: 4));
    });

    test('failures are counted only while empty', () {
      final r = fresh();
      r.next(hasContent: false);
      r.next(hasContent: false);
      expect(r.failures, 2);
      r.next(hasContent: true);
      expect(r.failures, 0);
    });
  });

  test('reset clears the history', () {
    final r = fresh();
    for (var i = 0; i < 4; i++) {
      r.next(hasContent: false);
    }
    r.reset();
    expect(r.next(hasContent: false), const Duration(seconds: 4));
  });
}
