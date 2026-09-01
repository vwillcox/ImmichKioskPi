import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/services/tts_service.dart';

void main() {
  _parts();
  group('what actually gets said', () {
    test('a plain note is read as written', () {
      expect(TtsService.tidy('Dinner is ready'), 'Dinner is ready');
    });

    test('a URL becomes "a link" rather than being spelt out', () {
      // Reading "h-t-t-p-s-colon-slash-slash..." aloud is worse than useless.
      expect(
        TtsService.tidy('Look at https://example.com/a/b?c=1 now'),
        'Look at a link now',
      );
    });

    test('newlines and runs of spaces collapse', () {
      expect(TtsService.tidy('one\n\n  two\t three'), 'one two three');
    });

    test('a very long note is cut short and says so', () {
      final long = List.filled(400, 'word').join(' ');
      final said = TtsService.tidy(long);
      expect(said.length, lessThan(700));
      expect(said, contains('more on screen'));
    });

    test('nothing to say stays nothing', () {
      expect(TtsService.tidy('   \n  '), isEmpty);
      expect(TtsService.tidy(''), isEmpty);
    });
  });

  group('the announcement', () {
    test('names the sender by default', () {
      expect(
        TtsService.announcement('Dinner is ready', 'Jo'),
        'Message from Jo. Dinner is ready',
      );
    });

    test('can be told not to', () {
      expect(
        TtsService.announcement('Dinner is ready', 'Jo', withSender: false),
        'Dinner is ready',
      );
    });

    test('an unnamed sender is not announced as nobody', () {
      expect(TtsService.announcement('Hello', '  '), 'Hello');
    });

    test('an empty note produces nothing to say, sender or not', () {
      // Guards against announcing "Message from Jo." and then silence.
      expect(TtsService.announcement('', 'Jo'), isEmpty);
      expect(TtsService.announcement('   ', 'Jo'), isEmpty);
    });
  });
}

void _parts() {
  group('the announcement is said as two statements', () {
    test('sender and note are separate utterances', () {
      // Separate so a real pause can sit between them; piper takes no SSML,
      // and a full stop only buys a mid-paragraph pause.
      expect(
        TtsService.announcementParts('Dinner is ready', 'Jo'),
        ['Message from Jo.', 'Dinner is ready'],
      );
    });

    test('without the sender it is one part', () {
      expect(
        TtsService.announcementParts('Dinner is ready', 'Jo', withSender: false),
        ['Dinner is ready'],
      );
    });

    test('an unnamed sender is not announced', () {
      expect(TtsService.announcementParts('Hello', '   '), ['Hello']);
    });

    test('an empty note says nothing at all, not just the name', () {
      expect(TtsService.announcementParts('', 'Jo'), isEmpty);
      expect(TtsService.announcementParts('  \n ', 'Jo'), isEmpty);
    });

    test('the gap is long enough to hear as a break', () {
      expect(TtsService.announcementGap.inMilliseconds,
          greaterThanOrEqualTo(600));
    });
  });
}
