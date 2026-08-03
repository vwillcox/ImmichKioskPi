import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// Loads/saves [AppConfig] to ~/.config/immich_kiosk_pi/config.json and notifies
/// listeners on change. A single instance is shared app-wide.
class ConfigService extends ChangeNotifier {
  AppConfig _config = AppConfig();
  AppConfig get config => _config;

  // Convenience passthroughs.
  String get immichUrl => _config.immichUrl;
  String get apiKey => _config.apiKey;
  String get immichEmail => _config.immichEmail;
  String get immichPassword => _config.immichPassword;
  bool get isConfigured => _config.isConfigured;
  SlideshowSettings get slideshow => _config.slideshow;

  static String get _home => Platform.environment['HOME'] ?? '.';

  File get _file => File('$_home/.config/immich_kiosk_pi/config.json');

  /// Location used before the project was renamed from TabletPi.
  File get _legacyFile => File('$_home/.config/tabletpi/config.json');

  /// Carry an existing TabletPi config over on first run after the rename, so
  /// upgrades don't lose the server URL, API key or saved login.
  Future<void> _migrateLegacyConfig() async {
    try {
      final f = _file;
      if (await f.exists()) return;
      final legacy = _legacyFile;
      if (!await legacy.exists()) return;
      await f.parent.create(recursive: true);
      await legacy.copy(f.path);
      debugPrint('Migrated config from ${legacy.path} to ${f.path}');
    } catch (e) {
      debugPrint('ConfigService migration error: $e');
    }
  }

  Future<void> load() async {
    await _migrateLegacyConfig();
    try {
      final f = _file;
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _config = AppConfig.fromJson(data);
      }
    } catch (e) {
      debugPrint('ConfigService.load error: $e');
    }
    notifyListeners();
  }

  Future<void> save() async {
    try {
      final f = _file;
      await f.parent.create(recursive: true);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(_config.toJson()));
    } catch (e) {
      debugPrint('ConfigService.save error: $e');
    }
    notifyListeners();
  }

  Future<void> setConnection(String url, String key) async {
    _config.immichUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    _config.apiKey = key.trim();
    await save();
  }

  Future<void> setCredentials(String email, String password) async {
    _config.immichEmail = email.trim();
    _config.immichPassword = password;
    await save();
  }

  /// Remember the video player's level between videos (and restarts).
  Future<void> setVideoAudio(double volume, bool muted) async {
    _config.videoVolume = volume;
    _config.videoMuted = muted;
    await save();
  }

  Future<void> updateSlideshow(SlideshowSettings s) async {
    _config.slideshow = s;
    await save();
  }
}
