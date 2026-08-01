import 'dart:async';

import 'package:dio/dio.dart';

import '../models/immich_models.dart';
import 'api_cache.dart';
import 'config_service.dart';
import 'media_cache.dart';
import 'media_source.dart';

/// Thin Immich REST client. Reads connection details live from [ConfigService]
/// so reconnecting in Settings takes effect immediately. Also acts as a
/// [MediaSource] for normal (x-api-key) media fetching.
class ImmichService with ImmichUrls implements MediaSource {
  final ConfigService config;
  ImmichService(this.config);

  String get _base => config.immichUrl;

  @override
  String get baseUrl => config.immichUrl;

  @override
  Map<String, String> get authHeaders => {'x-api-key': config.apiKey};

  Dio _dio() => Dio(BaseOptions(
        baseUrl: _base,
        headers: {'x-api-key': config.apiKey, 'Accept': 'application/json'},
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 30),
      ));

  Future<bool> testConnection() async {
    try {
      final r = await _dio().get('/api/users/me');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Test arbitrary credentials without persisting them (used by setup/edit).
  Future<bool> testConnectionWith(String url, String key) async {
    try {
      final base = url.trim().replaceAll(RegExp(r'/+$'), '');
      final r = await Dio().get(
        '$base/api/users/me',
        options: Options(
          headers: {'x-api-key': key.trim()},
          sendTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ---- Response caching -------------------------------------------------
  // Album lists and album contents are cached in memory for the session and
  // on disk across restarts, so navigating back to a screen is instant.

  static const _memTtl = Duration(minutes: 10);

  List<Map<String, dynamic>>? _albumsMem;
  DateTime? _albumsMemAt;
  final Map<String, List<Map<String, dynamic>>> _assetsMem = {};
  final Map<String, DateTime> _assetsMemAt = {};

  bool _fresh(DateTime? at) =>
      at != null && DateTime.now().difference(at) < _memTtl;

  List<Album> _albumsFromJson(List<Map<String, dynamic>> raw) {
    final albums = raw.map(Album.fromJson).toList();
    // Non-empty albums first, then by most-recently-updated / name.
    albums.sort((a, b) {
      final aEmpty = a.assetCount == 0;
      final bEmpty = b.assetCount == 0;
      if (aEmpty != bEmpty) return aEmpty ? 1 : -1;
      final ad = a.updatedAt, bd = b.updatedAt;
      if (ad != null && bd != null) return bd.compareTo(ad);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return albums;
  }

  /// Album list. Served from memory, then disk, then the network.
  /// [forceRefresh] always hits the network (used by the refresh button).
  Future<List<Album>> getAlbums({bool forceRefresh = false}) async {
    if (!forceRefresh && _albumsMem != null && _fresh(_albumsMemAt)) {
      return _albumsFromJson(_albumsMem!);
    }
    final r = await _dio().get('/api/albums');
    final raw = (r.data as List).cast<Map<String, dynamic>>();
    _albumsMem = raw;
    _albumsMemAt = DateTime.now();
    unawaited(ApiCache.write('albums', raw));
    return _albumsFromJson(raw);
  }

  /// Disk-cached album list for an instant first paint on a cold start.
  /// Returns null when nothing usable is cached.
  Future<List<Album>?> getCachedAlbums({
    Duration maxAge = const Duration(days: 7),
  }) async {
    if (_albumsMem != null) return _albumsFromJson(_albumsMem!);
    final data = await ApiCache.read('albums', maxAge: maxAge);
    if (data is! List) return null;
    try {
      final raw = data.cast<Map<String, dynamic>>();
      _albumsMem = raw;
      return _albumsFromJson(raw);
    } catch (_) {
      return null;
    }
  }

  /// Album assets, via /api/search/metadata (album detail omits assets in v3).
  Future<List<Asset>> getAlbumAssets(
    String albumId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _assetsMem.containsKey(albumId) &&
        _fresh(_assetsMemAt[albumId])) {
      return _assetsMem[albumId]!.map(Asset.fromJson).toList();
    }
    final dio = _dio();
    final raw = <Map<String, dynamic>>[];
    int? page = 1;
    while (page != null) {
      final r = await dio.post('/api/search/metadata', data: {
        'albumIds': [albumId],
        'page': page,
        'size': 250,
        'order': 'desc',
      });
      final a = (r.data as Map<String, dynamic>)['assets'] as Map<String, dynamic>;
      final items = (a['items'] as List).cast<Map<String, dynamic>>();
      raw.addAll(items);
      final next = a['nextPage'];
      page = next == null ? null : int.tryParse(next.toString());
    }
    _assetsMem[albumId] = raw;
    _assetsMemAt[albumId] = DateTime.now();
    unawaited(ApiCache.write('album_$albumId', raw));
    return raw.map(Asset.fromJson).toList();
  }

  /// Disk-cached album contents, for an instant paint before the refresh lands.
  Future<List<Asset>?> getCachedAlbumAssets(
    String albumId, {
    Duration maxAge = const Duration(days: 7),
  }) async {
    if (_assetsMem.containsKey(albumId)) {
      return _assetsMem[albumId]!.map(Asset.fromJson).toList();
    }
    final data = await ApiCache.read('album_$albumId', maxAge: maxAge);
    if (data is! List) return null;
    try {
      final raw = data.cast<Map<String, dynamic>>();
      _assetsMem[albumId] = raw;
      return raw.map(Asset.fromJson).toList();
    } catch (_) {
      return null;
    }
  }

  /// Warm the disk cache with album cover thumbnails in the background, so the
  /// home grid is fully populated even before it's scrolled.
  Future<void> warmAlbumCovers(List<Album> albums) async {
    for (final a in albums) {
      final id = a.thumbnailAssetId;
      if (id == null) continue;
      try {
        await ImmichKioskPiCache.manager.downloadFile(
          thumbUrl(id),
          authHeaders: authHeaders,
        );
      } catch (_) {
        // Best effort; a failed warm just means it loads on demand.
      }
    }
  }
}
