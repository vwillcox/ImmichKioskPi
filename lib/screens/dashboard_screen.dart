import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../dashboard/dashboard_model.dart';
import '../dashboard/dashboard_theme.dart';
import '../dashboard/widget_registry.dart';
import '../services/config_service.dart';
import '../services/dashboard_service.dart';
import '../services/screen_idle_service.dart';

/// The dashboard: widgets laid out on a grid, drawn in the chosen theme.
///
/// Placement comes entirely from the saved configuration, which is edited in
/// a browser rather than here — this screen only draws it. Editing on a
/// wall-mounted touchscreen with no keyboard is miserable, and a phone is
/// already in your hand.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.initialPage = 0});

  /// Which page to open on. Only used by the debug launch hook — the panel
  /// itself always opens on the first page.
  final int initialPage;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  ScreenIdleService? _screenIdle;

  late final PageController _pages =
      PageController(initialPage: widget.initialPage);
  Timer? _flip;
  late int _page = widget.initialPage;

  @override
  void initState() {
    super.initState();
    // A dashboard is a thing you glance at from across the room without
    // touching it, so the idle timer would switch the panel off precisely
    // when it is doing its job. Held awake for as long as it is on screen;
    // switching it off is left to the user, or to Alexa.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _screenIdle = context.read<ScreenIdleService>()..dashboardShowing = true;
    });
  }

  @override
  void dispose() {
    // Releasing it here rather than on the way in to the next screen means
    // the timer restarts from now, not from whenever the dashboard opened.
    _screenIdle?.dashboardShowing = false;
    _flip?.cancel();
    _pages.dispose();
    super.dispose();
  }

  /// Starts, restarts or stops the automatic page turn to match the settings
  /// and how many pages there actually are.
  void _syncFlipTimer(DashboardSettings settings) {
    final wanted = settings.pageSeconds > 0 && settings.pageCount > 1;
    if (!wanted) {
      _flip?.cancel();
      _flip = null;
      return;
    }
    if (_flip != null && _flip!.isActive) return;
    _flip = Timer.periodic(Duration(seconds: settings.pageSeconds), (_) {
      if (!mounted) return;
      _goTo(_page + 1, settings.pageCount);
    });
  }

  void _goTo(int index, int pageCount) {
    if (pageCount <= 1) return;
    final next = index % pageCount;
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
    );
  }

  /// A tap anywhere that a widget did not claim.
  ///
  /// Only reached when the widget under the finger ignored it, so tapping the
  /// TV remote or the speed test still does what those do rather than turning
  /// the page underneath them.
  void _tapped(DashboardSettings settings) {
    if (!settings.tapToFlip) return;
    _goTo(_page + 1, settings.pageCount);
    // Manual turns restart the clock, so a page you just chose is not
    // whipped away half a second later.
    if (settings.pageSeconds > 0) {
      _flip?.cancel();
      _flip = null;
      _syncFlipTimer(settings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = context.watch<DashboardService>();
    final settings = context.watch<ConfigService>().config.dashboard;
    final theme = dashboard.themes.byId(settings.themeId);

    final pageCount = settings.pageCount;
    // Kept in step with the config on every build, so editing the interval in
    // the browser takes effect without leaving and re-entering the dashboard.
    _syncFlipTimer(settings);

    return Scaffold(
      body: Container(
        decoration: theme.backgroundDecoration,
        child: SafeArea(
          child: Stack(
            children: [
              if (settings.widgets.isEmpty)
                _Empty(theme: theme, address: dashboard.editorAddress)
              else
                // Behind the widgets, not over them: a translucent layer on
                // top would swallow every tap meant for a widget. This only
                // sees taps that fell on empty grid.
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _tapped(settings),
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: pageCount,
                    // Swiping works whatever the settings say — it is
                    // unambiguous in a way that tapping is not.
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (context, page) => _Grid(
                      settings: settings,
                      theme: theme,
                      page: page,
                    ),
                  ),
                ),
              // The panel has no keyboard and no window chrome, so without
              // this there is no way off the dashboard at all. Drawn in the
              // theme's own colours so it belongs to the dashboard rather
              // than sitting on top of it.
              Positioned(
                left: 12,
                bottom: 12,
                child: _BackButton(theme: theme),
              ),
              if (pageCount > 1)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: _PageDots(
                    count: pageCount,
                    current: _page,
                    theme: theme,
                    onTap: (i) => _goTo(i, pageCount),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Back to whatever the kiosk was showing before the dashboard.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.theme});

  final DashboardTheme theme;

  @override
  Widget build(BuildContext context) {
    return Material(
      // Never fully transparent, even under a theme whose tiles are: a
      // control you cannot see is a control you cannot find.
      color: Color.alphaBlend(
          theme.surface, theme.background.first.withValues(alpha: 1)),
      shape: CircleBorder(
          side: BorderSide(color: theme.textSecondary.withValues(alpha: 0.4))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).maybePop(),
        child: SizedBox(
          width: 76,
          height: 76,
          child: Icon(Icons.arrow_back, color: theme.textPrimary, size: 38),
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.settings,
    required this.theme,
    this.page = 0,
  });

  final DashboardSettings settings;
  final DashboardTheme theme;
  final int page;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final gap = theme.gap;
        // Cells are whatever is left once the gaps are taken out, so the
        // outermost widgets sit the same distance from the edge as they do
        // from each other.
        final cellWidth =
            (c.maxWidth - gap * (DashboardGrid.columns + 1)) /
                DashboardGrid.columns;
        final cellHeight =
            (c.maxHeight - gap * (DashboardGrid.rows + 1)) / DashboardGrid.rows;

        return Stack(
          children: [
            for (final w in settings.widgetsOn(page))
              Positioned(
                left: gap + w.x * (cellWidth + gap),
                top: gap + w.y * (cellHeight + gap),
                width: w.width * cellWidth + (w.width - 1) * gap,
                height: w.height * cellHeight + (w.height - 1) * gap,
                child: _Tile(config: w, theme: theme, settings: settings),
              ),
          ],
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.config,
    required this.theme,
    required this.settings,
  });

  final DashboardWidgetConfig config;
  final DashboardTheme theme;
  final DashboardSettings settings;

  @override
  Widget build(BuildContext context) {
    final type = WidgetRegistry.find(config.type);

    final child = type == null
        // A type this build doesn't know — a config from a newer version, or
        // a widget mid-development. Say so rather than drawing nothing, and
        // leave the configuration alone so it comes back when the widget does.
        ? Center(
            child: Text(
              'Unknown widget "${config.type}"',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textSecondary, fontSize: 14),
            ),
          )
        : Builder(
            builder: (context) => type.build(
              context,
              DashboardWidgetContext(config: config, theme: theme),
            ),
          );

    // Font and size are applied here, for every widget, rather than in each
    // one. The family rides on the default text style, which Text merges into
    // its own; the scale goes through the text scaler, which is the only
    // thing that also reaches the explicit font sizes widgets set on
    // themselves.
    // How much the tile has been shrunk below the size this widget's fixed
    // font sizes and paddings were written for. Every widget can now be
    // placed at 1x1, where a 17-point heading and 16 pixels of padding on
    // each side simply do not fit.
    final fit = type?.contentScale(config.width, config.height) ?? 1.0;

    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          media.textScaler.scale(1) * config.fontScale * fit,
        ),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: theme.textPrimary,
          fontFamily:
              config.fontFamily.isEmpty ? theme.fontFamily : config.fontFamily,
        ),
        child: Container(
          decoration: theme.tileDecorationWith(
            radius: settings.radiusOver(theme.cornerRadius),
            withShadow: settings.shadowOver(theme.shadow),
          ),
          // Padding shrinks with the text. At 1x1 the old fixed 16 took a
          // fifth of the tile before anything was drawn in it.
          padding: EdgeInsets.all(16 * fit),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.theme, required this.address});

  final DashboardTheme theme;
  final String address;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dashboard_customize_outlined,
              size: 64, color: theme.textSecondary),
          const SizedBox(height: 20),
          Text(
            'No widgets yet',
            style: TextStyle(
                color: theme.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            'Open this in a browser to arrange the dashboard:',
            style: TextStyle(color: theme.textSecondary, fontSize: 16),
          ),
          const SizedBox(height: 10),
          SelectableText(
            address,
            style: TextStyle(
              color: theme.accent,
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Which page you are on, and a way to jump straight to another.
///
/// Sized for a finger rather than as decoration: on a wall panel these are
/// the only visible sign that there is more than one page at all.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.current,
    required this.theme,
    required this.onTap,
  });

  final int count;
  final int current;
  final DashboardTheme theme;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          GestureDetector(
            onTap: () => onTap(i),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              // The padding is the touch target; the dot itself stays small
              // so it does not compete with the widgets for attention.
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: i == current ? 30 : 12,
                height: 12,
                decoration: BoxDecoration(
                  color: i == current
                      ? theme.accent
                      : theme.textSecondary.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
