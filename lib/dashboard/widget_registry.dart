import 'package:flutter/material.dart';

import 'dashboard_model.dart';
import 'dashboard_theme.dart';

/// The kind of control the web editor should offer for an option.
enum OptionKind { text, number, boolean, choice, multiline }

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

  /// Shown under the field. Say what the setting is for, not what it is.
  final String? help;

  const WidgetOption({
    required this.key,
    required this.label,
    this.kind = OptionKind.text,
    this.defaultValue,
    this.choices = const {},
    this.help,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'kind': kind.name,
        'default': defaultValue,
        'choices': choices,
        'help': help,
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
