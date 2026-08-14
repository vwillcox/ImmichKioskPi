import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../dashboard/dashboard_model.dart';
import '../dashboard/dashboard_theme.dart';
import '../dashboard/widget_registry.dart';
import '../services/config_service.dart';
import '../services/dashboard_service.dart';

/// The dashboard: widgets laid out on a grid, drawn in the chosen theme.
///
/// Placement comes entirely from the saved configuration, which is edited in
/// a browser rather than here — this screen only draws it. Editing on a
/// wall-mounted touchscreen with no keyboard is miserable, and a phone is
/// already in your hand.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dashboard = context.watch<DashboardService>();
    final settings = context.watch<ConfigService>().config.dashboard;
    final theme = dashboard.themes.byId(settings.themeId);

    return Scaffold(
      body: Container(
        decoration: theme.backgroundDecoration,
        child: SafeArea(
          child: settings.widgets.isEmpty
              ? _Empty(theme: theme, address: dashboard.editorAddress)
              : _Grid(settings: settings, theme: theme),
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.settings, required this.theme});

  final DashboardSettings settings;
  final DashboardTheme theme;

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
            for (final w in settings.widgets)
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
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          media.textScaler.scale(1) * config.fontScale,
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
          padding: const EdgeInsets.all(16),
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
