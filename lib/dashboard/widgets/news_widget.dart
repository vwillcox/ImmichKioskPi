import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/feed_service.dart';
import '../widget_registry.dart';

/// Headlines from an RSS or Atom feed.
class DashboardNewsWidget extends StatelessWidget {
  const DashboardNewsWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final url = w.option('url', '');
    if (url.isEmpty) {
      return Center(
        child: Text(
          'Paste a feed address in this widget’s settings.',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textSecondary, fontSize: 15),
        ),
      );
    }

    final feeds = context.watch<FeedService>();
    final items = feeds.feed(url);
    final error = feeds.errorFor(url);

    if (items.isEmpty) {
      return Center(
        child: Text(
          error ?? 'Fetching headlines…',
          style: TextStyle(color: t.textSecondary, fontSize: 15),
        ),
      );
    }

    final showSummary = w.option('showSummary', false);
    final showTime = w.option('showTime', true);
    final shown = items.take(w.option('maxItems', 5)).toList();

    return ListView.separated(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: shown.length,
      separatorBuilder: (_, _) => Divider(
        height: 14,
        thickness: 1,
        color: t.textSecondary.withValues(alpha: 0.15),
      ),
      itemBuilder: (context, i) {
        final item = shown[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.title,
              maxLines: showSummary ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t.textPrimary,
                fontSize: 15,
                height: 1.25,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (showSummary && item.summary != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  item.summary!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: t.textSecondary, fontSize: 13, height: 1.25),
                ),
              ),
            if (showTime && item.published != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _ago(item.published!),
                  style: TextStyle(
                    color: t.textSecondary.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _ago(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

final newsWidgetType = DashboardWidgetType(
  type: 'news',
  name: 'News feed',
  description: 'Headlines from any RSS or Atom feed.',
  glyph: '📰',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 3,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'url',
      label: 'Feed address',
      kind: OptionKind.text,
      defaultValue: '',
      help: 'For example https://feeds.bbci.co.uk/news/rss.xml',
    ),
    WidgetOption(
      key: 'maxItems',
      label: 'Headlines to show',
      kind: OptionKind.number,
      defaultValue: 5,
    ),
    WidgetOption(
      key: 'showSummary',
      label: 'Show a line of summary',
      kind: OptionKind.boolean,
      defaultValue: false,
    ),
    WidgetOption(
      key: 'showTime',
      label: 'Show how long ago',
      kind: OptionKind.boolean,
      defaultValue: true,
    ),
  ],
  build: (context, w) => DashboardNewsWidget(w: w),
);
