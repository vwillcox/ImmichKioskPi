import 'dart:async';

import 'package:flutter/material.dart';

import '../dashboard_theme.dart';
import '../widget_registry.dart';
import 'omarchy_hotkeys.dart';

/// The Omarchy keyboard shortcuts, as a wall-sized cheat sheet.
///
/// Two hundred and twenty-four shortcuts will not fit on a screen at a size
/// anybody can read from across a room, so this does not try. It shows one
/// section at a time, as large as that section allows, and gives you three
/// ways to move: the tabs, a tap on the sheet itself, or a timer.
///
/// Everything about the layout is worked out from the tile it is given rather
/// than fixed, because the same widget has to survive being a full page and
/// being dropped in a corner.
class DashboardOmarchyWidget extends StatefulWidget {
  const DashboardOmarchyWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  State<DashboardOmarchyWidget> createState() => _DashboardOmarchyWidgetState();
}

class _DashboardOmarchyWidgetState extends State<DashboardOmarchyWidget> {
  int _section = 0;
  int _page = 0;

  /// How many pages the current section needed last time it was laid out.
  ///
  /// Paging is a property of the size the widget was given, which only the
  /// LayoutBuilder knows, so the count comes back from the build rather than
  /// being computed here.
  int _pages = 1;

  Timer? _timer;

  List<HotkeySection> get _sections {
    final chosen = widget.w.option('section', 'all');
    if (chosen == 'all') return omarchyHotkeys;
    final one = omarchyHotkeys.where((s) => s.title == chosen).toList();
    // A section renamed out from under a saved config falls back to all of
    // them rather than to an empty screen.
    return one.isEmpty ? omarchyHotkeys : one;
  }

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void didUpdateWidget(DashboardOmarchyWidget old) {
    super.didUpdateWidget(old);
    if (_section >= _sections.length) _section = 0;
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    final seconds = widget.w.option('autoSeconds', 0);
    if (seconds <= 0) return;
    // Floored, for the same reason the dashboard's own page timer is: a typo
    // of 1 would otherwise make a wall panel strobe.
    final every = Duration(seconds: seconds < 3 ? 3 : seconds);
    _timer = Timer.periodic(every, (_) => _advance());
  }

  void _advance() {
    if (!mounted) return;
    setState(() {
      if (_page + 1 < _pages) {
        _page++;
      } else {
        _page = 0;
        _section = (_section + 1) % _sections.length;
      }
    });
    // A manual turn should not be whipped away half a second later.
    _restartTimer();
  }

  void _goTo(int section) {
    setState(() {
      _section = section;
      _page = 0;
    });
    _restartTimer();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.w.theme;
    final sections = _sections;
    final section = sections[_section.clamp(0, sections.length - 1)];
    final metrics = _Metrics.of(widget.w.option('textSize', 'large'));
    final showTabs = widget.w.option('showTabs', true) && sections.length > 1;

    return LayoutBuilder(
      builder: (context, c) {
        // The header and tabs come off the top before anything is divided up,
        // so the rows that follow are working with the space they will really
        // get rather than the space the tile has.
        final headerHeight = metrics.header;
        final tabsHeight = showTabs ? metrics.tabs : 0.0;
        final bodyHeight = c.maxHeight - headerHeight - tabsHeight;

        final fit = omarchySheetFit(
          width: c.maxWidth,
          height: bodyHeight,
          minColumnWidth: metrics.minColumnWidth,
          rowHeight: metrics.row,
          count: section.keys.length,
        );
        final columns = fit.columns;
        final rows = fit.rows;
        final perPage = columns * rows;
        final pages = fit.pages;

        // Report the page count back for the timer and the tap handler. Done
        // after the frame because it is a build result, not build input.
        if (pages != _pages) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _pages = pages);
          });
        }
        final page = _page.clamp(0, pages - 1);
        final from = page * perPage;
        final slice = section.keys.sublist(
            from, (from + perPage).clamp(0, section.keys.length));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: headerHeight,
              child: _Header(
                theme: t,
                title: section.title,
                pages: pages,
                page: page,
                metrics: metrics,
              ),
            ),
            if (showTabs)
              SizedBox(
                height: tabsHeight,
                child: _Tabs(
                  theme: t,
                  sections: sections,
                  current: _section,
                  metrics: metrics,
                  onPick: _goTo,
                ),
              ),
            Expanded(
              // The whole sheet turns the page. Opaque, because most of a
              // short section is empty space and a target you have to land on
              // a row to hit would be no use on a wall.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _advance,
                child: _Sheet(
                  theme: t,
                  keys: slice,
                  columns: columns,
                  rows: rows,
                  metrics: metrics,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Every size the sheet uses, in one place.
///
/// Three named steps rather than a slider: the useful question is "can I read
/// this from the sofa", and a number does not answer it any better than a
/// name does.
class _Metrics {
  const _Metrics({
    required this.key,
    required this.action,
    required this.title,
    required this.row,
    required this.header,
    required this.tabs,
    required this.minColumnWidth,
  });

  /// Text inside a keycap.
  final double key;

  /// The description beside it.
  final double action;

  /// The section name in the header.
  final double title;

  /// One shortcut's slot, including the gap under it.
  final double row;

  final double header;
  final double tabs;

  /// Narrower than this and a column is not worth having; the sheet uses
  /// fewer, wider ones instead.
  final double minColumnWidth;

  static _Metrics of(String size) {
    switch (size) {
      case 'small':
        return const _Metrics(
          key: 15,
          action: 14,
          title: 22,
          row: 42,
          header: 40,
          tabs: 38,
          minColumnWidth: 380,
        );
      case 'medium':
        return const _Metrics(
          key: 19,
          action: 17,
          title: 28,
          row: 52,
          header: 48,
          tabs: 44,
          minColumnWidth: 460,
        );
      default:
        return const _Metrics(
          key: 24,
          action: 21,
          title: 36,
          row: 66,
          header: 58,
          tabs: 52,
          minColumnWidth: 560,
        );
    }
  }
}

/// Above this many pages, the dots become a counter.
const int _maxDots = 8;

class _Header extends StatelessWidget {
  const _Header({
    required this.theme,
    required this.title,
    required this.pages,
    required this.page,
    required this.metrics,
  });

  final DashboardTheme theme;
  final String title;
  final int pages;
  final int page;
  final _Metrics metrics;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: metrics.title,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // Dots while they can be counted at a glance. Past that they stop
        // meaning anything and start pushing the section name off the tile —
        // a small enough tile turns a long section into a dozen pages.
        if (pages > 1 && pages <= _maxDots)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < pages; i++)
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == page
                        ? theme.accent
                        : theme.textSecondary.withValues(alpha: 0.35),
                  ),
                ),
            ],
          )
        else if (pages > 1)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              '${page + 1} / $pages',
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: metrics.action,
              ),
            ),
          ),
      ],
    );
  }
}

/// The section picker, scrolled sideways.
///
/// Twenty sections do not fit across a screen, so the strip scrolls and
/// carries itself: tapping the sheet moves the selection, and the strip
/// brings the new section into view rather than leaving the highlight
/// somewhere off the side where nobody can see which one they are on.
class _Tabs extends StatefulWidget {
  const _Tabs({
    required this.theme,
    required this.sections,
    required this.current,
    required this.metrics,
    required this.onPick,
  });

  final DashboardTheme theme;
  final List<HotkeySection> sections;
  final int current;
  final _Metrics metrics;
  final void Function(int) onPick;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  final Map<int, GlobalKey> _keys = {};

  @override
  void didUpdateWidget(_Tabs old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _keys[widget.current]?.currentContext;
      // Only built tabs have a context; one far off the side has not been
      // laid out yet, and jumping to it is the scroll position's job anyway.
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  DashboardTheme get theme => widget.theme;
  List<HotkeySection> get sections => widget.sections;
  int get current => widget.current;
  _Metrics get metrics => widget.metrics;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: sections.length,
      itemBuilder: (context, i) {
        final selected = i == current;
        return Padding(
          key: _keys.putIfAbsent(i, GlobalKey.new),
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: GestureDetector(
            onTap: () => widget.onPick(i),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected
                    ? theme.accent.withValues(alpha: 0.22)
                    : theme.textSecondary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(theme.cornerRadius * 0.4),
                border: Border.all(
                  color: selected
                      ? theme.accent
                      : theme.textSecondary.withValues(alpha: 0.25),
                  width: selected ? 2 : 1,
                ),
              ),
              child: Text(
                sections[i].title,
                style: TextStyle(
                  color: selected ? theme.accent : theme.textSecondary,
                  fontSize: metrics.action,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One page of shortcuts, laid out in columns.
class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.theme,
    required this.keys,
    required this.columns,
    required this.rows,
    required this.metrics,
  });

  final DashboardTheme theme;
  final List<Hotkey> keys;
  final int columns;
  final int rows;
  final _Metrics metrics;

  @override
  Widget build(BuildContext context) {
    // Filled column by column, so the eye reads down one and then down the
    // next — the order the source lists them in. Filling across would put
    // consecutive shortcuts on opposite sides of the screen.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < columns; c++) ...[
          if (c > 0) SizedBox(width: metrics.action),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var r = 0; r < rows; r++)
                  if (c * rows + r < keys.length)
                    SizedBox(
                      height: metrics.row,
                      child: _Row(
                        theme: theme,
                        hotkey: keys[c * rows + r],
                        metrics: metrics,
                      ),
                    ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.theme,
    required this.hotkey,
    required this.metrics,
  });

  final DashboardTheme theme;
  final Hotkey hotkey;
  final _Metrics metrics;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 47,
          child: Align(
            alignment: Alignment.centerLeft,
            // The longest combinations — "Super + Ctrl + Shift + Alt +
            // Arrows" — are five caps wide and would push the description off
            // the tile. Shrinking the rare long one keeps every row on the
            // same grid instead of wrapping one of them into two.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: _Caps(
                theme: theme,
                keys: hotkey.keys,
                size: metrics.key,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 53,
          child: Text(
            hotkey.action,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: metrics.action,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}

/// A combination drawn as keycaps. See [omarchyCaps] for the notation.
class _Caps extends StatelessWidget {
  const _Caps({required this.theme, required this.keys, required this.size});

  final DashboardTheme theme;
  final String keys;
  final double size;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final alternatives = omarchyCaps(keys);
    for (var a = 0; a < alternatives.length; a++) {
      if (a > 0) children.add(_joiner('or'));
      for (var i = 0; i < alternatives[a].length; i++) {
        if (i > 0) children.add(_joiner('+'));
        children.add(_cap(alternatives[a][i]));
      }
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _joiner(String text) => Padding(
        padding: EdgeInsets.symmetric(horizontal: size * 0.22),
        child: Text(
          text,
          style: TextStyle(
            color: theme.textSecondary,
            fontSize: size * 0.85,
          ),
        ),
      );

  Widget _cap(String label) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: size * 0.45, vertical: size * 0.26),
        decoration: BoxDecoration(
          color: theme.accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(size * 0.35),
          border: Border.all(color: theme.accent.withValues(alpha: 0.55)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: theme.accent,
            fontSize: size,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      );
}

/// How a page of [count] shortcuts divides up in a box of this size.
///
/// Pulled out of the build because it is the whole behaviour of the widget —
/// how large the text can be is really the question of how many pages there
/// are — and testing it through a rendered tile would tell you much less.
///
/// Columns are capped at four: past that the eye has to travel too far
/// between a key and its description, and the descriptions start truncating.
@visibleForTesting
({int columns, int rows, int pages}) omarchySheetFit({
  required double width,
  required double height,
  required double minColumnWidth,
  required double rowHeight,
  required int count,
}) {
  final columns = (width / minColumnWidth).floor().clamp(1, 4);
  final rows = (height / rowHeight).floor().clamp(1, 40);
  final pages = count <= 0 ? 1 : (count / (columns * rows)).ceil().clamp(1, 99);
  return (columns: columns, rows: rows, pages: pages);
}

/// Split a combination into the caps to draw, grouped by alternative.
///
/// The source's notation is ` + ` between the keys of one combination and
/// ` or ` between alternatives, so `Super + W or Super + Q` is two ways of
/// doing the same thing rather than a four-key chord.
///
/// Everything else is left exactly as written — `1/2/3/4`, `Print Screen`,
/// `CapsLock M S` — and goes on a single cap. Those are the manual's own
/// shorthand, and splitting them further would invent notation the reader has
/// never seen on the page they are trying to memorise.
@visibleForTesting
List<List<String>> omarchyCaps(String keys) => [
      for (final alternative in keys.split(' or '))
        alternative.split(' + '),
    ];

final omarchyWidgetType = DashboardWidgetType(
  type: 'omarchy',
  name: 'Omarchy hotkeys',
  description:
      'The Omarchy keyboard shortcuts as a cheat sheet, one section at a '
      'time. Tap a section to jump to it, or tap the sheet to turn the page. '
      'Sized for a page of its own.',
  glyph: '⌨️',
  defaultWidth: 12,
  defaultHeight: 8,
  minWidth: 1,
  minHeight: 1,
  options: [
    WidgetOption(
      key: 'section',
      label: 'Section',
      kind: OptionKind.choice,
      defaultValue: 'all',
      choices: {
        'all': 'All of them',
        for (final s in omarchyHotkeys) s.title: s.title,
      },
      help: 'Pick one to pin the sheet to it, or show them all and move '
          'between them.',
    ),
    const WidgetOption(
      key: 'textSize',
      label: 'Text size',
      kind: OptionKind.choice,
      defaultValue: 'large',
      choices: {
        'large': 'Large — readable across a room',
        'medium': 'Medium',
        'small': 'Small — more on a page',
      },
      help: 'Larger text means more pages, not smaller rows.',
    ),
    const WidgetOption(
      key: 'autoSeconds',
      label: 'Turn the page by itself, every',
      kind: OptionKind.number,
      defaultValue: 0,
      help: 'Seconds. 0 leaves it still until you touch it. Under three is '
          'treated as three.',
    ),
    const WidgetOption(
      key: 'showTabs',
      label: 'Show the section tabs',
      kind: OptionKind.boolean,
      defaultValue: true,
      help: 'Turn off for a display-only sheet with no controls on it.',
    ),
  ],
  preview: const [
    PreviewLine('Navigating', scale: 0.14),
    PreviewLine('Super + Space   Omarchy menu', scale: 0.10, accent: true),
    PreviewLine('Super + Return   Terminal', scale: 0.10, accent: true),
    PreviewLine('Super + W   Close window', scale: 0.10, accent: true),
  ],
  live: (config, data) {
    final chosen = config.options['section'] as String?;
    final section = omarchyHotkeys.firstWhere(
      (s) => s.title == chosen,
      orElse: () => omarchyHotkeys.first,
    );
    return [
      PreviewLine(section.title, scale: 0.14),
      for (final k in section.keys.take(3))
        PreviewLine('${k.keys}   ${k.action}', scale: 0.10, accent: true),
    ];
  },
  build: (context, w) => DashboardOmarchyWidget(w: w),
);
