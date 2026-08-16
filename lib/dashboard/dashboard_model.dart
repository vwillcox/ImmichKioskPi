/// The dashboard's stored shape: which widgets, where, and how they're set up.
///
/// Deliberately dumb — no Flutter, no services, no knowledge of what any
/// widget type actually does. A widget is a type name, a rectangle on the
/// grid, and a bag of options whose meaning belongs to whoever registered
/// that type. That is what lets a new widget be added without touching
/// anything here, the web editor, or the saved configuration format.
library;

/// The grid the panel is divided into.
///
/// Coordinates are in cells, not pixels, so a layout drawn on one screen
/// still makes sense on another. 12x8 divides the 1920x1200 panel into
/// 160x150 cells — fine enough to place things deliberately, coarse enough
/// that dragging snaps somewhere sensible.
class DashboardGrid {
  static const int columns = 12;
  static const int rows = 8;
}

/// One widget on the dashboard.
class DashboardWidgetConfig {
  /// Stable identity, so the editor can move a widget around without it being
  /// torn down and rebuilt.
  final String id;

  /// Which registered type this is. Unknown types are kept rather than
  /// discarded: a config written by a newer build, or with a widget still
  /// being developed, should survive a round trip through an older one.
  final String type;

  int x;
  int y;
  int width;
  int height;

  /// Which page this widget lives on, counted from zero.
  ///
  /// Every widget carries one rather than pages owning lists of widgets: it
  /// keeps the config a flat list, so a config written before pages existed
  /// loads as a single page without conversion, and moving a widget between
  /// pages is a field change rather than a restructure.
  int page;

  /// Whatever that widget type wants to remember — a feed URL, a format
  /// string, which fields to show. Opaque here.
  Map<String, dynamic> options;

  /// Appearance, handled for every widget by the frame that draws it rather
  /// than by the widgets themselves — so a new widget gets a font and a size
  /// control without asking for them, and can't forget to honour them.
  ///
  /// Empty family means the theme decides.
  String fontFamily;
  double fontScale;

  DashboardWidgetConfig({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.page = 0,
    this.fontFamily = '',
    this.fontScale = 1.0,
    Map<String, dynamic>? options,
  }) : options = options ?? <String, dynamic>{};

  /// Clamped to the grid on the way in, so a hand-edited or stale config
  /// can't put a widget off-screen where it can't be dragged back.
  factory DashboardWidgetConfig.fromJson(Map<String, dynamic> j) {
    final w = (j['width'] as num?)?.toInt() ?? 3;
    final h = (j['height'] as num?)?.toInt() ?? 2;
    final width = w.clamp(1, DashboardGrid.columns);
    final height = h.clamp(1, DashboardGrid.rows);
    return DashboardWidgetConfig(
      id: j['id'] as String? ?? '',
      type: j['type'] as String? ?? '',
      x: ((j['x'] as num?)?.toInt() ?? 0).clamp(0, DashboardGrid.columns - width),
      y: ((j['y'] as num?)?.toInt() ?? 0).clamp(0, DashboardGrid.rows - height),
      width: width,
      height: height,
      // Absent means page one, which is what every pre-pages config is.
      page: ((j['page'] as num?)?.toInt() ?? 0).clamp(0, 99),
      fontFamily: j['fontFamily'] as String? ?? '',
      // Clamped so a hand-edited config can't produce text too small to read
      // or so large the tile shows one letter.
      fontScale: ((j['fontScale'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.5),
      options: (j['options'] as Map?)?.cast<String, dynamic>() ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'page': page,
        'fontFamily': fontFamily,
        'fontScale': fontScale,
        'options': options,
      };

  /// True when this widget's cells overlap [other]'s.
  ///
  /// Widgets on different pages never overlap however their cells line up —
  /// they are never on screen together.
  bool overlaps(DashboardWidgetConfig other) =>
      page == other.page &&
      x < other.x + other.width &&
      other.x < x + width &&
      y < other.y + other.height &&
      other.y < y + height;
}

/// The dashboard as a whole.
class DashboardSettings {
  /// Whether the dashboard is offered at all — it appears in the toolbar
  /// only when this is on.
  bool enabled;

  /// Id of the theme to draw with. An unknown id falls back to the first
  /// built-in rather than failing, so deleting a custom theme leaves a
  /// working dashboard.
  String themeId;

  /// Show the dashboard instead of the album grid when the app starts.
  bool showOnLaunch;

  /// Port the web editor listens on. Separate from the Share Inbox's, so one
  /// can be exposed beyond the LAN without the other.
  int editorPort;

  /// Applied over whatever the theme says, so a look can be settled once and
  /// kept while trying themes out rather than re-chosen every time one is
  /// swapped.
  ///
  /// Rounded corners keep each theme's own radius — they differ on purpose —
  /// and fall back to a sensible one for a theme that is square by design.
  bool roundedCorners;
  bool tileShadows;

  /// Seconds between automatic page turns; 0 leaves it manual.
  int pageSeconds;

  /// Tap anywhere on the dashboard to go to the next page.
  ///
  /// Off by default: a dashboard full of tappable widgets would otherwise
  /// turn the page every time you pressed one of them.
  bool tapToFlip;

  List<DashboardWidgetConfig> widgets;

  DashboardSettings({
    this.enabled = false,
    this.themeId = 'midnight',
    this.showOnLaunch = false,
    this.editorPort = 8090,
    this.roundedCorners = true,
    this.tileShadows = true,
    this.pageSeconds = 0,
    this.tapToFlip = false,
    List<DashboardWidgetConfig>? widgets,
  }) : widgets = widgets ?? [];

  factory DashboardSettings.fromJson(Map<String, dynamic> j) =>
      DashboardSettings(
        enabled: j['enabled'] as bool? ?? false,
        themeId: j['themeId'] as String? ?? 'midnight',
        showOnLaunch: j['showOnLaunch'] as bool? ?? false,
        editorPort: (j['editorPort'] as num?)?.toInt() ?? 8090,
        // Migrated from the three-way settings these replaced.
        roundedCorners: j['roundedCorners'] as bool? ??
            (j['corners'] == null ? true : j['corners'] != 'square'),
        tileShadows: j['tileShadows'] as bool? ??
            (j['shadows'] == null ? true : j['shadows'] != 'off'),
        // Floored at 3s: anything quicker is unreadable, and a config typo
        // of 1 would make the panel strobe.
        pageSeconds: () {
          final v = (j['pageSeconds'] as num?)?.toInt() ?? 0;
          return v <= 0 ? 0 : v.clamp(3, 3600);
        }(),
        tapToFlip: j['tapToFlip'] as bool? ?? false,
        widgets: ((j['widgets'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DashboardWidgetConfig.fromJson)
            .where((w) => w.id.isNotEmpty && w.type.isNotEmpty)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'themeId': themeId,
        'showOnLaunch': showOnLaunch,
        'editorPort': editorPort,
        'roundedCorners': roundedCorners,
        'tileShadows': tileShadows,
        'pageSeconds': pageSeconds,
        'tapToFlip': tapToFlip,
        'widgets': widgets.map((w) => w.toJson()).toList(),
      };

  /// The corner radius to draw with, given what the theme asked for.
  double radiusOver(double themeRadius) =>
      roundedCorners ? (themeRadius > 0 ? themeRadius : 20) : 0;

  /// Whether to draw a shadow. The theme's own preference is a starting
  /// point, not a veto — this is the switch that decides.
  bool shadowOver(bool themeShadow) => tileShadows;

  /// The first free rectangle of [width]x[height] cells, scanning left to
  /// right then top to bottom, or null when the grid is full. Used to place a
  /// newly added widget somewhere sensible instead of on top of another.
  ({int x, int y})? firstFreeSlot(int width, int height, {int page = 0}) {
    for (var y = 0; y <= DashboardGrid.rows - height; y++) {
      for (var x = 0; x <= DashboardGrid.columns - width; x++) {
        final candidate = DashboardWidgetConfig(
            id: '', type: '', x: x, y: y, width: width, height: height,
            page: page);
        if (!widgets.any(candidate.overlaps)) return (x: x, y: y);
      }
    }
    return null;
  }

  /// How many pages there are: enough to hold the highest page in use, and
  /// never fewer than one.
  ///
  /// Derived rather than stored, so a page cannot claim to exist after its
  /// last widget has been deleted or moved off it.
  int get pageCount {
    var highest = 0;
    for (final w in widgets) {
      if (w.page > highest) highest = w.page;
    }
    return highest + 1;
  }

  /// The widgets on [page], in configuration order.
  List<DashboardWidgetConfig> widgetsOn(int page) =>
      widgets.where((w) => w.page == page).toList();
}
