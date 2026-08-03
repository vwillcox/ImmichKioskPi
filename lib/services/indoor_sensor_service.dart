import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// One recorded sample from the indoor sensor.
class IndoorReading {
  final DateTime time;
  final double temperatureC;
  final double humidity;

  const IndoorReading({
    required this.time,
    required this.temperatureC,
    required this.humidity,
  });
}

/// Indoor temperature and humidity, read from Home Assistant.
///
/// The sensor is a Govee H510x that broadcasts over Bluetooth LE. The kiosk
/// used to scan for those advertisements itself, but Home Assistant watches the
/// same sensor full-time on a dedicated BLE dongle, so reading its state is both
/// simpler and kinder to the radio: two things scanning the same air gained
/// nothing, and scanning on the Pi's built-in controller makes Bluetooth audio
/// stutter.
///
/// Home Assistant also keeps the history, so the chart comes from there rather
/// than from anything recorded on disk here.
class IndoorSensorService extends ChangeNotifier {
  /// How often to read the current value. Home Assistant updates continuously;
  /// the widget doesn't need to.
  static const Duration _pollInterval = Duration(minutes: 2);

  /// How much history the expanded panel charts.
  static const Duration _historyWindow = Duration(hours: 24);

  /// Refetch history less often than the current value — it's a bigger request
  /// and a 24-hour chart doesn't visibly change minute to minute.
  static const Duration _historyInterval = Duration(minutes: 15);

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 15),
  ));

  HomeAssistantSettings _settings = HomeAssistantSettings();
  Timer? _pollTimer;
  Timer? _historyTimer;

  double? _temperatureC;
  double? _humidity;
  int? _battery;
  DateTime? _lastSeen;

  double? get temperatureC => _temperatureC;
  double? get humidity => _humidity;
  int? get battery => _battery;
  DateTime? get lastSeen => _lastSeen;

  /// Shown in settings so it's obvious where the reading comes from.
  String get deviceName => _settings.temperatureEntity;

  /// True when a reading arrived recently enough to trust.
  bool get available =>
      _temperatureC != null &&
      _lastSeen != null &&
      DateTime.now().difference(_lastSeen!) < _pollInterval * 3;

  List<IndoorReading> _history = [];

  /// Samples for the chart. The window is fixed by [_historyWindow]; the
  /// argument is accepted so callers read naturally.
  List<IndoorReading> recent(Duration window) {
    final cutoff = DateTime.now().subtract(window);
    return _history.where((r) => r.time.isAfter(cutoff)).toList();
  }

  Future<void> start(HomeAssistantSettings settings) async {
    updateSettings(settings);
  }

  /// Called at start-up and whenever the settings change, so entering a token
  /// takes effect without restarting the kiosk.
  void updateSettings(HomeAssistantSettings settings) {
    _settings = settings;
    _pollTimer?.cancel();
    _historyTimer?.cancel();
    if (!settings.isConfigured) {
      _temperatureC = null;
      _humidity = null;
      _battery = null;
      _lastSeen = null;
      _history = [];
      notifyListeners();
      return;
    }
    unawaited(_refresh());
    unawaited(_refreshHistory());
    _pollTimer = Timer.periodic(_pollInterval, (_) => _refresh());
    _historyTimer = Timer.periodic(_historyInterval, (_) => _refreshHistory());
  }

  Options get _auth => Options(
        headers: {'Authorization': 'Bearer ${_settings.token}'},
        responseType: ResponseType.json,
      );

  /// Current value of one entity, or null if it's missing or non-numeric.
  /// Home Assistant reports 'unknown' and 'unavailable' as states too.
  Future<double?> _readEntity(String entityId) async {
    if (entityId.isEmpty) return null;
    try {
      final r = await _dio.get(
        '${_settings.baseUrl}/api/states/$entityId',
        options: _auth,
      );
      final state = (r.data as Map)['state'];
      return state is String ? double.tryParse(state) : null;
    } catch (e) {
      debugPrint('HA read $entityId failed: $e');
      return null;
    }
  }

  Future<void> _refresh() async {
    final temp = await _readEntity(_settings.temperatureEntity);
    if (temp == null) return; // Leave the last good reading in place.
    _temperatureC = temp;
    _humidity = await _readEntity(_settings.humidityEntity) ?? _humidity;
    _battery = (await _readEntity(_settings.batteryEntity))?.round() ?? _battery;
    _lastSeen = DateTime.now();
    notifyListeners();
  }

  /// Pull the last [_historyWindow] of temperature and humidity and pair them
  /// up for the chart.
  Future<void> _refreshHistory() async {
    final temps = await _readHistory(_settings.temperatureEntity);
    if (temps.isEmpty) return;
    final hums = await _readHistory(_settings.humidityEntity);

    _history = [
      for (final t in temps)
        IndoorReading(
          time: t.key,
          temperatureC: t.value,
          humidity: _nearest(hums, t.key) ?? _humidity ?? 0,
        )
    ];
    notifyListeners();
  }

  Future<List<MapEntry<DateTime, double>>> _readHistory(String entityId) async {
    if (entityId.isEmpty) return const [];
    final start = DateTime.now().subtract(_historyWindow).toUtc();
    try {
      final r = await _dio.get(
        '${_settings.baseUrl}/api/history/period/${start.toIso8601String()}',
        queryParameters: {
          'filter_entity_id': entityId,
          // Without these Home Assistant returns every attribute of every
          // state change, which for a sensor updating every few seconds is a
          // lot of JSON to move and parse on a Pi.
          'minimal_response': '',
          'significant_changes_only': '',
        },
        options: _auth,
      );
      final data = r.data;
      if (data is! List || data.isEmpty) return const [];
      final series = data.first;
      if (series is! List) return const [];

      final points = <MapEntry<DateTime, double>>[];
      for (final entry in series) {
        if (entry is! Map) continue;
        final value = double.tryParse('${entry['state']}');
        final when = DateTime.tryParse('${entry['last_changed']}');
        if (value != null && when != null) {
          points.add(MapEntry(when.toLocal(), value));
        }
      }
      return downsample(points);
    } catch (e) {
      debugPrint('HA history $entityId failed: $e');
      return const [];
    }
  }

  /// One point every few minutes is plenty for a 24-hour chart, and keeps the
  /// painter from drawing thousands of segments.
  @visibleForTesting
  static List<MapEntry<DateTime, double>> downsample(
      List<MapEntry<DateTime, double>> points) {
    const bucket = Duration(minutes: 10);
    final out = <MapEntry<DateTime, double>>[];
    for (final p in points) {
      if (out.isEmpty || p.key.difference(out.last.key) >= bucket) {
        out.add(p);
      }
    }
    return out;
  }

  static double? _nearest(
      List<MapEntry<DateTime, double>> points, DateTime when) {
    if (points.isEmpty) return null;
    var best = points.first;
    var bestGap = (best.key.difference(when)).abs();
    for (final p in points.skip(1)) {
      final gap = (p.key.difference(when)).abs();
      if (gap < bestGap) {
        best = p;
        bestGap = gap;
      }
    }
    return best.value;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _historyTimer?.cancel();
    _dio.close();
    super.dispose();
  }
}
