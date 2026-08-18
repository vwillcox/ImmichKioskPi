import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/weather_service.dart';
import '../../widgets/weather_overlay.dart' show weatherIcon;
import '../dashboard_theme.dart';
import '../widget_registry.dart';

/// Current conditions, and optionally the next few days.
///
/// Reads the same [WeatherService] the corner overlay uses, so the location
/// and units stay in one place — Settings → Weather — rather than being
/// configured twice.
class DashboardWeatherWidget extends StatelessWidget {
  const DashboardWeatherWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final service = context.watch<WeatherService>();
    final weather = service.weather;

    if (weather == null) {
      return Center(
        child: Text(
          service.error ?? 'Waiting for the forecast…',
          style: TextStyle(color: t.textSecondary, fontSize: 16),
        ),
      );
    }

    // Stored as a choice, so it arrives as a string from the editor and as a
    // number from a config written before it became one.
    final days =
        (int.tryParse('${w.config.options['forecastDays'] ?? 3}') ?? 3)
            .clamp(0, 14);
    final showFeels = w.option('showFeelsLike', true);
    final showHighLow = w.option('showHighLow', true);
    final showCurrent = w.option('showCurrent', true);

    // Everything is laid out at a natural size and then scaled to fill by
    // FittedBox, rather than drawn at fixed point sizes. That is what lets
    // the same widget fill a large tile instead of sitting small in the
    // middle of one, and shrink to fit a small tile instead of overflowing —
    // the numbers below are proportions to each other, not sizes on screen.
    final current = FittedBox(
      fit: BoxFit.contain,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                weatherIcon(weather.weatherCode, weather.isDay),
                color: t.accent,
                size: 64,
              ),
              const SizedBox(width: 16),
              Text(
                '${weather.temperature.round()}${weather.unit}',
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 52,
                  height: 1.0,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            showFeels
                ? '${weather.description} · feels ${weather.feelsLike.round()}${weather.unit}'
                : weather.description,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textSecondary, fontSize: 17),
          ),
          if (showHighLow)
            Text(
              '${weather.tempMax.round()}° / ${weather.tempMin.round()}°',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textSecondary, fontSize: 16),
            ),
        ],
      ),
    );

    // With the current reading switched off, today is dropped from the
    // forecast too. Otherwise the panel still leads with "Today", which is
    // the very thing that was turned off — and on a tile paired with a
    // separate current-conditions widget, says it twice.
    final daily = showCurrent
        ? weather.daily
        : weather.daily.where((d) => !_isToday(d.date)).toList();

    final hasForecast = days > 0 && daily.isNotEmpty;

    return LayoutBuilder(
      builder: (context, c) {
        if (!hasForecast) return Center(child: current);

        // Forecast only: one widget's code, two quite different panels — a
        // reading on one tile and a week's outlook on another.
        if (!showCurrent) {
          return _Forecast(
            days: daily.take(days).toList(),
            theme: t,
            // A long forecast on a wide tile reads better as columns; on a
            // narrow one, as rows down the tile.
            vertical: c.maxWidth / c.maxHeight < 0.9,
          );
        }

        // On a wide, short tile the forecast belongs beside the reading —
        // stacked, there is no height left for either. On anything squarer it
        // belongs underneath, which is how a forecast is usually read.
        final beside = c.maxWidth / c.maxHeight > 2.2;
        final forecast = _Forecast(
          days: daily.take(days).toList(),
          theme: t,
          vertical: beside,
        );

        if (beside) {
          return Row(
            children: [
              Expanded(flex: 5, child: Center(child: current)),
              const SizedBox(width: 12),
              Expanded(flex: 6, child: forecast),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 3, child: Center(child: current)),
            const SizedBox(height: 10),
            Expanded(flex: 2, child: forecast),
          ],
        );
      },
    );
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];


  static bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  static String dayLabel(DateTime d) =>
      _isToday(d) ? 'Today' : _days[d.weekday - 1];
}

/// The next few days, as a row of columns or a column of rows.
///
/// Each day is scaled into its own share of the space, so three days on a
/// wide tile read comfortably large and seven on a narrow one still fit,
/// without either being given a fixed point size that suits only one shape.
class _Forecast extends StatelessWidget {
  const _Forecast({
    required this.days,
    required this.theme,
    required this.vertical,
  });

  final List<DailyForecast> days;
  final DashboardTheme theme;

  /// Laid out as rows down the side rather than columns along the bottom,
  /// which is what a tall, narrow share of a wide tile wants.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final cells = [
      for (final day in days)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: FittedBox(
              fit: BoxFit.contain,
              child: vertical
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 58,
                          child: Text(
                            DashboardWeatherWidget.dayLabel(day.date),
                            style: TextStyle(
                                color: theme.textSecondary, fontSize: 17),
                          ),
                        ),
                        Icon(weatherIcon(day.weatherCode, true),
                            color: theme.textSecondary, size: 26),
                        const SizedBox(width: 10),
                        Text(
                          '${day.tempMax.round()}°',
                          style:
                              TextStyle(color: theme.textPrimary, fontSize: 20),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          DashboardWeatherWidget.dayLabel(day.date),
                          style: TextStyle(
                              color: theme.textSecondary, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Icon(weatherIcon(day.weatherCode, true),
                            color: theme.textSecondary, size: 32),
                        const SizedBox(height: 4),
                        Text(
                          '${day.tempMax.round()}°',
                          style:
                              TextStyle(color: theme.textPrimary, fontSize: 18),
                        ),
                      ],
                    ),
            ),
          ),
        ),
    ];
    return vertical ? Column(children: cells) : Row(children: cells);
  }
}

final weatherWidgetType = DashboardWidgetType(
  type: 'weather',
  name: 'Weather',
  description:
      'Current conditions and a short forecast. Uses the location set in '
      'Settings → Weather.',
  glyph: '⛅',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 1,
  minHeight: 1,
  options: const [
    WidgetOption(
      key: 'forecastDays',
      label: 'Forecast',
      kind: OptionKind.choice,
      defaultValue: '3',
      choices: {
        '0': 'None',
        '3': '3 day',
        '5': '5 day',
        '7': '7 day',
        '10': '10 day',
        '14': '14 day',
      },
      help: 'A wider tile suits the longer forecasts.',
    ),
    WidgetOption(
      key: 'showCurrent',
      label: 'Show current conditions',
      kind: OptionKind.boolean,
      defaultValue: true,
      help: 'Turn off for a forecast-only tile, so one widget can be a '
          'reading in one place and a week’s outlook in another. Today is '
          'left out of the forecast when this is off.',
    ),
    WidgetOption(
      key: 'showFeelsLike',
      label: 'Show what it feels like',
      kind: OptionKind.boolean,
      defaultValue: true,
    ),
    WidgetOption(
      key: 'showHighLow',
      label: 'Show today’s high and low',
      kind: OptionKind.boolean,
      defaultValue: true,
    ),
  ],
  preview: const [
    PreviewLine('☁ 14°C', scale: 0.3, accent: true),
    PreviewLine('Light cloud · feels 12°C', scale: 0.1, muted: true),
    PreviewLine('Today 16°  Tue 15°  Wed 13°', scale: 0.1, muted: true),
  ],
  live: (config, data) {
    final weather = data.weather?.weather;
    if (weather == null) return const [];
    final days =
        (int.tryParse('${config.options['forecastDays'] ?? 3}') ?? 3).clamp(0, 7);
    final feels = config.options['showFeelsLike'] != false
        ? ' · feels ${weather.feelsLike.round()}${weather.unit}'
        : '';
    final showCurrent = config.options['showCurrent'] != false;
    if (!showCurrent) {
      return [
        for (final d in weather.daily.take(days == 0 ? 3 : days))
          PreviewLine(
              '${DashboardWeatherWidget.dayLabel(d.date)}   ${d.tempMax.round()}°',
              scale: 0.11,
              centre: true),
      ];
    }
    return [
      PreviewLine('${weather.temperature.round()}${weather.unit}',
          scale: 0.3, accent: true, centre: true),
      PreviewLine('${weather.description}$feels',
          scale: 0.1, muted: true, centre: true),
      if (config.options['showHighLow'] != false)
        PreviewLine(
            '${weather.tempMax.round()}° / ${weather.tempMin.round()}°',
            scale: 0.09, muted: true, centre: true),
      if (days > 0 && weather.daily.isNotEmpty)
        PreviewLine(
          weather.daily
              .take(days)
              .map((d) => '${d.tempMax.round()}°')
              .join('   '),
          scale: 0.1,
          muted: true,
          centre: true,
        ),
    ];
  },
  build: (context, w) => DashboardWeatherWidget(w: w),
);
