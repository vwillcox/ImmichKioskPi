import 'package:flutter/material.dart';

import 'dashboard_model.dart';
import 'live_preview.dart';
import 'dashboard_theme.dart';

/// The kind of control the web editor should offer for an option.
///
/// [list] is a repeating group: the option holds a list of records, each with
/// the fields named in [WidgetOption.fields], and the editor gives it a plus
/// to add a row and a cross to remove one. Generic rather than specific to
/// the calendar's several feeds, so the next widget that needs a repeating
/// setting gets one for free.
enum OptionKind { text, number, boolean, choice, multiline, colour, list }

/// One setting a widget type accepts.
///
/// The editor builds its form from these, so a new widget's settings appear
/// in the browser without a line of editor code. Keep [key] stable: it is
/// what ends up in the saved configuration.
class WidgetOption {
  final String key;
  final String label;
  final OptionKind kind;
  final Object? defaultValue;

  /// For [OptionKind.choice]: the allowed values, and what to call them.
  final Map<String, String> choices;

  /// For [OptionKind.choice]: the name of a list the *kiosk* supplies, rather
  /// than one written here — currently only `albums`.
  ///
  /// Needed because some choices are not knowable when the widget is
  /// declared: which albums exist is a property of somebody's Immich server,
  /// changes without this app being rebuilt, and cannot be a const map.
  /// The editor fills these from the schema at render time.
  final String? choicesFrom;

  /// Shown under the field. Say what the setting is for, not what it is.
  final String? help;

  /// For [OptionKind.list]: the fields of one row.
  final List<WidgetOption> fields;

  /// For [OptionKind.list]: what to call a row on the button that adds one.
  final String addLabel;

  const WidgetOption({
    required this.key,
    this.choicesFrom,
    required this.label,
    this.kind = OptionKind.text,
    this.defaultValue,
    this.choices = const {},
    this.help,
    this.fields = const [],
    this.addLabel = 'Add',
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'kind': kind.name,
        'default': defaultValue,
        'choices': choices,
        'choicesFrom': choicesFrom,
        'help': help,
        'fields': fields.map((f) => f.toJson()).toList(),
        'addLabel': addLabel,
      };
}

/// Everything a widget's builder is handed.
class DashboardWidgetContext {
  final DashboardWidgetConfig config;
  final DashboardTheme theme;

  const DashboardWidgetContext({required this.config, required this.theme});

  /// Read an option, falling back to the type's declared default and then to
  /// [fallback]. Widgets should always go through this rather than reading
  /// `config.options` directly, so a config saved before an option existed
  /// still behaves.
  T option<T>(String key, T fallback) {
    final v = config.options[key];
    if (v is T) return v;
    // JSON numbers arrive as int or double depending on how they were written.
    if (T == double && v is num) return v.toDouble() as T;
    if (T == int && v is num) return v.toInt() as T;
    return fallback;
  }

  /// Rows of an [OptionKind.list] option.
  List<Map<String, dynamic>> rows(String key) =>
      (config.options[key] as List?)
          ?.whereType<Map>()
          .map((r) => r.cast<String, dynamic>())
          .toList() ??
      const [];
}

/// A line of stand-in content for the browser editor's preview.
///
/// Declared by the widget type rather than drawn by the editor, so a new
/// widget previews itself without the editor learning anything about it.
/// [scale] is relative to the tile's height, which is what keeps a preview
/// honest as the tile is resized.
///
/// `{time}` and `{date}` are substituted with the real ones, so a clock
/// preview shows the actual time rather than a fixed 09:41.
class PreviewLine {
  final String text;
  final double scale;
  final bool muted;
  final bool accent;

  /// Centred rather than ranged left, matching how the widget itself lays the
  /// line out.
  final bool centre;

  const PreviewLine(
    this.text, {
    this.scale = 0.14,
    this.muted = false,
    this.accent = false,
    this.centre = false,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'scale': scale,
        'muted': muted,
        'accent': accent,
        'centre': centre,
      };
}

/// A widget type the dashboard can show.
class DashboardWidgetType {
  /// Stable identifier stored in the config. Never rename one in place.
  final String type;

  final String name;
  final String description;

  /// Shown in the web editor's palette. An emoji keeps the editor free of
  /// icon fonts and dependencies.
  final String glyph;

  final int defaultWidth;
  final int defaultHeight;
  final int minWidth;
  final int minHeight;

  final List<WidgetOption> options;

  /// Stand-in content for the editor's preview, used when [live] is absent
  /// or has nothing yet.
  final List<PreviewLine> preview;

  /// The real thing, for the editor's preview: what this widget would be
  /// showing right now. Returning an empty list falls back to [preview].
  final List<PreviewLine> Function(
      DashboardWidgetConfig config, PreviewData data)? live;

  final Widget Function(BuildContext context, DashboardWidgetContext w) build;

  const DashboardWidgetType({
    required this.type,
    required this.name,
    required this.description,
    required this.glyph,
    required this.build,
    this.defaultWidth = 3,
    this.defaultHeight = 2,
    this.minWidth = 1,
    this.minHeight = 1,
    this.options = const [],
    this.preview = const [],
    this.live,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'name': name,
        'description': description,
        'glyph': glyph,
        'defaultWidth': defaultWidth,
        'defaultHeight': defaultHeight,
        'minWidth': minWidth,
        'minHeight': minHeight,
        'options': options.map((o) => o.toJson()).toList(),
        'preview': preview.map((p) => p.toJson()).toList(),
      };
}

/// Every widget type the build knows about.
///
/// To add one: write the widget, then register it here. Nothing else needs
/// touching — the editor's palette, its settings form, and the saved
/// configuration all follow from the descriptor. See
/// `lib/dashboard/widgets/README.md`.
class WidgetRegistry {
  WidgetRegistry._();

  static final Map<String, DashboardWidgetType> _types = {};

  static void register(DashboardWidgetType type) {
    _types[type.type] = type;
  }

  static void registerAll(Iterable<DashboardWidgetType> types) {
    for (final t in types) {
      register(t);
    }
  }

  static DashboardWidgetType? find(String type) => _types[type];

  static List<DashboardWidgetType> get all => _types.values.toList();

  /// Options filled in with their declared defaults, for a newly added widget.
  static Map<String, dynamic> defaultsFor(String type) {
    final t = _types[type];
    if (t == null) return {};
    return {
      for (final o in t.options)
        if (o.defaultValue != null) o.key: o.defaultValue,
    };
  }
}
