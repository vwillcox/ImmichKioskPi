import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/weather_service.dart';
import '../../widgets/weather_overlay.dart' show weatherIcon;
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
            .clamp(0, 7);
    final showFeels = w.option('showFeelsLike', true);
    final showHighLow = w.option('showHighLow', true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // Centred rather than ranged left: on a tile of its own the reading
          // is the whole point, and off to one side it reads as a caption for
          // empty space.
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        weatherIcon(weather.weatherCode, weather.isDay),
                        color: t.accent,
                        size: 46,
                      ),
                      const SizedBox(width: 14),
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
                  const SizedBox(height: 4),
                  Text(
                    showFeels
                        ? '${weather.description} · feels ${weather.feelsLike.round()}${weather.unit}'
                        : weather.description,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.textSecondary, fontSize: 15),
                  ),
                  if (showHighLow)
                    Text(
                      '${weather.tempMax.round()}° / ${weather.tempMin.round()}°',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.textSecondary, fontSize: 14),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (days > 0 && weather.daily.isNotEmpty) ...[
          const SizedBox(height: 10),
          Expanded(
            child: Row(
              children: [
                for (final day in weather.daily.take(days))
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _dayLabel(day.date),
                          style:
                              TextStyle(color: t.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Icon(weatherIcon(day.weatherCode, true),
                            color: t.textSecondary, size: 20),
                        const SizedBox(height: 2),
                        Text(
                          '${day.tempMax.round()}°',
                          style: TextStyle(color: t.textPrimary, fontSize: 15),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _dayLabel(DateTime d) {
    final today = DateTime.now();
    if (d.year == today.year && d.month == today.month && d.day == today.day) {
      return 'Today';
    }
    return _days[d.weekday - 1];
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
  minWidth: 2,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'forecastDays',
      label: 'Forecast',
      kind: OptionKind.choice,
      defaultValue: '3',
      choices: {
        '0': 'Current conditions only',
        '3': '3 day',
        '5': '5 day',
        '7': '7 day',
      },
      help: 'A wider tile suits the longer forecasts.',
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
  build: (context, w) => DashboardWeatherWidget(w: w),
);
