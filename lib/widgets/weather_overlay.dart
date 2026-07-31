import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../services/config_service.dart';
import '../services/weather_service.dart';

/// Maps a WMO weather code to a colour, so conditions read at a glance:
/// sun = amber, cloud = slate, rain = blue, snow = pale cyan, storm = violet.
Color weatherColor(int code, bool isDay) {
  switch (code) {
    case 0:
    case 1:
      return isDay ? const Color(0xFFFFC542) : const Color(0xFFBFC7FF);
    case 2:
      return isDay ? const Color(0xFFFFD98A) : const Color(0xFF9FA8DA);
    case 3:
      return const Color(0xFFB0BEC5);
    case 45:
    case 48:
      return const Color(0xFF90A4AE);
    case 51:
    case 53:
    case 55:
    case 56:
    case 57:
      return const Color(0xFF80D8FF);
    case 61:
    case 63:
    case 65:
    case 66:
    case 67:
    case 80:
    case 81:
    case 82:
      return const Color(0xFF4FA3FF);
    case 71:
    case 73:
    case 75:
    case 77:
    case 85:
    case 86:
      return const Color(0xFFE3F2FD);
    case 95:
    case 96:
    case 99:
      return const Color(0xFFB388FF);
    default:
      return Colors.white;
  }
}

/// Maps a WMO weather code to an icon.
IconData weatherIcon(int code, bool isDay) {
  switch (code) {
    case 0:
    case 1:
      return isDay ? Icons.wb_sunny : Icons.nightlight_round;
    case 2:
      return isDay ? Icons.wb_cloudy : Icons.nights_stay;
    case 3:
      return Icons.cloud;
    case 45:
    case 48:
      return Icons.foggy;
    case 51:
    case 53:
    case 55:
    case 56:
    case 57:
      return Icons.grain;
    case 61:
    case 63:
    case 65:
    case 66:
    case 67:
    case 80:
    case 81:
    case 82:
      return Icons.water_drop;
    case 71:
    case 73:
    case 75:
    case 77:
    case 85:
    case 86:
      return Icons.ac_unit;
    case 95:
    case 96:
    case 99:
      return Icons.thunderstorm;
    default:
      return Icons.thermostat;
  }
}

/// Floating weather panel in a configurable corner. Tapping it expands to a
/// full-screen 7-day forecast; tapping again shrinks it back. Place inside a
/// Stack that fills the screen.
class WeatherOverlay extends StatefulWidget {
  /// Inset from the screen edges when collapsed.
  final EdgeInsets margin;
  final bool compact;

  const WeatherOverlay({
    super.key,
    this.margin = const EdgeInsets.all(16),
    this.compact = false,
  });

  @override
  State<WeatherOverlay> createState() => _WeatherOverlayState();
}

class _WeatherOverlayState extends State<WeatherOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 340),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  bool get _expanded => _controller.value > 0.5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_expanded) {
      _controller.reverse();
    } else {
      _controller.forward();
    }
  }

  // Sized to fit the enlarged type without clipping.
  Size _collapsedSize() =>
      widget.compact ? const Size(290, 124) : const Size(410, 178);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ConfigService>().config.weather;
    final service = context.watch<WeatherService>();
    if (!settings.enabled) return const SizedBox.shrink();
    final w = service.weather;
    if (w == null) return const SizedBox.shrink();

    // Fill the parent Stack so the collapse/expand geometry is measured
    // against the whole screen. Empty areas don't absorb touches, so the
    // slideshow underneath still receives taps when collapsed.
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screen = Size(constraints.maxWidth, constraints.maxHeight);
          final collapsed = _collapsedRect(screen, settings.corner);
          final expanded = _expandedRect(screen);

          return AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              final v = _t.value;
              final rect = Rect.lerp(collapsed, expanded, v)!;
              return Stack(
                children: [
                  // Scrim behind the expanded card so the photo doesn't compete.
                  if (v > 0.01)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: v < 0.5,
                        child: GestureDetector(
                          onTap: _toggle,
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.55 * v),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fromRect(
                    rect: rect,
                    child: GestureDetector(
                      onTap: _toggle,
                      child: _Panel(
                        weather: w,
                        compact: widget.compact,
                        expansion: v,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Rect _collapsedRect(Size screen, OverlayCorner corner) {
    final size = _collapsedSize();
    final m = widget.margin;
    final isTop =
        corner == OverlayCorner.topLeft || corner == OverlayCorner.topRight;
    final isLeft =
        corner == OverlayCorner.topLeft || corner == OverlayCorner.bottomLeft;
    final left = isLeft ? m.left : screen.width - size.width - m.right;
    final top = isTop ? m.top : screen.height - size.height - m.bottom;
    return Rect.fromLTWH(left, top, size.width, size.height);
  }

  Rect _expandedRect(Size screen) {
    // Full-screen with a comfortable inset, capped so it stays card-like.
    const inset = 28.0;
    final width = (screen.width - inset * 2).clamp(0.0, 1700.0);
    final height = (screen.height - inset * 2).clamp(0.0, 1000.0);
    return Rect.fromLTWH(
      (screen.width - width) / 2,
      (screen.height - height) / 2,
      width,
      height,
    );
  }
}

class _Panel extends StatelessWidget {
  final Weather weather;
  final bool compact;
  final double expansion; // 0 = collapsed, 1 = expanded

  const _Panel({
    required this.weather,
    required this.compact,
    required this.expansion,
  });

  @override
  Widget build(BuildContext context) {
    // Cross-fade the two layouts: collapsed fades out over the first half,
    // detail fades in over the second half.
    final collapsedOpacity = (1 - expansion * 2).clamp(0.0, 1.0);
    final detailOpacity = ((expansion - 0.5) * 2).clamp(0.0, 1.0);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62 + 0.24 * expansion),
        borderRadius: BorderRadius.circular(26 + 6 * expansion),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 18 + 20 * expansion,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26 + 6 * expansion),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (collapsedOpacity > 0)
              Opacity(
                opacity: collapsedOpacity,
                child: _CollapsedContent(weather: weather, compact: compact),
              ),
            if (detailOpacity > 0)
              Opacity(
                opacity: detailOpacity,
                child: _DetailContent(weather: weather),
              ),
          ],
        ),
      ),
    );
  }
}

class _CollapsedContent extends StatelessWidget {
  final Weather weather;
  final bool compact;
  const _CollapsedContent({required this.weather, required this.compact});

  @override
  Widget build(BuildContext context) {
    final icon = weatherIcon(weather.weatherCode, weather.isDay);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 21 : 27,
        vertical: compact ? 15 : 21,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: compact ? 52 : 72,
              color: weatherColor(weather.weatherCode, weather.isDay)),
          SizedBox(width: compact ? 15 : 21),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${weather.temperature.round()}${weather.unit}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 40 : 54,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
                Text(
                  weather.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: compact ? 20 : 25,
                  ),
                ),
                if (!compact)
                  Text(
                    '${weather.label}  •  '
                    '${weather.tempMax.round()}° / ${weather.tempMin.round()}°',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 21),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen detail: current conditions + 7-day forecast.
class _DetailContent extends StatelessWidget {
  final Weather weather;
  const _DetailContent({required this.weather});

  @override
  Widget build(BuildContext context) {
    final today = weather.daily.isNotEmpty ? weather.daily.first : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 28, 36, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: location + close affordance
          Row(
            children: [
              Expanded(
                child: Text(
                  weather.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(
                Icons.close_fullscreen,
                color: Colors.white54,
                size: 30,
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Current conditions
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                weatherIcon(weather.weatherCode, weather.isDay),
                size: 104,
                color: weatherColor(weather.weatherCode, weather.isDay),
              ),
              const SizedBox(width: 26),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${weather.temperature.round()}${weather.unit}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 86,
                      fontWeight: FontWeight.w300,
                      height: 1.0,
                    ),
                  ),
                  Text(
                    weather.description,
                    style: const TextStyle(color: Colors.white70, fontSize: 29),
                  ),
                ],
              ),
              const Spacer(),
              Wrap(
                spacing: 34,
                runSpacing: 14,
                children: [
                  _Stat(
                    icon: Icons.thermostat,
                    color: const Color(0xFFFF8A65),
                    label: 'Feels like',
                    value: '${weather.feelsLike.round()}${weather.unit}',
                  ),
                  _Stat(
                    icon: Icons.water_drop_outlined,
                    color: const Color(0xFF4FC3F7),
                    label: 'Humidity',
                    value: '${weather.humidity}%',
                  ),
                  _Stat(
                    icon: Icons.air,
                    color: const Color(0xFF9FE7C7),
                    label: 'Wind',
                    value: '${weather.windSpeed.round()} ${weather.windUnit}',
                  ),
                  if (today != null)
                    _Stat(
                      icon: Icons.umbrella_outlined,
                      color: const Color(0xFF7FB6FF),
                      label: 'Rain',
                      value: '${today.precipitationChance}%',
                    ),
                  if (today != null)
                    _Stat(
                      icon: Icons.wb_twilight,
                      color: const Color(0xFFFFC542),
                      label: 'Sun',
                      value: '${today.sunrise} – ${today.sunset}',
                    ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 22),
          const Divider(color: Colors.white24, height: 1),
          const SizedBox(height: 18),

          const Text(
            '7-DAY FORECAST',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 12),

          Expanded(
            child: Row(
              children: [
                for (var i = 0; i < weather.daily.length; i++)
                  Expanded(
                    child: _DayColumn(
                      day: weather.daily[i],
                      isToday: i == 0,
                      unit: weather.unit,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.color = Colors.white54,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 23, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 18),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 27,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  final DailyForecast day;
  final bool isToday;
  final String unit;
  const _DayColumn({
    required this.day,
    required this.isToday,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 5),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: isToday
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Text(
            day.dayLabel(isToday),
            style: TextStyle(
              color: Colors.white,
              fontSize: 23,
              fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          Icon(
            weatherIcon(day.weatherCode, true),
            size: 54,
            color: weatherColor(day.weatherCode, true),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              day.description,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
          ),
          Text(
            '${day.tempMax.round()}°',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 29,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '${day.tempMin.round()}°',
            style: const TextStyle(color: Colors.white60, fontSize: 22),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.umbrella_outlined,
                size: 15,
                color: Color(0xFF7FB6FF),
              ),
              const SizedBox(width: 4),
              Text(
                '${day.precipitationChance}%',
                style: const TextStyle(color: Color(0xFF7FB6FF), fontSize: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
