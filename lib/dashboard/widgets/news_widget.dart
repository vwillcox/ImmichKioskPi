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
    final urls = feedUrls(w);
    if (urls.isEmpty) {
      return Center(
        child: Text(
          'Add a feed address in this widget’s settings.',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textSecondary, fontSize: 15),
        ),
      );
    }

    final feeds = context.watch<FeedService>();
    final maxAge = Duration(minutes: refreshMinutes(w));
    final lists = [for (final u in urls) feeds.feed(u, maxAge: maxAge)];
    final error = urls.map(feeds.errorFor).whereType<String>().firstOrNull;

    final maxItems = w.option('maxItems', 5);
    // One feed needs no blending, and going through the mixer would only
    // reorder it away from the order the publisher chose.
    final items = lists.length == 1
        ? lists.first.take(maxItems).toList()
        : FeedService.mix(lists, max: maxItems);

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
    final shown = items;

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
  /// Every configured feed, falling back to the single `url` this widget
  /// originally took so a dashboard built before it accepted several keeps
  /// working untouched.
  static List<String> feedUrls(DashboardWidgetContext w) {
    final rows = w.rows('sources');
    final urls = [
      for (final r in rows)
        if ('${r['url'] ?? ''}'.trim().isNotEmpty) '${r['url']}'.trim(),
    ];
    if (urls.isNotEmpty) return urls;
    final legacy = w.option('url', '').trim();
    return legacy.isEmpty ? const [] : [legacy];
  }

  static int refreshMinutes(DashboardWidgetContext w) =>
      (int.tryParse('${w.config.options['refreshMinutes'] ?? 15}') ?? 15)
          .clamp(1, 1440);

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
      key: 'sources',
      label: 'Feeds',
      kind: OptionKind.list,
      addLabel: 'Add a feed',
      help: 'RSS or Atom. With more than one, headlines are blended: each is '
          'ranked on how recent it is and on how much that feed has already '
          'contributed, so a busy wire service can’t bury a quieter source.',
      fields: [
        WidgetOption(key: 'name', label: 'Name', defaultValue: ''),
        WidgetOption(
          key: 'url',
          label: 'Address',
          defaultValue: '',
          help: 'For example https://feeds.bbci.co.uk/news/rss.xml',
        ),
      ],
    ),
    WidgetOption(
      key: 'refreshMinutes',
      label: 'Check for new items every (minutes)',
      kind: OptionKind.choice,
      defaultValue: '15',
      choices: {
        '2': 'Every 2 minutes',
        '5': 'Every 5 minutes',
        '15': 'Every 15 minutes',
        '30': 'Every 30 minutes',
        '60': 'Hourly',
        '180': 'Every 3 hours',
        '720': 'Twice a day',
      },
      help: 'Little point checking a weekly blog every two minutes, or a wire '
          'service twice a day.',
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
    if (data.feeds == null) return const [];
    final urls = <String>[
      for (final r in (config.options['sources'] as List?) ?? const [])
        if (r is Map && '${r['url'] ?? ''}'.trim().isNotEmpty)
          '${r['url']}'.trim(),
    ];
    if (urls.isEmpty && '${config.options['url'] ?? ''}'.trim().isNotEmpty) {
      urls.add('${config.options['url']}'.trim());
    }
    if (urls.isEmpty) return const [];

    final shown = (config.options['maxItems'] as num?)?.toInt() ?? 5;
    final lists = [for (final u in urls) data.feeds!.feed(u)];
    // Blended exactly as the panel blends them, so the preview is not a
    // different selection of headlines from the one on the wall.
    final items = lists.length == 1
        ? lists.first.take(shown).toList()
        : FeedService.mix(lists, max: shown);
    if (items.isEmpty) return const [];
    return [
      for (final item in items) ...[
        PreviewLine(item.title, scale: 0.13),
        if (config.options['showTime'] != false && item.published != null)
          PreviewLine(DashboardNewsWidget.ago(item.published!),
              scale: 0.09, muted: true),
      ],
    ];
  },
  build: (context, w) => DashboardNewsWidget(w: w),
);
