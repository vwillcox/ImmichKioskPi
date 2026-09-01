import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/feed_service.dart';

void main() {
  _entities();
  group('RSS and Atom', () {
    test('reads RSS items, newest first', () {
      final items = FeedService.parseFeed('''
<rss version="2.0"><channel>
  <item><title>Older</title><description>&lt;p&gt;Some &amp;amp; markup&lt;/p&gt;</description>
    <pubDate>Sun, 09 Aug 2026 08:00:00 +0000</pubDate><link>http://a</link></item>
  <item><title>Newer</title><pubDate>Mon, 10 Aug 2026 09:30:00 +0000</pubDate></item>
</channel></rss>''');
      expect(items.map((i) => i.title), ['Newer', 'Older']);
      expect(items[1].summary, 'Some & markup');
      expect(items[1].link, 'http://a');
    });

    test('reads Atom entries', () {
      final items = FeedService.parseFeed('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>Hello</title><updated>2026-08-10T09:30:00Z</updated>
    <link href="http://b"/></entry>
</feed>''');
      expect(items.single.title, 'Hello');
      expect(items.single.link, 'http://b');
    });

    test('malformed XML yields nothing rather than throwing', () {
      expect(FeedService.parseFeed('<rss><channel><item>'), isEmpty);
    });
  });

  group('iCalendar', () {
    test('reads events and sorts them by start', () {
      final events = FeedService.parseIcs('''
BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:Later thing
DTSTART:20260812T140000Z
DTEND:20260812T150000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:Earlier thing
LOCATION:The shed
DTSTART:20260811T090000Z
END:VEVENT
END:VCALENDAR''');
      expect(events.map((e) => e.title), ['Earlier thing', 'Later thing']);
      expect(events.first.location, 'The shed');
    });

    test('unfolds wrapped lines and unescapes text', () {
      final events = FeedService.parseIcs(
          'BEGIN:VEVENT\r\nSUMMARY:A very long title that got\r\n  wrapped\\, twice\r\n'
          'DTSTART:20260811T090000Z\r\nEND:VEVENT');
      expect(events.single.title, 'A very long title that got wrapped, twice');
    });

    test('recognises all-day events', () {
      final events = FeedService.parseIcs(
          'BEGIN:VEVENT\nSUMMARY:Birthday\nDTSTART;VALUE=DATE:20260811\nEND:VEVENT');
      expect(events.single.allDay, isTrue);
      expect(events.single.start.day, 11);
    });

    test('an event with no start is skipped rather than guessed at', () {
      final events =
          FeedService.parseIcs('BEGIN:VEVENT\nSUMMARY:Whenever\nEND:VEVENT');
      expect(events, isEmpty);
    });
  });

  mixTests();
}

FeedItem item(String title, {Duration? old}) => FeedItem(
      title: title,
      published: old == null ? null : DateTime(2026, 8, 14, 12).subtract(old),
    );

void mixTests() {
  final now = DateTime(2026, 8, 14, 12);

  group('blending several feeds', () {
    test('a busy feed cannot crowd out a quieter one', () {
      final busy = [
        for (var i = 0; i < 10; i++)
          item('busy $i', old: Duration(minutes: i * 5)),
      ];
      final quiet = [item('quiet', old: const Duration(hours: 2))];

      final mixed = FeedService.mix([busy, quiet], max: 5, now: now);
      expect(mixed.map((i) => i.title), contains('quiet'),
          reason: 'the quiet feed must get a look-in');
      expect(mixed.first.title, 'busy 0',
          reason: 'but the freshest item still leads');
    });

    test('recency beats feed order', () {
      final stale = [item('old news', old: const Duration(days: 3))];
      final fresh = [item('breaking', old: const Duration(minutes: 2))];
      final mixed = FeedService.mix([stale, fresh], max: 2, now: now);
      expect(mixed.first.title, 'breaking');
    });

    test('the same story from two feeds appears once', () {
      final a = [item('Shared headline', old: const Duration(hours: 1))];
      final b = [item('shared headline  ', old: const Duration(hours: 2))];
      final mixed = FeedService.mix([a, b], max: 5, now: now);
      expect(mixed.length, 1);
    });

    test('undated items rank below today but are not discarded', () {
      final dated = [item('today', old: const Duration(hours: 1))];
      final undated = [item('whenever')];
      final mixed = FeedService.mix([dated, undated], max: 5, now: now);
      expect(mixed.first.title, 'today');
      expect(mixed.map((i) => i.title), contains('whenever'));
    });

    test('never returns more than asked for', () {
      final a = [for (var i = 0; i < 20; i++) item('a$i', old: Duration(hours: i))];
      final b = [for (var i = 0; i < 20; i++) item('b$i', old: Duration(hours: i))];
      expect(FeedService.mix([a, b], max: 4, now: now).length, 4);
    });
  });
}

/// Entities in feed titles.
///
/// Note what the XML parser already does: a well-formed `&#038;` is decoded
/// to `&` before this code ever sees it. The case that reaches [_unescape] is
/// **double** encoding — `&amp;#038;` in the document, which XML turns into
/// the literal text `&#038;` — and that is what was showing on the panel.
void _entities() {
  String titleOf(String rawXml) => FeedService.parseFeed(
        '<rss><channel><item><title>$rawXml</title></item></channel></rss>',
      ).single.title;

  group('HTML entities in feed titles', () {
    test('double-encoded numeric entities are decoded', () {
      // The one seen on the wall: "Simpsons: Hit &#038; Run".
      expect(titleOf('Simpsons: Hit &amp;#038; Run'), 'Simpsons: Hit & Run');
    });

    test('the punctuation feeds actually use', () {
      expect(titleOf('It&amp;#8217;s here'), 'It\u2019s here');
      expect(titleOf('Nine &amp;#8211; ten'), 'Nine \u2013 ten');
    });

    test('hex entities too', () {
      expect(titleOf('A &amp;#x26; B'), 'A & B');
    });

    test('plain named entities still work', () {
      expect(titleOf('Fish &amp;amp; chips'), 'Fish & chips');
    });

    test('an ampersand-first pass would break escaped markup', () {
      // "&amp;lt;" is a literal "&lt;", not a "<". Decoding the ampersand
      // before the angle brackets would silently turn one into the other.
      expect(titleOf('&amp;amp;lt;'), '&lt;');
    });

    test('nonsense is left alone rather than mangled', () {
      expect(titleOf('100&amp;#; off'), '100&#; off');
      // Beyond the Unicode range — decoding this would throw.
      expect(titleOf('&amp;#99999999;'), '&#99999999;');
    });
  });
}
