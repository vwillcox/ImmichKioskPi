import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/feed_service.dart';

void main() {
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
}
