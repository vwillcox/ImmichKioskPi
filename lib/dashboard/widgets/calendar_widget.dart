import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/feed_service.dart';
import '../dashboard_theme.dart';
import '../widget_registry.dart';

/// One calendar feed and the colour its events are drawn in.
class _Source {
  const _Source(this.url, this.colour, this.name);
  final String url;
  final Color colour;
  final String name;
}

/// An event with the colour of whichever calendar it came from.
class _Entry {
  const _Entry(this.event, this.colour);
  final CalendarEvent event;
  final Color colour;
}

/// Upcoming events from one or more published iCalendar feeds, as a schedule
/// or as a month.
class DashboardCalendarWidget extends StatelessWidget {
  const DashboardCalendarWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  static Color _colour(Object? v, Color fallback) {
    if (v is! String || v.isEmpty) return fallback;
    var s = v.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'ff$s';
    final n = int.tryParse(s, radix: 16);
    return n == null ? fallback : Color(n);
  }

  /// The configured feeds.
  ///
  /// Falls back to the single `url` this widget originally took, so a
  /// dashboard built before it accepted several keeps working untouched.
  List<_Source> _sources(Color fallback) {
    final rows = w.rows('sources');
    if (rows.isNotEmpty) {
      return [
        for (final r in rows)
          if ('${r['url'] ?? ''}'.isNotEmpty)
            _Source('${r['url']}', _colour(r['colour'], fallback),
                '${r['name'] ?? ''}'),
      ];
    }
    final legacy = w.option('url', '');
    return legacy.isEmpty ? const [] : [_Source(legacy, fallback, '')];
  }

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final sources = _sources(t.accent);
    if (sources.isEmpty) {
      return _Hint(
        text: 'Add a calendar link in this widget’s settings.',
        colour: t.textSecondary,
      );
    }

    final feeds = context.watch<FeedService>();
    final entries = <_Entry>[];
    String? error;
    for (final s in sources) {
      for (final e in feeds.calendar(s.url)) {
        entries.add(_Entry(e, s.colour));
      }
      error ??= feeds.errorFor(s.url);
    }
    entries.sort((a, b) => a.event.start.compareTo(b.event.start));

    final month = w.option('view', 'schedule') == 'month';
    return month
        ? _MonthView(w: w, entries: entries)
        : _ScheduleView(w: w, entries: entries, error: error);
  }
}

class _ScheduleView extends StatelessWidget {
  const _ScheduleView(
      {required this.w, required this.entries, required this.error});

  final DashboardWidgetContext w;
  final List<_Entry> entries;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final days = w.option('days', 14);
    final horizon = DateTime.now().add(Duration(days: days));
    final from = DateTime.now().subtract(const Duration(hours: 12));
    final shown = entries
        .where((e) =>
            e.event.start.isAfter(from) && e.event.start.isBefore(horizon))
        .take(w.option('maxEvents', 6))
        .toList();

    if (shown.isEmpty) {
      return _Hint(
        text: error ?? 'Nothing in the next $days days.',
        colour: t.textSecondary,
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: shown.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final entry = shown[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 3,
              height: 34,
              decoration: BoxDecoration(
                color: entry.colour,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    _when(entry.event),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _when(CalendarEvent e) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(e.start.year, e.start.month, e.start.day);
    final diff = day.difference(today).inDays;

    final String dayLabel;
    if (diff == 0) {
      dayLabel = 'Today';
    } else if (diff == 1) {
      dayLabel = 'Tomorrow';
    } else if (diff < 7) {
      dayLabel = _days[e.start.weekday - 1];
    } else {
      dayLabel = '${_days[e.start.weekday - 1]} ${e.start.day}/${e.start.month}';
    }

    if (e.allDay) return '$dayLabel · all day';
    final time =
        '${e.start.hour.toString().padLeft(2, '0')}:${e.start.minute.toString().padLeft(2, '0')}';
    final where = e.location == null ? '' : ' · ${e.location}';
    return '$dayLabel $time$where';
  }
}

/// A month at a glance: a dot per event, in its calendar's colour.
///
/// Deliberately dots rather than titles — at the size a month grid gets on a
/// dashboard tile, a title is unreadable anyway, and what the month view is
/// for is seeing which days are busy.
class _MonthView extends StatelessWidget {
  const _MonthView({required this.w, required this.entries});

  final DashboardWidgetContext w;
  final List<_Entry> entries;

  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, 1);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    // Monday-first, which is what a UK wall calendar does.
    final leading = first.weekday - 1;
    final cells = leading + daysInMonth;
    final weeks = (cells / 7).ceil();

    final byDay = <int, List<_Entry>>{};
    for (final e in entries) {
      if (e.event.start.year != now.year || e.event.start.month != now.month) {
        continue;
      }
      byDay.putIfAbsent(e.event.start.day, () => []).add(e);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_months[now.month - 1]} ${now.year}',
          style: TextStyle(
            color: t.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final d in _weekdays)
              Expanded(
                child: Text(
                  d,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.textSecondary, fontSize: 11),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Column(
            children: [
              for (var week = 0; week < weeks; week++)
                Expanded(
                  child: Row(
                    children: [
                      for (var slot = 0; slot < 7; slot++)
                        Expanded(
                          child: _Day(
                            day: week * 7 + slot - leading + 1,
                            daysInMonth: daysInMonth,
                            today: now.day,
                            events: byDay[week * 7 + slot - leading + 1],
                            theme: w.theme,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Day extends StatelessWidget {
  const _Day({
    required this.day,
    required this.daysInMonth,
    required this.today,
    required this.events,
    required this.theme,
  });

  final int day;
  final int daysInMonth;
  final int today;
  final List<_Entry>? events;
  final DashboardTheme theme;

  @override
  Widget build(BuildContext context) {
    if (day < 1 || day > daysInMonth) return const SizedBox.shrink();
    final isToday = day == today;
    final list = events ?? const [];

    return LayoutBuilder(
      builder: (context, c) {
        // Titles need room to be worth showing. Below that, fall back to a
        // dot each — which is all a cell three millimetres tall can honestly
        // carry, and still answers "is that day busy?".
        final titleHeight = 11.0;
        final room = ((c.maxHeight - 16) / titleHeight).floor();
        final showTitles = c.maxHeight > 34 && room >= 1;
        final shown = showTitles ? list.take(room.clamp(1, 3)).toList() : const <_Entry>[];

        return Padding(
          padding: const EdgeInsets.all(1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.center,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: isToday
                      ? BoxDecoration(
                          color: theme.accent,
                          borderRadius: BorderRadius.circular(20),
                        )
                      : null,
                  child: Text(
                    '$day',
                    style: TextStyle(
                      // Against the accent fill, the background colour is the
                      // one guaranteed to contrast with it.
                      color:
                          isToday ? theme.background.first : theme.textPrimary,
                      fontSize: 12,
                      fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
              if (shown.isNotEmpty)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final e in shown)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 1),
                            decoration: BoxDecoration(
                              color: e.colour.withValues(alpha: 0.22),
                              border: Border(
                                  left:
                                      BorderSide(color: e.colour, width: 2)),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              e.event.title,
                              maxLines: 1,
                              // Cropped rather than wrapped: a wrapped title
                              // would push the next day's events out of the
                              // cell entirely.
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontSize: 9,
                                height: 1.1,
                              ),
                            ),
                          ),
                        ),
                      if (list.length > shown.length)
                        Text(
                          '+${list.length - shown.length} more',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: theme.textSecondary, fontSize: 8),
                        ),
                    ],
                  ),
                )
              else if (list.isNotEmpty) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final e in list.take(4))
                      Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                            color: e.colour, shape: BoxShape.circle),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, required this.colour});
  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: colour, fontSize: 15),
        ),
      );
}

final calendarWidgetType = DashboardWidgetType(
  type: 'calendar',
  name: 'Calendar',
  description:
      'Upcoming events from one or more published calendar links, as a '
      'schedule or a month.',
  glyph: '📅',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 3,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'view',
      label: 'View',
      kind: OptionKind.choice,
      defaultValue: 'schedule',
      choices: {
        'schedule': 'Schedule — what’s coming up',
        'month': 'Month — which days are busy',
      },
    ),
    WidgetOption(
      key: 'sources',
      label: 'Calendars',
      kind: OptionKind.list,
      addLabel: 'Add a calendar',
      help: 'Each link is the secret iCal address from Google, Apple or '
          'Outlook — webcal:// works too. Anyone with one can read that '
          'calendar, so treat them as passwords.',
      fields: [
        WidgetOption(key: 'name', label: 'Name', defaultValue: ''),
        WidgetOption(key: 'url', label: 'Link (ICS)', defaultValue: ''),
        WidgetOption(
          key: 'colour',
          label: 'Colour',
          kind: OptionKind.colour,
          defaultValue: '#7DD3FC',
        ),
      ],
    ),
    WidgetOption(
      key: 'days',
      label: 'Look ahead (days)',
      kind: OptionKind.number,
      defaultValue: 14,
      help: 'Schedule view only.',
    ),
    WidgetOption(
      key: 'maxEvents',
      label: 'Most events to show',
      kind: OptionKind.number,
      defaultValue: 6,
      help: 'Schedule view only.',
    ),
  ],
  preview: const [
    PreviewLine('Dentist', scale: 0.14),
    PreviewLine('Today 14:30', scale: 0.1, muted: true),
    PreviewLine('Bin day', scale: 0.14),
    PreviewLine('Tomorrow · all day', scale: 0.1, muted: true),
  ],
  live: (config, data) {
    final feeds = data.feeds;
    if (feeds == null) return const [];
    final urls = <String>[
      for (final r in (config.options['sources'] as List?) ?? const [])
        if (r is Map && '${r['url'] ?? ''}'.isNotEmpty) '${r['url']}',
    ];
    if (urls.isEmpty && '${config.options['url'] ?? ''}'.isNotEmpty) {
      urls.add('${config.options['url']}');
    }
    if (urls.isEmpty) return const [];

    final events = [for (final u in urls) ...feeds.calendar(u)]
      ..sort((a, b) => a.start.compareTo(b.start));
    final from = DateTime.now().subtract(const Duration(hours: 12));
    final upcoming =
        events.where((e) => e.start.isAfter(from)).take(4).toList();
    if (upcoming.isEmpty) return const [];
    return [
      for (final e in upcoming) ...[
        PreviewLine(e.title, scale: 0.14),
        PreviewLine(_ScheduleView._when(e), scale: 0.1, muted: true),
      ],
    ];
  },
  build: (context, w) => DashboardCalendarWidget(w: w),
);
