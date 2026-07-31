import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/immich_models.dart';
import 'config_service.dart';
import 'media_source.dart';

enum UnlockResult { success, wrongPin, notConfigured, error }

/// Drives Immich's server-side Locked Folder. Unlike normal browsing (which
/// uses an API key), the Locked Folder requires a real login session:
///   login(email,password) -> session token
///   POST /api/auth/session/unlock {pinCode} -> elevates the session (204)
///   POST /api/search/metadata {visibility:'locked'} -> locked assets
///   POST /api/auth/session/lock -> re-lock
class LockedFolderService extends ChangeNotifier {
  final ConfigService config;
  LockedFolderService(this.config);

  String? _token;
  String? _pin; // held in memory only while unlocked, to re-elevate on demand
  bool _elevated = false;

  bool get elevated => _elevated;

  /// Whether the Locked Folder can be attempted (credentials are configured).
  bool get canUse =>
      config.immichEmail.isNotEmpty && config.immichPassword.isNotEmpty;

  MediaSource? get mediaSource =>
      _token == null ? null : BearerMediaSource(config.immichUrl, _token!);

  Dio _dio() => Dio(BaseOptions(
        baseUrl: config.immichUrl,
        headers: {'Accept': 'application/json'},
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 30),
        // Accept 2xx-4xx so we can inspect status codes ourselves.
        validateStatus: (s) => s != null && s < 500,
      ));

  Options _auth() => Options(headers: {'Authorization': 'Bearer $_token'});

  Future<bool> _ensureLoggedIn() async {
    if (_token != null) return true;
    if (!canUse) return false;
    try {
      final r = await _dio().post('/api/auth/login', data: {
        'email': config.immichEmail,
        'password': config.immichPassword,
      });
      if (r.statusCode == 200 || r.statusCode == 201) {
        _token = (r.data as Map)['accessToken'] as String?;
        return _token != null;
      }
    } catch (e) {
      debugPrint('LockedFolder login error: $e');
    }
    return false;
  }

  /// Attempt to unlock the Locked Folder with [pin].
  Future<UnlockResult> unlock(String pin) async {
    if (!canUse) return UnlockResult.notConfigured;
    if (!await _ensureLoggedIn()) return UnlockResult.error;
    try {
      final r = await _dio().post(
        '/api/auth/session/unlock',
        data: {'pinCode': pin},
        options: _auth(),
      );
      if (r.statusCode == 200 || r.statusCode == 204) {
        _pin = pin;
        _elevated = true;
        notifyListeners();
        return UnlockResult.success;
      }
      if (r.statusCode == 400 || r.statusCode == 401 || r.statusCode == 403) {
        return UnlockResult.wrongPin;
      }
      return UnlockResult.error;
    } catch (e) {
      debugPrint('LockedFolder unlock error: $e');
      return UnlockResult.error;
    }
  }

  /// Re-elevate the session so locked media keeps loading. Immich's elevation
  /// expires after a while; call this right before showing locked media (esp.
  /// video, which libmpv streams via range requests) so it doesn't 404.
  Future<void> ensureElevated() async {
    if (_token == null || _pin == null) return;
    try {
      final r = await _dio().post(
        '/api/auth/session/unlock',
        data: {'pinCode': _pin},
        options: _auth(),
      );
      _elevated = r.statusCode == 200 || r.statusCode == 204;
    } catch (e) {
      debugPrint('LockedFolder re-elevate error: $e');
    }
  }

  Future<List<Asset>> getLockedAssets() async {
    if (_token == null) return [];
    final dio = _dio();
    final assets = <Asset>[];
    int? page = 1;
    while (page != null) {
      final r = await dio.post(
        '/api/search/metadata',
        data: {'visibility': 'locked', 'page': page, 'size': 250},
        options: _auth(),
      );
      if (r.statusCode != 200) break;
      final a = (r.data as Map)['assets'] as Map<String, dynamic>;
      final items = (a['items'] as List).cast<Map<String, dynamic>>();
      assets.addAll(items.map(Asset.fromJson));
      final next = a['nextPage'];
      page = next == null ? null : int.tryParse(next.toString());
    }
    return assets;
  }

  /// Re-lock the folder (called when leaving the locked view).
  Future<void> lock() async {
    _pin = null;
    if (_token == null || !_elevated) {
      _elevated = false;
      notifyListeners();
      return;
    }
    try {
      await _dio().post('/api/auth/session/lock', options: _auth());
    } catch (e) {
      debugPrint('LockedFolder lock error: $e');
    }
    _elevated = false;
    notifyListeners();
  }
}
