import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'media_cache.dart';

/// Small JSON-on-disk cache for Immich API responses (album list, album
/// contents). Lives on the NVMe next to the media cache so the album grid can
/// paint instantly from disk on a cold start, before the network responds.
class ApiCache {
  ApiCache._();

  static Directory get _dir => Directory(p.join(ImmichKioskPiCache.root, 'api'));

  static File _fileFor(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return File(p.join(_dir.path, '$safe.json'));
  }

  /// Read a cached payload. Returns null when missing or unreadable.
  /// [maxAge] bounds how old an entry may be; null accepts any age.
  static Future<dynamic> read(String key, {Duration? maxAge}) async {
    try {
      final f = _fileFor(key);
      if (!await f.exists()) return null;
      if (maxAge != null) {
        final age = DateTime.now().difference(await f.lastModified());
        if (age > maxAge) return null;
      }
      return jsonDecode(await f.readAsString());
    } catch (e) {
      debugPrint('ApiCache.read($key) error: $e');
      return null;
    }
  }

  static Future<void> write(String key, dynamic payload) async {
    try {
      final f = _fileFor(key);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(payload));
    } catch (e) {
      debugPrint('ApiCache.write($key) error: $e');
    }
  }
}
