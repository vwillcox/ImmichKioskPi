import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart' show UnifiSettings;
import 'config_service.dart';
import 'retry_schedule.dart';
import 'unifi_models.dart';

/// Reads a UniFi console — a Dream Router, Dream Machine or Cloud Key.
///
/// Uses the **official** Network Integration API under
/// `/proxy/network/integration/v1`, authenticated with an `X-API-KEY` header.
/// The older `/proxy/network/api/...` endpoints are richer — live WAN
/// throughput, per-client counters — but are undocumented, need a stored
/// username and password, and change between releases. A wall panel is not
/// the place for credentials that break on a firmware update.
///
/// Everything is served from the last good response while a refresh is in
/// flight, so a console that goes briefly unreachable leaves the panel showing
/// slightly old numbers rather than blanking.
class UnifiService extends ChangeNotifier {
  UnifiService(this._config);

  final ConfigService _config;

  UnifiSettings get settings => _config.config.unifi;

  Dio? _dio;
  Timer? _timer;
  bool _disposed = false;

  /// Quick retries until the console answers, then a steady poll. The panel
  /// starts before the network, so the first attempt usually fails.
  final RetrySchedule _retry =
      RetrySchedule(settled: const Duration(seconds: 60));

  String? _error;
  String? get error => _error;

  DateTime? _fetchedAt;
  DateTime? get fetchedAt => _fetchedAt;

  Map<String, dynamic>? _sites;
  List<UnifiDevice> _devices = const [];
  List<UnifiClient> _clients = const [];
  final Map<String, UnifiStats> _stats = {};

  List<UnifiDevice> get devices => _devices;
  List<UnifiClient> get clients => _clients;

  /// Statistics for a device, or an empty set if it has not answered yet.
  UnifiStats statsFor(String deviceId) => _stats[deviceId] ?? const UnifiStats();

  /// The gateway — the device reporting an uplink. On a single-console site
  /// that is the router; found rather than assumed to be first in the list.
  UnifiDevice? get gateway {
    for (final d in _devices) {
      final s = _stats[d.id];
      if (s?.txRateBps != null || s?.rxRateBps != null) return d;
    }
    return _devices.isEmpty ? null : _devices.first;
  }

  UnifiStats get gatewayStats {
    final g = gateway;
    return g == null ? const UnifiStats() : statsFor(g.id);
  }

  /// A rolling window of uplink readings, for the throughput graph.
  ///
  /// Kept here rather than in the widget so the history survives paging away
  /// from it — a graph that empties every time you look at another page is
  /// not a graph.
  final List<ThroughputSample> _throughput = [];
  List<ThroughputSample> get throughput => List.unmodifiable(_throughput);

  /// About an hour at the default poll. Long enough to show the shape of an
  /// evening, short enough not to grow without bound.
  static const int _maxSamples = 180;

  bool get hasContent => _devices.isNotEmpty || _clients.isNotEmpty;

  UnifiIspTest? _isp;

  /// The console's own ISP speed test, if it has ever run one.
  UnifiIspTest? get ispTest => _isp;

  /// Devices that are not online, which is the thing worth surfacing.
  List<UnifiDevice> get offlineDevices =>
      _devices.where((d) => !d.online).toList();

  List<UnifiDevice> get updatableDevices =>
      _devices.where((d) => d.firmwareUpdatable).toList();

  String get _base => 'https://${settings.host}/proxy/network/integration/v1';

  Dio _client() {
    final existing = _dio;
    if (existing != null) return existing;
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: {
        'X-API-KEY': settings.apiKey,
        'Accept': 'application/json',
      },
      // 4xx should be readable rather than thrown: a 401 means the key is
      // wrong, which is worth saying plainly instead of "request failed".
      validateStatus: (code) => code != null && code < 500,
    ));
    if (settings.allowSelfSignedCert) {
      // A UniFi console presents a certificate for its .id.ui.direct name, not
      // for the address you reach it on, so a strict check fails against the
      // very device in front of you. Scoped to the configured host so this is
      // not a blanket "trust anything".
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..badCertificateCallback = (cert, host, port) => host == settings.host,
      );
    }
    return _dio = dio;
  }

  /// Drops the cached client so a changed key or host takes effect.
  void refreshFromSettings() {
    _dio?.close(force: true);
    _dio = null;
    _retry.reset();
    _scheduleNext(immediately: true);
  }

  Future<void> start() async => _scheduleNext(immediately: true);

  void _scheduleNext({bool immediately = false}) {
    _timer?.cancel();
    if (!settings.isConfigured) return;
    final delay =
        immediately ? Duration.zero : _retry.next(hasContent: hasContent);
    _timer = Timer(delay, () async {
      await refresh();
      if (!_disposed) _scheduleNext();
    });
  }

  /// One pass: resolve the site if needed, then read devices and clients.
  Future<void> refresh() async {
    if (!settings.isConfigured) return;
    try {
      final site = await _resolveSite();
      if (site == null) return;
      final devices = await _get('/sites/$site/devices');
      // 200 covers a household; the endpoint pages at 25 by default, which
      // would silently show a third of the network.
      final clients = await _get('/sites/$site/clients?limit=200');

      _devices = _listOf(devices)
          .map(UnifiDevice.parse)
          .whereType<UnifiDevice>()
          .toList();
      _clients = _listOf(clients)
          .map(UnifiClient.parse)
          .whereType<UnifiClient>()
          .toList();

      // Statistics are per device and are what carry CPU, memory and the WAN
      // rates, so they are worth the extra calls.
      for (final d in _devices) {
        try {
          _stats[d.id] = UnifiStats.parse(
              await _get('/sites/$site/devices/${d.id}/statistics/latest'));
        } catch (e) {
          debugPrint('UniFi: stats for ${d.name} failed: $e');
        }
      }
      _recordThroughput();
      await _readIspTest();

      _error = null;
      _fetchedAt = DateTime.now();
    } catch (e) {
      // Kept, not cleared: stale numbers beat an empty panel.
      _error = '$e';
      debugPrint('UniFi: $e');
    }
    notifyListeners();
  }

  /// The site id, discovered once and remembered in config.
  ///
  /// UniFi's own default site is named "default" but addressed by an opaque
  /// id, so it has to be looked up rather than assumed.
  Future<String?> _resolveSite() async {
    if (settings.siteId.isNotEmpty) return settings.siteId;
    final body = await _get('/sites');
    final list = _listOf(body);
    if (list.isEmpty) return null;
    final first = list.first;
    final id = first is Map ? '${first['id'] ?? ''}' : '';
    if (id.isEmpty) return null;
    settings.siteId = id;
    unawaited(_config.save());
    _sites = first is Map ? first.cast<String, dynamic>() : null;
    return id;
  }

  Map<String, dynamic>? get site => _sites;

  /// Reads the built-in speed test from the legacy health endpoint.
  ///
  /// The only legacy call in here, and only because the Integration API does
  /// not expose this at all. It is tolerated rather than embraced: a failure
  /// leaves the previous result alone and never disturbs the rest of the
  /// refresh, so a console that drops the endpoint in a future release costs
  /// one widget rather than all six.
  Future<void> _readIspTest() async {
    try {
      final r = await _client().get<Object?>(
          'https://${settings.host}/proxy/network/api/s/default/stat/health');
      if ((r.statusCode ?? 0) >= 400) return;
      final parsed = UnifiIspTest.fromHealth(r.data);
      if (parsed != null) _isp = parsed;
    } catch (e) {
      debugPrint('UniFi: ISP speed test unavailable: $e');
    }
  }

  void _recordThroughput() {
    final s = gatewayStats;
    if (s.txRateBps == null && s.rxRateBps == null) return;
    _throughput.add(ThroughputSample(
        DateTime.now(), s.txRateBps ?? 0, s.rxRateBps ?? 0));
    if (_throughput.length > _maxSamples) {
      _throughput.removeRange(0, _throughput.length - _maxSamples);
    }
  }

  /// The API pages its collections; this returns the `data` array where there
  /// is one, and the body itself where the endpoint answers with a bare list.
  static List<dynamic> _listOf(Object? body) {
    if (body is List) return body;
    if (body is Map && body['data'] is List) return body['data'] as List;
    return const [];
  }

  Future<Object?> _get(String path) async {
    final r = await _client().get<Object?>('$_base$path');
    final code = r.statusCode ?? 0;
    if (code == 401 || code == 403) {
      throw UnifiAuthException(
          'the console refused the API key (HTTP $code) — check it is still '
          'valid, and that its admin has access to this site');
    }
    if (code >= 400) {
      throw StateError('GET $path returned HTTP $code');
    }
    return r.data;
  }

  /// Fetches an arbitrary endpoint, for finding out what a console actually
  /// returns before anything is written against it.
  @visibleForTesting
  Future<Object?> probe(String path) => _get(path);

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _dio?.close(force: true);
    super.dispose();
  }
}

/// The key was refused. Its own type so the UI can say so, rather than
/// reporting a network error for something a person has to fix.
class UnifiAuthException implements Exception {
  UnifiAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
