import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../dashboard/dashboard_model.dart';
import '../dashboard/photo_backdrop.dart';
import '../dashboard/schedule.dart';
import '../dashboard/dashboard_theme.dart';
import '../dashboard/widgets/tv_inputs_sheet.dart';
import '../dashboard/widgets/weather_forecast_sheet.dart';
import '../dashboard/widget_registry.dart';
import '../services/config_service.dart';
import '../services/dashboard_service.dart';
import '../services/screen_idle_service.dart';
import '../services/playback_source.dart';
import '../look.dart';
import '../theme.dart' show fontFallback;
import '../widgets/glass.dart';
import '../widgets/module_bar.dart';
import '../widgets/now_playing_overlay.dart';
import 'home_screen.dart' show showablePlayback;

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

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  ScreenIdleService? _screenIdle;

  late final PageController _pages = PageController(
    initialPage: widget.initialPage,
  );
  late int _page = widget.initialPage;

  /// The automatic page turn, as an animation rather than a timer: it runs
  /// from 0 to 1 over the page's time and turns the page when it gets there.
  /// That same value fills the current page's dot, so a turn is never a
  /// surprise, and pausing is simply stopping it.
  ///
  /// Made in initState, not lazily: a dashboard whose pages never turn would
  /// otherwise first touch it in dispose, and a controller made there looks
  /// up its TickerMode through an element that is already gone.
  late final AnimationController _turn;

  /// Paused from the page dots. Holds until they are tapped again — through
  /// leaving the dashboard and through a restart, since it is saved.
  late bool _paused =
      context.read<ConfigService>().config.dashboard.pagesPaused;
  bool _turning = false;
  int _pageCount = 1;

  /// The pages showing now, by page number — those whose hours are on. The
  /// page view runs over these, so a page out of its hours is simply not
  /// there to swipe to.
  List<int> _visible = const [];

  /// Looks again every half minute at which pages and widgets are due.
  Timer? _clock;

  /// The full now-playing player, opened from a Now playing tile or the
  /// top bar's controls — the home screen's player, growing out of whatever
  /// was tapped.
  final NowPlayingOverlayController _player = NowPlayingOverlayController();

  /// The page is not turned out from under the full player: it would take
  /// the tile the player shrinks back into with it.
  void _playerOpened() {
    if (!_turning) return;
    if (_player.isOpen.value) {
      _turn.stop();
    } else {
      _restartTurn();
    }
  }

  @override
  void initState() {
    super.initState();
    _turn = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          _goTo(_page + 1, _pageCount);
        }
      });
    _player.isOpen.addListener(_playerOpened);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    // A dashboard is a thing you glance at from across the room without
    // touching it, so the idle timer would switch the panel off precisely
    // when it is doing its job. Held awake for as long as it is on screen;
    // switching it off is left to the user, or to Alexa.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _screenIdle = context.read<ScreenIdleService>()..dashboardShowing = true;
      _debugPopup();
    });
  }

  /// Dev aid: HOMECANVAS_TEST_POPUP=forecast|inputs opens that pop-up once
  /// the dashboard is up. Both open only on a tap otherwise, and the panel is
  /// not something to send synthetic taps to.
  void _debugPopup() {
    final which = Platform.environment['HOMECANVAS_TEST_POPUP'];
    if (which == null || which.isEmpty) return;
    final theme = context.read<DashboardService>().themes.byId(
      context.read<ConfigService>().config.dashboard.themeId,
    );
    if (which == 'forecast') unawaited(showWeatherForecast(context, theme));
    if (which == 'inputs') unawaited(showTvInputs(context, theme));
  }

  @override
  void dispose() {
    // Releasing it here rather than on the way in to the next screen means
    // the timer restarts from now, not from whenever the dashboard opened.
    _screenIdle?.dashboardShowing = false;
    _clock?.cancel();
    _player.isOpen.removeListener(_playerOpened);
    _player.dispose();
    _turn.dispose();
    _pages.dispose();
    super.dispose();
  }

  /// Starts, retimes or stops the automatic page turn to match the settings
  /// and how many pages there actually are. Called from build, so the change
  /// itself waits for the frame to finish: starting an animation mid-build
  /// would redraw the dots in the middle of drawing them.
  void _syncTurn(DashboardSettings settings, int pageCount) {
    _pageCount = pageCount;
    final wanted = settings.pageSeconds > 0 && pageCount > 1;
    final length = Duration(seconds: settings.pageSeconds);
    if (wanted == _turning && (!wanted || _turn.duration == length)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final changed = _turn.duration != length;
      if (wanted) _turn.duration = length;
      setState(() => _turning = wanted);
      if (!wanted) {
        _turn
          ..stop()
          ..value = 0;
      } else if (!_paused &&
          !_player.isOpen.value &&
          (changed || !_turn.isAnimating)) {
        _turn.forward(from: changed ? 0 : _turn.value);
      }
    });
  }

  /// Keeps the page view in step as pages come and go with their hours.
  ///
  /// A page whose hours have just begun is gone to straight away — the
  /// morning page arriving at six is the point of giving it hours. Otherwise
  /// the page being looked at stays, wherever it now sits in the list.
  void _followVisible(List<int> visible) {
    final was = _visible;
    if (listEquals(was, visible)) return;
    _visible = visible;
    if (was.isEmpty) return; // first build: the page view starts where it is
    final arrived = visible.where((p) => !was.contains(p)).toList();
    final current = _page < was.length ? was[_page] : 0;
    final target = arrived.isNotEmpty
        ? visible.indexOf(arrived.first)
        : math.max(0, visible.indexOf(current));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pages.hasClients) return;
      _pages.jumpToPage(target);
      setState(() => _page = target);
      _restartTurn();
    });
  }

  /// The page's time starts again — on arriving at a page, and whenever it
  /// is touched, so a page being read or scrolled is not taken away from
  /// under the finger.
  void _restartTurn() {
    if (!_turning) return;
    if (_paused || _player.isOpen.value) {
      _turn.value = 0;
    } else {
      _turn.forward(from: 0);
    }
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    final config = context.read<ConfigService>();
    config.config.dashboard.pagesPaused = _paused;
    unawaited(config.save());
    if (_paused) {
      _turn.stop();
    } else if (_turning && !_player.isOpen.value) {
      _turn.forward();
    }
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
    // Arriving at the page restarts its time (see onPageChanged), so a page
    // you just chose is not whipped away half a second later.
    _goTo(_page + 1, settings.pageCount);
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = context.watch<DashboardService>();
    final settings = context.watch<ConfigService>().config.dashboard;
    // The kiosk's theme, which the dashboard's choice sets — including the
    // HOMECANVAS_TEST_THEME override, applied where it is chosen.
    final theme = context.look;

    final visible = visiblePages(
      settings.pageCount,
      settings.pages,
      DateTime.now(),
    );
    _followVisible(visible);
    final pageCount = visible.length;
    // Kept in step with the config on every build, so editing the interval in
    // the browser takes effect without leaving and re-entering the dashboard.
    _syncTurn(settings, pageCount);
    final dotsTurn = _turning ? _turn : null;
    final onPause = _turning ? _togglePause : null;

    final grid = Stack(
      children: [
        if (settings.widgets.isEmpty)
          _Empty(
            theme: theme,
            address: dashboard.editorAddress,
            fallback: dashboard.editorIpAddress,
          )
        else
          // Behind the widgets, not over them: a translucent layer on
          // top would swallow every tap meant for a widget. This only
          // sees taps that fell on empty grid.
          // Any touch on a page gives it its full time again. A Listener
          // sees the touch without taking it, so the widget underneath
          // still gets its tap or its scroll.
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _restartTurn(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _tapped(settings),
              child: PageView.builder(
                controller: _pages,
                itemCount: pageCount,
                // Swiping works whatever the settings say — it is
                // unambiguous in a way that tapping is not.
                onPageChanged: (i) {
                  setState(() => _page = i);
                  _restartTurn();
                },
                itemBuilder: (context, i) =>
                    _Grid(settings: settings, theme: theme, page: visible[i]),
              ),
            ),
          ),
        // With the top bar off: the panel has no keyboard and no
        // window chrome, so without this there is no way off the
        // dashboard at all.
        if (!settings.topBar) ...[
          Positioned(left: 12, bottom: 12, child: _BackButton(theme: theme)),
          if (pageCount > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: _PageDots(
                  count: pageCount,
                  current: _page,
                  theme: theme,
                  onTap: (i) => _goTo(i, pageCount),
                  turn: dotsTurn,
                  paused: _paused,
                  onTogglePause: onPause,
                ),
              ),
            ),
        ],
      ],
    );

    // The tiles find the player through this: a Now playing tile opens it.
    return NowPlayingOpener(
      controller: _player,
      child: _scaffold(settings, theme, grid, pageCount, dotsTurn, onPause),
    );
  }

  Widget _scaffold(
    DashboardSettings settings,
    DashboardTheme theme,
    Widget grid,
    int pageCount,
    Animation<double>? dotsTurn,
    VoidCallback? onPause,
  ) {
    return Scaffold(
      body: Container(
        decoration: theme.backgroundDecoration,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (theme.glowEndDecoration != null)
              DecoratedBox(decoration: theme.glowEndDecoration!),
            if (settings.photoBackground)
              PhotoBackdrop(
                albumId: settings.photoAlbum,
                dim: settings.photoDim,
                every: Duration(seconds: settings.photoSeconds),
                base: theme.background.first,
              ),
            SafeArea(
              child: !settings.topBar
                  ? grid
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // The same bar as every other screen, in the theme's
                        // colours: back on the left, the greeting and date, and
                        // the pages on the right where the dots used to float
                        // over the widgets.
                        _TopBar(
                          theme: theme,
                          pageCount: pageCount,
                          page: _page,
                          onPage: (i) => _goTo(i, pageCount),
                          turn: dotsTurn,
                          paused: _paused,
                          onTogglePause: onPause,
                          player: _player,
                        ),
                        Expanded(child: grid),
                      ],
                    ),
            ),
            // Over everything, top bar included, as it is on the home
            // screen. Draws nothing until something opens it.
            NowPlayingOverlay(fullScreen: true, controller: _player),
          ],
        ),
      ),
    );
  }
}

/// The kiosk's top bar, drawn for the dashboard.
///
/// [ScreenHeader] in the dashboard theme's colours rather than the app's, so
/// it belongs to whichever theme is chosen — under Glass it is the home
/// screen's bar exactly; under Nightstand it is amber on black.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.theme,
    required this.pageCount,
    required this.page,
    required this.onPage,
    this.turn,
    this.paused = false,
    this.onTogglePause,
    this.player,
  });

  final DashboardTheme theme;
  final int pageCount;
  final int page;
  final void Function(int) onPage;
  final Animation<double>? turn;
  final bool paused;
  final VoidCallback? onTogglePause;
  final NowPlayingOverlayController? player;

  @override
  Widget build(BuildContext context) {
    final playing = showablePlayback(context);
    return DefaultTextStyle.merge(
      style: TextStyle(color: theme.textPrimary),
      child: ScreenHeader(
        titleWidget: GreetingTitle(
          colour: theme.textPrimary,
          secondary: theme.textSecondary,
        ),
        padding: const EdgeInsets.fromLTRB(28, 14, 20, 4),
        // The home screen's own bar, rather than a back button: Photos takes
        // you home, and everything else is where it is there.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (playing != null) ...[
              _MediaControls(source: playing, theme: theme, player: player),
              const SizedBox(width: 12),
            ],
            if (pageCount > 1) ...[
              _PageDots(
                count: pageCount,
                current: page,
                theme: theme,
                onTap: onPage,
                turn: turn,
                paused: paused,
                onTogglePause: onTogglePause,
              ),
              const SizedBox(width: 12),
            ],
            ModuleBar(
              current: KioskModule.dashboard,
              colour: theme.textPrimary,
              accent: theme.accent,
            ),
          ],
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
    // Glass like every other screen's back button, but never fully clear: a
    // control you cannot see is a control you cannot find.
    return GlassIconButton(
      icon: Icons.arrow_back_rounded,
      tooltip: 'Back',
      size: 72,
      colour: theme.textPrimary,
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.settings, required this.theme, this.page = 0});

  final DashboardSettings settings;
  final DashboardTheme theme;
  final int page;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final gap = theme.gap;
        final now = DateTime.now();
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
              if (w.schedule.isAlways || w.schedule.activeAt(now))
                Positioned(
                  left: gap + w.x * (cellWidth + gap),
                  top: gap + w.y * (cellHeight + gap),
                  width: w.width * cellWidth + (w.width - 1) * gap,
                  height: w.height * cellHeight + (w.height - 1) * gap,
                  child: DashboardTile(
                    config: w,
                    theme: theme,
                    settings: settings,
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// One widget in its tile: the theme's frame, the chosen font and size, and
/// the shrink for a small tile.
///
/// Public because the web editor's previews are drawn by this too — see
/// `TileRenderHost` — so a preview is the panel's own drawing, not a copy.
class DashboardTile extends StatelessWidget {
  const DashboardTile({
    super.key,
    required this.config,
    required this.theme,
    required this.settings,
    this.framed = true,
  });

  final DashboardWidgetConfig config;
  final DashboardTheme theme;
  final DashboardSettings settings;

  /// Whether to draw the tile's own background, border and shadow. Off for
  /// the editor, which draws the frame itself — a shadow falls outside the
  /// tile and would be cut off in a picture of it — and lays the picture of
  /// the contents over it.
  final bool framed;

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
    // A widget that fits its own text to the tile gets the user's font size
    // untouched; shrinking it here as well would undo the fitting.
    final textFit = (type?.fitsItself ?? false) ? 1.0 : fit;

    final decoration = theme.tileDecorationWith(
      radius: settings.radiusOver(theme.cornerRadius),
      withShadow: settings.shadowOver(theme.shadow),
    );
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          media.textScaler.scale(1) * config.fontScale * textFit,
        ),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: theme.textPrimary,
          fontFamily: config.fontFamily.isEmpty
              ? theme.fontFamily
              : config.fontFamily,
          // A fresh style, not a merge, so the app's fallback is named again.
          fontFamilyFallback: fontFallback,
        ),
        child: framed
            ? Container(
                decoration: decoration,
                // Padding shrinks with the text. At 1x1 the old fixed 16 took
                // a fifth of the tile before anything was drawn in it.
                padding: EdgeInsets.all(16 * fit),
                clipBehavior: Clip.antiAlias,
                child: child,
              )
            // Where the framed tile's contents would be: a Container adds its
            // border's width to the padding, so the same inset is kept here.
            : Padding(
                padding: EdgeInsets.all(16 * fit).add(decoration.padding),
                child: child,
              ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.theme, required this.address, this.fallback});

  final DashboardTheme theme;
  final String address;

  /// The same address by IP, for a browser that can't resolve .local names.
  final String? fallback;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dashboard_customize_outlined,
            size: 64,
            color: theme.textSecondary,
          ),
          const SizedBox(height: 20),
          Text(
            'No widgets yet',
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w600,
            ),
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
          if (fallback != null) ...[
            const SizedBox(height: 6),
            SelectableText(
              'or $fallback',
              style: TextStyle(color: theme.textSecondary, fontSize: 16),
            ),
          ],
        ],
      ),
    );
  }
}

/// Play and pause from any page, whenever something is playing: the
/// artwork, which opens the full player out of itself, and back, play and
/// next — in a glass pill the size of the module bar's, beside it.
class _MediaControls extends StatefulWidget {
  const _MediaControls({required this.source, required this.theme, this.player});

  final PlaybackSource source;
  final DashboardTheme theme;
  final NowPlayingOverlayController? player;

  @override
  State<_MediaControls> createState() => _MediaControlsState();
}

class _MediaControlsState extends State<_MediaControls> {
  final _art = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final t = widget.theme;
    final playing = source.now.isPlaying;
    final art = source.artUrl;
    return Glass(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: 'Now playing: ${source.now.title}. Open the player.',
            child: GestureDetector(
              onTap: () => widget.player?.expand(from: _art),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 60,
                height: 60,
                child: Center(
                  child: ClipRRect(
                    key: _art,
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: art == null
                          ? ColoredBox(
                              color: t.textSecondary.withValues(alpha: 0.15),
                              child: Icon(
                                Icons.music_note_rounded,
                                size: 24,
                                color: t.textSecondary,
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: art,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => const SizedBox(),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          PillIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous',
            colour: t.textPrimary,
            onPressed: source.previous,
          ),
          PillIconButton(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: playing ? 'Pause' : 'Play',
            colour: t.accent,
            onPressed: source.playPause,
          ),
          PillIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: 'Next',
            colour: t.textPrimary,
            onPressed: source.next,
          ),
        ],
      ),
    );
  }
}

/// Which page you are on, and a way to jump straight to another — and,
/// with the pages turning themselves, how long until the next turn and a
/// way to hold it.
///
/// Sized for a finger rather than as decoration: on a wall panel these are
/// the only visible sign that there is more than one page at all.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.current,
    required this.theme,
    required this.onTap,
    this.turn,
    this.paused = false,
    this.onTogglePause,
  });

  final int count;
  final int current;
  final DashboardTheme theme;
  final void Function(int) onTap;

  /// How far through its time the current page is, when pages turn
  /// themselves. Fills the current dot.
  final Animation<double>? turn;
  final bool paused;
  final VoidCallback? onTogglePause;

  @override
  Widget build(BuildContext context) {
    final dim = theme.textSecondary.withValues(alpha: 0.4);
    // In a glass pill, like every other control on the kiosk's screens, and
    // the same height as the module bar beside it: 60-point targets, as the
    // bar's buttons are, so the two pills line up and read as one toolbar.
    return Glass(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            GestureDetector(
              // The current dot is the clock: tapping it holds or carries on,
              // the same as the button beside it. The others go to their page.
              onTap: () => i == current && onTogglePause != null
                  ? onTogglePause!()
                  : onTap(i),
              behavior: HitTestBehavior.opaque,
              child: Container(
                // The box is the touch target; the dot itself stays smaller
                // so it does not compete with the widgets for attention.
                constraints: const BoxConstraints(minWidth: 52, minHeight: 60),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: i == current ? 44 : 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: i == current
                        ? (turn == null
                              ? theme.accent
                              : theme.accent.withValues(alpha: 0.3))
                        : dim,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: i == current && turn != null
                      ? _Fill(turn: turn!, paused: paused, colour: theme.accent)
                      : null,
                ),
              ),
            ),
          if (onTogglePause != null) ...[
            Container(
              width: 1,
              height: 34,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              color: dim,
            ),
            Semantics(
              button: true,
              label: paused ? 'Carry on turning pages' : 'Hold this page',
              child: GestureDetector(
                onTap: onTogglePause,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 60,
                  height: 60,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, a) => ScaleTransition(
                        scale: a,
                        child: FadeTransition(opacity: a, child: child),
                      ),
                      child: Icon(
                        paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                        key: ValueKey(paused),
                        size: 30,
                        color: paused ? theme.accent : theme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The current dot filling up as its page's time runs out. Paused, the fill
/// stays where it stopped and breathes, so a held page reads as held rather
/// than stuck.
class _Fill extends StatefulWidget {
  const _Fill({required this.turn, required this.paused, required this.colour});

  final Animation<double> turn;
  final bool paused;
  final Color colour;

  @override
  State<_Fill> createState() => _FillState();
}

class _FillState extends State<_Fill> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.paused) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Fill old) {
    super.didUpdateWidget(old);
    if (widget.paused && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!widget.paused && _breath.isAnimating) {
      _breath
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.turn, _breath]),
      builder: (context, _) => Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: widget.turn.value.clamp(0.0, 1.0),
          heightFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.colour.withValues(
                alpha: widget.paused ? 0.55 + 0.35 * _breath.value : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }
}
