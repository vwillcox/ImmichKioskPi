import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import 'config_service.dart';

/// One day in the 7-day forecast.
class DailyForecast {
  final DateTime date;
  final int weatherCode;
  final double tempMax;
  final double tempMin;
  final int precipitationChance;
  final double windMax;
  final double uvIndexMax;
  final String sunrise;
  final String sunset;

  const DailyForecast({
    required this.date,
    required this.weatherCode,
    required this.tempMax,
    required this.tempMin,
    required this.precipitationChance,
    required this.windMax,
    required this.uvIndexMax,
    required this.sunrise,
    required this.sunset,
  });

  String get description => weatherCodeDescription(weatherCode);

  static const _days = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];

  /// 'Today' for the first entry, otherwise the short weekday name.
  String dayLabel(bool isToday) =>
      isToday ? 'Today' : _days[(date.weekday - 1) % 7];
}

/// Current conditions for the configured location.
class Weather {
  final double temperature;
  final double feelsLike;
  final double tempMax;
  final double tempMin;
  final int weatherCode;
  final bool isDay;
  final String label;
  final String unit; // '°C' or '°F'
  final int humidity;
  final double windSpeed;
  final String windUnit;
  final List<DailyForecast> daily;

  const Weather({
    required this.temperature,
    required this.feelsLike,
    required this.tempMax,
    required this.tempMin,
    required this.weatherCode,
    required this.isDay,
    required this.label,
    required this.unit,
    this.humidity = 0,
    this.windSpeed = 0,
    this.windUnit = 'km/h',
    this.daily = const [],
  });

  String get description => weatherCodeDescription(weatherCode);
}

/// WMO weather interpretation codes used by Open-Meteo.
String weatherCodeDescription(int code) {
  switch (code) {
    case 0:
      return 'Clear';
    case 1:
      return 'Mainly clear';
    case 2:
      return 'Partly cloudy';
    case 3:
      return 'Overcast';
    case 45:
    case 48:
      return 'Fog';
    case 51:
    case 53:
    case 55:
      return 'Drizzle';
    case 56:
    case 57:
      return 'Freezing drizzle';
    case 61:
      return 'Light rain';
    case 63:
      return 'Rain';
    case 65:
      return 'Heavy rain';
    case 66:
    case 67:
      return 'Freezing rain';
    case 71:
      return 'Light snow';
    case 73:
      return 'Snow';
    case 75:
      return 'Heavy snow';
    case 77:
      return 'Snow grains';
    case 80:
    case 81:
      return 'Showers';
    case 82:
      return 'Heavy showers';
    case 85:
    case 86:
      return 'Snow showers';
    case 95:
      return 'Thunderstorm';
    case 96:
    case 99:
      return 'Thunderstorm, hail';
    default:
      return 'Unknown';
  }
}

/// Fetches weather from Open-Meteo (no API key). Resolves the configured
/// location via postcodes.io (UK postcodes) or Open-Meteo geocoding (place
/// names), caching the coordinates in config so we only geocode on change.
class WeatherService extends ChangeNotifier {
  final ConfigService config;
  WeatherService(this.config) {
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => refresh());
  }

  Weather? _weather;
  Weather? get weather => _weather;
  String? _error;
  String? get error => _error;
  bool _loading = false;
  bool get loading => _loading;

  Timer? _timer;
  String? _resolvedFor; // the location string the cached coords belong to

  WeatherSettings get _settings => config.config.weather;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (s) => s != null && s < 500,
      ));

  static final _ukPostcode = RegExp(
    r'^[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}$',
    caseSensitive: false,
  );

  /// Resolve [location] to coordinates. Returns (lat, lon, label) or null.
  Future<(double, double, String)?> _geocode(String location) async {
    final q = location.trim();
    if (q.isEmpty) return null;
    final dio = _dio();

    if (_ukPostcode.hasMatch(q)) {
      try {
        final r = await dio
            .get('https://api.postcodes.io/postcodes/${q.replaceAll(' ', '')}');
        if (r.statusCode == 200) {
          final res = (r.data as Map)['result'] as Map<String, dynamic>;
          final lat = (res['latitude'] as num).toDouble();
          final lon = (res['longitude'] as num).toDouble();
          final label =
              (res['admin_district'] ?? res['parish'] ?? q).toString();
          return (lat, lon, label);
        }
      } catch (e) {
        debugPrint('postcodes.io error: $e');
      }
    }

    try {
      final r = await dio.get(
        'https://geocoding-api.open-meteo.com/v1/search',
        queryParameters: {'name': q, 'count': 1},
      );
      if (r.statusCode == 200) {
        final results = (r.data as Map)['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final res = results.first as Map<String, dynamic>;
          return (
            (res['latitude'] as num).toDouble(),
            (res['longitude'] as num).toDouble(),
            (res['name'] ?? q).toString(),
          );
        }
      }
    } catch (e) {
      debugPrint('open-meteo geocoding error: $e');
    }
    return null;
  }

  Future<void> refresh({bool force = false}) async {
    final s = _settings;
    if (!s.enabled) return;
    if (_loading) return;
    _loading = true;

    try {
      // (Re)geocode when the location changed or we have no cached coords.
      final needsGeocode = force ||
          s.latitude == null ||
          s.longitude == null ||
          _resolvedFor != s.location;
      if (needsGeocode) {
        final geo = await _geocode(s.location);
        if (geo == null) {
          _error = 'Could not find "${s.location}"';
          _weather = null;
          _loading = false;
          notifyListeners();
          return;
        }
        s.latitude = geo.$1;
        s.longitude = geo.$2;
        s.resolvedLabel = geo.$3;
        _resolvedFor = s.location;
        await config.save();
      }

      final unit = s.metric ? 'celsius' : 'fahrenheit';
      final r = await _dio().get(
        'https://api.open-meteo.com/v1/forecast',
        queryParameters: {
          'latitude': s.latitude,
          'longitude': s.longitude,
          'current': 'temperature_2m,apparent_temperature,weather_code,is_day,'
              'relative_humidity_2m,wind_speed_10m',
          'daily': 'weather_code,temperature_2m_max,temperature_2m_min,'
              'precipitation_probability_max,wind_speed_10m_max,'
              'sunrise,sunset,uv_index_max',
          // 14 rather than 7 so the dashboard's longer forecast options have
          // something to show. Open-Meteo serves up to 16; anything reading
          // this list takes only as many as it needs.
          'forecast_days': 14,
          'timezone': 'auto',
          'temperature_unit': unit,
        },
      );
      if (r.statusCode != 200) {
        _error = 'Weather unavailable';
      } else {
        final data = r.data as Map<String, dynamic>;
        final c = data['current'] as Map<String, dynamic>;
        final d = data['daily'] as Map<String, dynamic>;
        final units = data['current_units'] as Map<String, dynamic>? ?? const {};

        final times = (d['time'] as List).cast<String>();
        final daily = <DailyForecast>[];
        for (var i = 0; i < times.length; i++) {
          double num_(String key) =>
              ((d[key] as List?)?[i] as num?)?.toDouble() ?? 0;
          String time_(String key) {
            final v = (d[key] as List?)?[i]?.toString() ?? '';
            // '2026-07-31T05:17' -> '05:17'
            return v.contains('T') ? v.split('T').last : v;
          }

          daily.add(DailyForecast(
            date: DateTime.tryParse(times[i]) ?? DateTime.now(),
            weatherCode: num_('weather_code').toInt(),
            tempMax: num_('temperature_2m_max'),
            tempMin: num_('temperature_2m_min'),
            precipitationChance: num_('precipitation_probability_max').toInt(),
            windMax: num_('wind_speed_10m_max'),
            uvIndexMax: num_('uv_index_max'),
            sunrise: time_('sunrise'),
            sunset: time_('sunset'),
          ));
        }

        _weather = Weather(
          temperature: (c['temperature_2m'] as num).toDouble(),
          feelsLike: (c['apparent_temperature'] as num).toDouble(),
          tempMax: daily.isNotEmpty ? daily.first.tempMax : 0,
          tempMin: daily.isNotEmpty ? daily.first.tempMin : 0,
          weatherCode: (c['weather_code'] as num).toInt(),
          isDay: (c['is_day'] as num).toInt() == 1,
          label: s.resolvedLabel ?? s.location,
          unit: s.metric ? '°C' : '°F',
          humidity: (c['relative_humidity_2m'] as num?)?.toInt() ?? 0,
          windSpeed: (c['wind_speed_10m'] as num?)?.toDouble() ?? 0,
          windUnit: (units['wind_speed_10m'] ?? 'km/h').toString(),
          daily: daily,
        );
        _error = null;
      }
    } catch (e) {
      debugPrint('WeatherService.refresh error: $e');
      _error = 'Weather unavailable';
    }

    _loading = false;
    notifyListeners();
  }

  /// Apply new settings and refresh (re-geocoding if the location changed).
  Future<void> updateSettings(WeatherSettings s) async {
    final locationChanged = s.location != _resolvedFor;
    config.config.weather = s;
    await config.save();
    if (s.enabled) {
      await refresh(force: locationChanged);
    } else {
      notifyListeners();
    }
  }
}
