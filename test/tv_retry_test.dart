import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/config/app_config.dart';
import 'package:immich_kiosk_pi/services/config_service.dart';
import 'package:immich_kiosk_pi/services/retry_schedule.dart';
import 'package:immich_kiosk_pi/services/tv_service.dart';

/// The backoff TvService is built with.
RetrySchedule asBuilt() => RetrySchedule(
      settled: const Duration(seconds: 60),
      first: const Duration(seconds: 4),
      ceiling: const Duration(seconds: 60),
    );

void main() {
  group('the backoff between attempts', () {
    test('starts quickly and settles at a minute', () {
      final s = asBuilt();
      final waits = [
        for (var i = 0; i < 7; i++) s.next(hasContent: false).inSeconds
      ];
      expect(waits, [4, 8, 16, 32, 60, 60, 60]);
    });

    test('a minute is the longest gap, however long it has been down', () {
      final s = asBuilt();
      for (var i = 0; i < 500; i++) {
        expect(s.next(hasContent: false).inSeconds, lessThanOrEqualTo(60));
      }
    });

    test('the settled interval never clamps the backoff below the ceiling', () {
      // The guard on someone lowering `settled` later: RetrySchedule caps the
      // wait at it, and a connection has no ordinary refresh interval to
      // borrow, so the two have to match.
      final s = asBuilt();
      s.next(hasContent: false);
      s.next(hasContent: false);
      s.next(hasContent: false);
      s.next(hasContent: false);
      expect(s.next(hasContent: false), const Duration(seconds: 60));
    });
  });

  group('a television that is not set up', () {
    late ConfigService config;
    late TvService tv;

    setUp(() {
      config = ConfigService();
      tv = TvService(config);
    });

    tearDown(() => tv.dispose());

    test('costs nothing to ask: no socket, no timer, no error on screen',
        () async {
      config.config.tv = TvSettings(enabled: true, host: '', uuid: '');
      await tv.connect();
      expect(tv.conn, ConnState.disconnected);
      expect(tv.retryPending, isFalse,
          reason: 'a blank address is not something to keep trying');
      expect(tv.lastError, isNull);
    });

    test('switched off in settings, it stays off', () async {
      config.config.tv = TvSettings(
          enabled: false, host: '192.0.2.1', uuid: '02:10:ac:92:12:52');
      await tv.connect();
      expect(tv.conn, ConnState.disconnected);
      expect(tv.retryPending, isFalse);
    });

    test('asked to stop, it stops asking', () async {
      config.config.tv = TvSettings(enabled: true, host: '', uuid: '');
      await tv.connect();
      tv.disconnect();
      expect(tv.conn, ConnState.disconnected);
      expect(tv.retryPending, isFalse);
    });
  });
}
