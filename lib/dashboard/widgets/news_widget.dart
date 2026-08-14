import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../screens/link_viewer_screen.dart';
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
        final tappable = w.option('openOnTap', true) &&
            (item.link != null || item.summary != null);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tappable ? () => _open(context, item) : null,
          child: Column(
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
                  ago(item.published!),
                  style: TextStyle(
                    color: t.textSecondary.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        );
      },
    );
  }

  /// Show whatever the feed gave us, and offer the page itself.
  ///
  /// Most feeds carry a paragraph of summary, which on a wall panel is often
  /// all anyone wants — so that comes first and costs nothing, with the full
  /// article a deliberate second tap rather than the only option.
  void _open(BuildContext context, FeedItem item) {
    if (item.summary == null || item.summary!.isEmpty) {
      if (item.link != null) _openPage(context, item);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.title, style: const TextStyle(fontSize: 24)),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Text(
              item.summary!,
              style: const TextStyle(fontSize: 18, height: 1.4),
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        actions: [
          if (item.link != null)
            FilledButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openPage(context, item);
              },
              icon: const Icon(Icons.open_in_browser, size: 26),
              label: const Text('Read the page',
                  style: TextStyle(fontSize: 20)),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 26, vertical: 18),
            ),
            child: const Text('Close', style: TextStyle(fontSize: 20)),
          ),
        ],
      ),
    );
  }

  void _openPage(BuildContext context, FeedItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LinkViewerScreen(url: item.link!, title: item.title),
    ));
  }

  /// Also used to build the editor's live preview.
  static String ago(DateTime when) {
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
    WidgetOption(
      key: 'openOnTap',
      label: 'Open a headline when tapped',
      kind: OptionKind.boolean,
      defaultValue: true,
      help: 'Shows the feed’s own summary, with the full page a tap further. '
          'Turn off for a panel nobody should be browsing from.',
    ),
  ],
  preview: const [
    PreviewLine('Council approves new cycle route', scale: 0.13),
    PreviewLine('2h ago', scale: 0.09, muted: true),
    PreviewLine('Storm expected to clear by Thursday', scale: 0.13),
    PreviewLine('4h ago', scale: 0.09, muted: true),
  ],
  live: (config, data) {
    final url = '${config.options['url'] ?? ''}';
    if (url.isEmpty || data.feeds == null) return const [];
    final items = data.feeds!.feed(url);
    if (items.isEmpty) return const [];
    final max = (config.options['maxItems'] as num?)?.toInt() ?? 5;
    return [
      for (final item in items.take(max)) ...[
        PreviewLine(item.title, scale: 0.13),
        if (config.options['showTime'] != false && item.published != null)
          PreviewLine(DashboardNewsWidget.ago(item.published!),
              scale: 0.09, muted: true),
      ],
    ];
  },
  build: (context, w) => DashboardNewsWidget(w: w),
);
