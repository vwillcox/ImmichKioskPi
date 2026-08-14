import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/feed_service.dart';
import '../widget_registry.dart';

/// Upcoming events from a published iCalendar feed.
class DashboardCalendarWidget extends StatelessWidget {
  const DashboardCalendarWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final url = w.option('url', '');
    if (url.isEmpty) {
      return _Hint(
        text: 'Paste a calendar link in this widget’s settings.',
        colour: t.textSecondary,
      );
    }

    final feeds = context.watch<FeedService>();
    final all = feeds.calendar(url);
    final error = feeds.errorFor(url);

    final horizon = DateTime.now().add(Duration(days: w.option('days', 14)));
    final from = DateTime.now().subtract(const Duration(hours: 12));
    final events = all
        .where((e) => e.start.isAfter(from) && e.start.isBefore(horizon))
        .take(w.option('maxEvents', 6))
        .toList();

    if (events.isEmpty) {
      return _Hint(
        text: error ?? 'Nothing in the next ${w.option('days', 14)} days.',
        colour: t.textSecondary,
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: events.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final e = events[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 3,
              height: 34,
              decoration: BoxDecoration(
                color: t.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    _when(e),
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

  static const _days = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

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
  description: 'Upcoming events from a published calendar link.',
  glyph: '📅',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 3,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'url',
      label: 'Calendar link (ICS)',
      kind: OptionKind.text,
      defaultValue: '',
      help: 'The secret iCal address from Google, Apple or Outlook. '
          'webcal:// links work too. Anyone with this link can read the '
          'calendar, so treat it as a password.',
    ),
    WidgetOption(
      key: 'days',
      label: 'Look ahead (days)',
      kind: OptionKind.number,
      defaultValue: 14,
    ),
    WidgetOption(
      key: 'maxEvents',
      label: 'Most events to show',
      kind: OptionKind.number,
      defaultValue: 6,
    ),
  ],
  build: (context, w) => DashboardCalendarWidget(w: w),
);
