import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// How a dashboard looks.
///
/// A theme is data, not code, so a new one is a JSON file rather than a
/// change to this app — drop it in `~/.config/immich_kiosk_pi/themes/` and it
/// appears in the picker. The built-ins below are the same shape and double
/// as worked examples; `deploy/theme-template.json` is a commented copy to
/// start from.
class DashboardTheme {
  final String id;
  final String name;

  /// Painted behind everything. Two colours make a vertical gradient; one
  /// makes a flat background.
  final List<Color> background;

  /// The tile behind each widget, and its edge. A fully transparent surface
  /// with a transparent border gives a flat look with no panels at all.
  final Color surface;
  final Color border;

  final Color textPrimary;
  final Color textSecondary;

  /// Used for the things a glance should land on first — the time, now
  /// playing, a temperature.
  final Color accent;

  final double cornerRadius;

  /// Gap between tiles, in logical pixels.
  final double gap;

  /// Optional font for the whole dashboard. Null uses the app's own.
  final String? fontFamily;

  /// Widget tiles cast a soft shadow. Off suits flat and light themes.
  final bool shadow;

  const DashboardTheme({
    required this.id,
    required this.name,
    required this.background,
    required this.surface,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    this.cornerRadius = 20,
    this.gap = 14,
    this.fontFamily,
    this.shadow = true,
  });

  static Color _colour(Object? v, Color fallback) {
    if (v is! String) return fallback;
    var s = v.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'ff$s';
    final n = int.tryParse(s, radix: 16);
    return n == null ? fallback : Color(n);
  }

  factory DashboardTheme.fromJson(Map<String, dynamic> j) {
    final bg = j['background'];
    return DashboardTheme(
      id: j['id'] as String? ?? 'custom',
      name: j['name'] as String? ?? 'Custom',
      background: bg is List
          ? bg.map((c) => _colour(c, const Color(0xFF101014))).toList()
          : [_colour(bg, const Color(0xFF101014))],
      surface: _colour(j['surface'], const Color(0x1AFFFFFF)),
      border: _colour(j['border'], const Color(0x22FFFFFF)),
      textPrimary: _colour(j['textPrimary'], Colors.white),
      textSecondary: _colour(j['textSecondary'], Colors.white70),
      accent: _colour(j['accent'], const Color(0xFF7DD3FC)),
      cornerRadius: (j['cornerRadius'] as num?)?.toDouble() ?? 20,
      gap: (j['gap'] as num?)?.toDouble() ?? 14,
      fontFamily: j['fontFamily'] as String?,
      shadow: j['shadow'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'background': background
            .map((c) =>
                '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}')
            .toList(),
        'surface': _hex(surface),
        'border': _hex(border),
        'textPrimary': _hex(textPrimary),
        'textSecondary': _hex(textSecondary),
        'accent': _hex(accent),
        'cornerRadius': cornerRadius,
        'gap': gap,
        'fontFamily': fontFamily,
        'shadow': shadow,
      };

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

  BoxDecoration get backgroundDecoration => BoxDecoration(
        gradient: background.length > 1
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: background,
              )
            : null,
        color: background.length == 1 ? background.first : null,
      );

  BoxDecoration get tileDecoration => tileDecorationWith();

  /// The tile's look, with the dashboard's own overrides applied over the
  /// theme's preferences.
  BoxDecoration tileDecorationWith({double? radius, bool? withShadow}) =>
      BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(radius ?? cornerRadius),
        border: Border.all(color: border),
        boxShadow: (withShadow ?? shadow)
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      );
}

/// Shipped themes. Each is a plain value, so any of them can be copied into a
/// JSON file and adjusted.
const List<DashboardTheme> kBuiltInThemes = [
  DashboardTheme(
    id: 'midnight',
    name: 'Midnight',
    background: [Color(0xFF0B0F1A), Color(0xFF141C2E)],
    surface: Color(0x14FFFFFF),
    border: Color(0x1FFFFFFF),
    textPrimary: Color(0xFFF2F5FA),
    textSecondary: Color(0x99F2F5FA),
    accent: Color(0xFF7DD3FC),
  ),
  DashboardTheme(
    id: 'paper',
    name: 'Paper',
    background: [Color(0xFFF6F4EF), Color(0xFFEAE6DD)],
    surface: Color(0xFFFFFFFF),
    border: Color(0x14000000),
    textPrimary: Color(0xFF1E1B16),
    textSecondary: Color(0x991E1B16),
    accent: Color(0xFFB4531F),
    cornerRadius: 16,
    shadow: false,
  ),
  DashboardTheme(
    id: 'ember',
    name: 'Ember',
    background: [Color(0xFF1A0F0B), Color(0xFF2E1710)],
    surface: Color(0x1AFFB08A),
    border: Color(0x33FFB08A),
    textPrimary: Color(0xFFFFF1E8),
    textSecondary: Color(0x99FFF1E8),
    accent: Color(0xFFFF8A4C),
    cornerRadius: 24,
  ),
  DashboardTheme(
    id: 'forest',
    name: 'Forest',
    background: [Color(0xFF0C1512), Color(0xFF14241E)],
    surface: Color(0x14A7F3D0),
    border: Color(0x26A7F3D0),
    textPrimary: Color(0xFFEAF6F0),
    textSecondary: Color(0x99EAF6F0),
    accent: Color(0xFF6EE7B7),
  ),
  // Deliberately plain and very high contrast: readable across a room, and
  // the safest choice on an always-on panel because so little of it is lit.
  DashboardTheme(
    id: 'nightstand',
    name: 'Nightstand',
    background: [Color(0xFF000000)],
    surface: Color(0x00000000),
    border: Color(0x00000000),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0x8AFFFFFF),
    accent: Color(0xFFFFB300),
    cornerRadius: 0,
    gap: 24,
    shadow: false,
  ),
];

/// Built-ins plus anything found in the themes directory.
///
/// A file whose id matches a built-in replaces it, so a shipped theme can be
/// adjusted without editing the app.
class ThemeRepository {
  ThemeRepository(this._directory);

  final String _directory;

  List<DashboardTheme> _custom = const [];

  static String defaultDirectory() {
    final home = Platform.environment['HOME'] ?? '.';
    return p.join(home, '.config', 'immich_kiosk_pi', 'themes');
  }

  List<DashboardTheme> get all {
    final byId = {for (final t in kBuiltInThemes) t.id: t};
    for (final t in _custom) {
      byId[t.id] = t;
    }
    return byId.values.toList();
  }

  DashboardTheme byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => all.first);

  /// Reads every `.json` file in the themes directory. A malformed file is
  /// skipped and logged rather than taken as fatal — one bad theme should not
  /// cost you the dashboard.
  Future<void> load() async {
    final dir = Directory(_directory);
    if (!await dir.exists()) {
      _custom = const [];
      return;
    }
    final found = <DashboardTheme>[];
    await for (final entry in dir.list()) {
      if (entry is! File || p.extension(entry.path) != '.json') continue;
      try {
        final data = jsonDecode(await entry.readAsString());
        if (data is Map<String, dynamic>) {
          found.add(DashboardTheme.fromJson(data));
        }
      } catch (e) {
        debugPrint('Dashboard: skipping theme ${entry.path}: $e');
      }
    }
    _custom = found;
  }
}
