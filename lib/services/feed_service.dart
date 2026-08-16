import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// One entry from an RSS or Atom feed.
class FeedItem {
  final String title;
  final String? summary;
  final DateTime? published;
  final String? link;

  const FeedItem({required this.title, this.summary, this.published, this.link});
}

/// One event from an iCalendar feed.
class CalendarEvent {
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
  final String? location;

  const CalendarEvent({
    required this.title,
    required this.start,
    this.end,
    this.allDay = false,
    this.location,
  });
}

class _Cached<T> {
  _Cached(this.items, this.fetchedAt, this.error);
  final List<T> items;
  final DateTime fetchedAt;
  final String? error;
}

/// Fetches and caches the feeds dashboard widgets read from.
///
/// Keyed by URL rather than by widget, so two widgets pointed at the same
/// feed cost one fetch. Everything is cached and served stale while a refresh
/// is in flight — a dashboard should never flash empty because a news site is
/// slow, and on a panel nobody is watching, a fetch failing is not worth
/// clearing the screen for.
class FeedService extends ChangeNotifier {
  FeedService({Duration? refreshInterval})
      : _refreshInterval = refreshInterval ?? const Duration(minutes: 15);

  final Duration _refreshInterval;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 12),
    responseType: ResponseType.plain,
    headers: const {'User-Agent': 'ImmichKioskPi/1.0'},
  ));

  final Map<String, _Cached<FeedItem>> _feeds = {};
  final Map<String, _Cached<CalendarEvent>> _calendars = {};
  final Set<String> _inFlight = {};
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(_refreshInterval, (_) => refreshAll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _dio.close(force: true);
    super.dispose();
  }

  /// Items for [url], fetching them if they aren't cached yet. Returns
  /// whatever is known now — possibly nothing on the very first call, with a
  /// rebuild to follow once the fetch lands.
  ///
  /// [maxAge] lets a widget ask for fresher content than the default: a news
  /// tile watching a wire service wants minutes, one showing a weekly blog
  /// does not, and there is no reason for either to impose its choice on the
  /// other.
  List<FeedItem> feed(String url, {Duration? maxAge}) {
    if (url.isEmpty) return const [];
    final cached = _feeds[url];
    if (cached == null || _isStale(cached.fetchedAt, maxAge)) _fetchFeed(url);
    return cached?.items ?? const [];
  }

  List<CalendarEvent> calendar(String url) {
    if (url.isEmpty) return const [];
    final cached = _calendars[url];
    if (cached == null || _isStale(cached.fetchedAt)) _fetchCalendar(url);
    return cached?.items ?? const [];
  }

  String? errorFor(String url) =>
      _feeds[url]?.error ?? _calendars[url]?.error;

  bool _isStale(DateTime at, [Duration? maxAge]) =>
      DateTime.now().difference(at) > (maxAge ?? _refreshInterval);

  void refreshAll() {
    for (final url in _feeds.keys.toList()) {
      _fetchFeed(url);
    }
    for (final url in _calendars.keys.toList()) {
      _fetchCalendar(url);
    }
  }

  Future<String?> _get(String url) async {
    try {
      final r = await _dio.get<String>(url);
      return r.data;
    } catch (e) {
      debugPrint('FeedService: $url failed: $e');
      return null;
    }
  }

  Future<void> _fetchFeed(String url) async {
    if (!_inFlight.add(url)) return;
    try {
      final body = await _get(url);
      if (body == null) {
        _feeds[url] = _Cached(
            _feeds[url]?.items ?? const [], DateTime.now(), 'Feed unreachable');
      } else {
        _feeds[url] = _Cached(parseFeed(body), DateTime.now(), null);
      }
      notifyListeners();
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<void> _fetchCalendar(String url) async {
    if (!_inFlight.add(url)) return;
    try {
      // webcal:// is just https:// wearing a hat — it is what Apple and
      // Google hand out for subscription links.
      final fetchUrl = url.replaceFirst(RegExp(r'^webcal://'), 'https://');
      final body = await _get(fetchUrl);
      if (body == null) {
        _calendars[url] = _Cached(_calendars[url]?.items ?? const [],
            DateTime.now(), 'Calendar unreachable');
      } else {
        _calendars[url] = _Cached(parseIcs(body), DateTime.now(), null);
      }
      notifyListeners();
    } finally {
      _inFlight.remove(url);
    }
  }

  /// Blend several feeds into one list.
  ///
  /// Not simply "newest first": a wire service posting every few minutes
  /// would bury a slower feed entirely, and the point of adding a second
  /// source is to see it. So each item is scored on how recent it is *and*
  /// on how many items that feed has already contributed, which lets a
  /// genuinely fresh story from a busy feed still win while a quiet feed's
  /// best item is never crowded out.
  ///
  /// Undated items are treated as a day old — old enough not to lead, recent
  /// enough not to vanish.
  static List<FeedItem> mix(
    List<List<FeedItem>> feeds, {
    required int max,
    DateTime? now,
    double perFeedPenalty = 0.65,
  }) {
    final at = now ?? DateTime.now();
    final scored = <({FeedItem item, double score})>[];

    for (final feed in feeds) {
      final sorted = [...feed]..sort((a, b) {
          final x = a.published, y = b.published;
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return y.compareTo(x);
        });
      for (var i = 0; i < sorted.length; i++) {
        final published = sorted[i].published ?? at.subtract(const Duration(days: 1));
        final hours = at.difference(published).inMinutes / 60.0;
        // Halves roughly every six hours, so today's news leads and
        // yesterday's is still present rather than gone.
        final recency = 1 / (1 + (hours < 0 ? 0 : hours) / 6);
        final fairness = 1 / (1 + i * perFeedPenalty);
        scored.add((item: sorted[i], score: recency * fairness));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    // The same story often appears in two feeds, and twice in one feed is
    // not unheard of either.
    final seen = <String>{};
    final out = <FeedItem>[];
    for (final s in scored) {
      final key = s.item.title.toLowerCase().trim();
      if (!seen.add(key)) continue;
      out.add(s.item);
      if (out.length >= max) break;
    }
    return out;
  }

  /// RSS 2.0 and Atom, which differ enough in element names to be worth
  /// handling separately but not enough to be worth a dependency.
  @visibleForTesting
  static List<FeedItem> parseFeed(String body) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (e) {
      debugPrint('FeedService: malformed feed: $e');
      return const [];
    }

    String? text(XmlElement e, String name) {
      final match = e.findElements(name).firstOrNull;
      return match?.innerText.trim();
    }

    final items = <FeedItem>[];

    for (final item in doc.findAllElements('item')) {
      final title = text(item, 'title');
      if (title == null || title.isEmpty) continue;
      items.add(FeedItem(
        title: _unescape(title),
        summary: _stripHtml(text(item, 'description')),
        published: _parseDate(text(item, 'pubDate')),
        link: text(item, 'link'),
      ));
    }

    for (final entry in doc.findAllElements('entry')) {
      final title = text(entry, 'title');
      if (title == null || title.isEmpty) continue;
      items.add(FeedItem(
        title: _unescape(title),
        summary: _stripHtml(text(entry, 'summary') ?? text(entry, 'content')),
        published:
            _parseDate(text(entry, 'updated') ?? text(entry, 'published')),
        link: entry
            .findElements('link')
            .firstOrNull
            ?.getAttribute('href'),
      ));
    }

    items.sort((a, b) {
      final at = a.published, bt = b.published;
      if (at == null || bt == null) return 0;
      return bt.compareTo(at);
    });
    return items;
  }

  /// The subset of iCalendar a dashboard needs: the summary, when it starts,
  /// when it ends, and whether it is an all-day event.
  ///
  /// Recurrence is not expanded. A repeating event therefore shows on its
  /// first occurrence only, which is wrong often enough to be worth saying
  /// out loud — most published feeds (Google, Apple, Outlook subscription
  /// links) already expand recurrences for you, which is why this is
  /// tolerable rather than merely convenient.
  @visibleForTesting
  static List<CalendarEvent> parseIcs(String body) {
    // Long lines are wrapped with a CRLF and a leading space or tab.
    final unfolded = body.replaceAll(RegExp(r'\r?\n[ \t]'), '');
    final events = <CalendarEvent>[];

    String? summary, location;
    DateTime? start, end;
    var allDay = false;
    var inEvent = false;

    for (final raw in unfolded.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line == 'BEGIN:VEVENT') {
        inEvent = true;
        summary = location = null;
        start = end = null;
        allDay = false;
        continue;
      }
      if (!inEvent) continue;
      if (line == 'END:VEVENT') {
        inEvent = false;
        if (summary != null && start != null) {
          events.add(CalendarEvent(
            title: summary,
            start: start,
            end: end,
            allDay: allDay,
            location: location,
          ));
        }
        continue;
      }

      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon);
      final value = line.substring(colon + 1);
      final key = name.split(';').first.toUpperCase();

      switch (key) {
        case 'SUMMARY':
          summary = _unescapeIcs(value);
        case 'LOCATION':
          location = _unescapeIcs(value);
        case 'DTSTART':
          allDay = name.toUpperCase().contains('VALUE=DATE') &&
              !name.toUpperCase().contains('DATE-TIME');
          start = _parseIcsDate(value);
        case 'DTEND':
          end = _parseIcsDate(value);
      }
    }

    events.sort((a, b) => a.start.compareTo(b.start));
    return events;
  }

  static DateTime? _parseIcsDate(String v) {
    final s = v.trim();
    // 20260812  |  20260812T090000  |  20260812T090000Z
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$')
        .firstMatch(s);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = int.tryParse(m.group(4) ?? '') ?? 0;
    final minute = int.tryParse(m.group(5) ?? '') ?? 0;
    final second = int.tryParse(m.group(6) ?? '') ?? 0;
    final utc = m.group(7) != null;
    final dt = utc
        ? DateTime.utc(year, month, day, hour, minute, second).toLocal()
        : DateTime(year, month, day, hour, minute, second);
    return dt;
  }

  static String _unescapeIcs(String v) => v
      .replaceAll(r'\,', ',')
      .replaceAll(r'\;', ';')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\\', r'\');

  /// Decodes the HTML entities feeds arrive full of.
  ///
  /// Named ones first, then numeric, which is also what unpicks the
  /// double-encoding feeds are prone to: `&amp;#038;` becomes `&#038;` on the
  /// first pass and `&` on the second.
  ///
  /// The numeric pass matters more than it looks. Feeds are full of `&#8217;`
  /// for an apostrophe and `&#8211;` for a dash, and a headline reading
  /// "Simpsons: Hit &#038; Run" on the wall is the sort of thing you notice
  /// every time you walk past it.
  static String _unescape(String v) {
    final named = v
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        // Ampersand last of the named ones: doing it first would turn
        // "&amp;lt;" into a working "<" that was never meant to be one.
        .replaceAll('&amp;', '&');

    return named.replaceAllMapped(
      RegExp(r'&#(x?)([0-9a-fA-F]+);'),
      (m) {
        final hex = m[1]!.isNotEmpty;
        final code = int.tryParse(m[2]!, radix: hex ? 16 : 10);
        // Anything outside Unicode, or a control character, is left as it was
        // rather than turned into something unprintable.
        if (code == null || code < 0x20 || code > 0x10FFFF) return m[0]!;
        return String.fromCharCode(code);
      },
    );
  }

  static String? _stripHtml(String? v) {
    if (v == null || v.isEmpty) return null;
    final text = _unescape(v.replaceAll(RegExp(r'<[^>]*>'), ' '))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.isEmpty ? null : text;
  }

  static DateTime? _parseDate(String? v) {
    if (v == null || v.isEmpty) return null;
    final iso = DateTime.tryParse(v);
    if (iso != null) return iso.toLocal();
    // RFC 822, as RSS uses: "Mon, 10 Aug 2026 07:11:00 +0100"
    final m = RegExp(
            r'(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?')
        .firstMatch(v);
    if (m == null) return null;
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final month = months[m.group(2)!.toLowerCase()];
    if (month == null) return null;
    return DateTime(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.tryParse(m.group(6) ?? '') ?? 0,
    );
  }
}
