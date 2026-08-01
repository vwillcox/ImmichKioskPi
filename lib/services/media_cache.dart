import 'dart:io' as io;

import 'package:file/file.dart' show File;
import 'package:file/local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

/// Aggressive, disk-backed media caching tuned for the Pi.
///
/// IMPORTANT: the default `flutter_cache_manager` location is
/// `getTemporaryDirectory()`, which on this Pi is `/tmp` — a 4 GB **tmpfs**,
/// i.e. RAM. Caching heavily there would eat memory and vanish on reboot.
/// Everything here is pinned to `~/.cache/immich_kiosk_pi` on the NVMe instead, which
/// has hundreds of GB free and survives restarts.
class ImmichKioskPiCache {
  ImmichKioskPiCache._();

  static const String cacheKey = 'immich_kiosk_pi_media';

  /// Root of all on-disk caches: ~/.cache/immich_kiosk_pi
  static String get root {
    final home = io.Platform.environment['HOME'] ?? '.';
    return p.join(home, '.cache', 'immich_kiosk_pi');
  }

  static CacheManager? _manager;

  /// Shared cache manager for every remote image in the app.
  static CacheManager get manager {
    return _manager ??= CacheManager(
      Config(
        cacheKey,
        // Immich media is immutable per asset id, so entries can live a long
        // time; keep a year and a very large object budget.
        stalePeriod: const Duration(days: 365),
        maxNrOfCacheObjects: 20000,
        fileSystem: _NvmeFileSystem('media'),
        repo: JsonCacheInfoRepository(path: p.join(root, '$cacheKey.json')),
      ),
    );
  }

  /// Raise Flutter's in-memory decoded-image cache. The Pi has 8 GB RAM and
  /// the default is only 100 MB / 1000 images; a bigger budget means revisited
  /// photos redisplay instantly with no decode cost.
  static void configureImageCache() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = 2000; // decoded images
    cache.maximumSizeBytes = 640 << 20; // 640 MB of decoded bitmaps
  }

  /// Best-effort on-disk cache size, for display in Settings.
  static Future<int> diskUsageBytes() async {
    var total = 0;
    try {
      final dir = io.Directory(root);
      if (!await dir.exists()) return 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is io.File) {
          try {
            total += await e.length();
          } catch (_) {/* file vanished mid-scan */}
        }
      }
    } catch (e) {
      debugPrint('diskUsageBytes error: $e');
    }
    return total;
  }

  /// Wipe every cached image and API response.
  static Future<void> clear() async {
    try {
      await manager.emptyCache();
    } catch (e) {
      debugPrint('emptyCache error: $e');
    }
    try {
      final dir = io.Directory(p.join(root, 'api'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('clear api cache error: $e');
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

/// Stores cached files under ~/.cache/immich_kiosk_pi/<subdir> on the NVMe.
class _NvmeFileSystem implements FileSystem {
  final Future<io.Directory> _dir;
  final String _subdir;

  _NvmeFileSystem(this._subdir) : _dir = _create(_subdir);

  static Future<io.Directory> _create(String subdir) async {
    final dir = io.Directory(p.join(ImmichKioskPiCache.root, subdir));
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<File> createFile(String name) async {
    var dir = await _dir;
    if (!await dir.exists()) {
      dir = await _create(_subdir);
    }
    const fs = LocalFileSystem();
    return fs.directory(dir.path).childFile(name);
  }
}
