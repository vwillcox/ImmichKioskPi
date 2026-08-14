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

  /// Whatever that widget type wants to remember — a feed URL, a format
  /// string, which fields to show. Opaque here.
  Map<String, dynamic> options;

  DashboardWidgetConfig({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
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
        'options': options,
      };

  /// True when this widget's cells overlap [other]'s.
  bool overlaps(DashboardWidgetConfig other) =>
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

  List<DashboardWidgetConfig> widgets;

  DashboardSettings({
    this.enabled = false,
    this.themeId = 'midnight',
    this.showOnLaunch = false,
    this.editorPort = 8090,
    List<DashboardWidgetConfig>? widgets,
  }) : widgets = widgets ?? [];

  factory DashboardSettings.fromJson(Map<String, dynamic> j) =>
      DashboardSettings(
        enabled: j['enabled'] as bool? ?? false,
        themeId: j['themeId'] as String? ?? 'midnight',
        showOnLaunch: j['showOnLaunch'] as bool? ?? false,
        editorPort: (j['editorPort'] as num?)?.toInt() ?? 8090,
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
        'widgets': widgets.map((w) => w.toJson()).toList(),
      };

  /// The first free rectangle of [width]x[height] cells, scanning left to
  /// right then top to bottom, or null when the grid is full. Used to place a
  /// newly added widget somewhere sensible instead of on top of another.
  ({int x, int y})? firstFreeSlot(int width, int height) {
    for (var y = 0; y <= DashboardGrid.rows - height; y++) {
      for (var x = 0; x <= DashboardGrid.columns - width; x++) {
        final candidate = DashboardWidgetConfig(
          id: '', type: '', x: x, y: y, width: width, height: height);
        if (!widgets.any(candidate.overlaps)) return (x: x, y: y);
      }
    }
    return null;
  }
}
