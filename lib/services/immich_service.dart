import 'package:dio/dio.dart';

import '../models/immich_models.dart';
import 'config_service.dart';
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

  Future<List<Album>> getAlbums() async {
    final r = await _dio().get('/api/albums');
    final list = (r.data as List).cast<Map<String, dynamic>>();
    final albums = list.map(Album.fromJson).toList();
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

  /// Album assets, via /api/search/metadata (album detail omits assets in v3).
  Future<List<Asset>> getAlbumAssets(String albumId) async {
    final dio = _dio();
    final assets = <Asset>[];
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
      assets.addAll(items.map(Asset.fromJson));
      final next = a['nextPage'];
      page = next == null ? null : int.tryParse(next.toString());
    }
    return assets;
  }
}
