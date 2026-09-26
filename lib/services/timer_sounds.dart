import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../app_paths.dart';
import 'media_cache.dart';

/// The sounds a kitchen timer can make when it is done: a few that come with
/// the app, and any MP3 somebody has uploaded from the editor.
///
/// A sound is named by an id, which is what a widget's settings keep:
/// `none`, a built-in's name (`chime`), or `custom:<file name>` for an
/// upload. Uploads live under the settings folder rather than the cache, so
/// clearing the cache does not silently turn a timer mute.
class TimerSounds {
  TimerSounds({String? uploadDir, String? cacheDir})
    : uploadDir = uploadDir ?? p.join(AppPaths.config, 'sounds'),
      _cacheDir = cacheDir ?? p.join(HomeCanvasCache.root, 'timer-sounds');

  final String uploadDir;
  final String _cacheDir;

  static const none = 'none';
  static const customPrefix = 'custom:';

  /// The sounds that come with the app, in the order the editor offers them.
  static const builtIn = {
    'chime': 'Chime',
    'bell': 'Bell',
    'beeps': 'Beeps',
    'alarm': 'Alarm clock',
    'marimba': 'Marimba',
  };

  /// Every choice there is, built-ins first, for the editor's dropdown.
  static const defaultChoices = {none: 'No sound', ...builtIn};

  /// The kinds of file an upload may be. MP3 is what was asked for; WAV and
  /// Ogg cost nothing more to play.
  static const _extensions = {'.mp3', '.wav', '.ogg'};

  /// Big enough for a song's worth of MP3, small enough that a mistaken
  /// upload does not fill the SD card.
  static const maxUploadBytes = 5 * 1024 * 1024;

  /// A sound is cut off after this long: it is meant to say "done", and one
  /// that runs longer would still be playing when the timer repeats itself.
  static const maxPlay = Duration(seconds: 20);

  Player? _player;

  /// Completed by [stop], so a [play] waiting for its sound to end returns.
  Completer<void>? _stopped;

  /// id → a name to show: the built-ins, then each upload by its file name.
  Future<Map<String, String>> choices() async {
    final out = Map<String, String>.of(defaultChoices);
    for (final name in await uploads()) {
      out['$customPrefix$name'] = '$name (uploaded)';
    }
    return out;
  }

  /// The uploaded files' names, sorted.
  Future<List<String>> uploads() async {
    final dir = Directory(uploadDir);
    if (!await dir.exists()) return const [];
    final names = <String>[];
    await for (final e in dir.list()) {
      final name = p.basename(e.path);
      if (e is File && safeName(name) == name) names.add(name);
    }
    return names..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// [name] cut down to something safe to keep as a file: letters, digits,
  /// spaces, dots, dashes and underscores, ending in a sound's extension.
  /// Null when nothing usable is left. Never a path — any folder in front is
  /// dropped, so an upload cannot land anywhere but [uploadDir].
  static String? safeName(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final ext = p.extension(base).toLowerCase();
    if (!_extensions.contains(ext)) return null;
    final stem = base
        .substring(0, base.length - ext.length)
        .replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // No hidden files, and nothing made only of dots.
    if (stem.isEmpty || stem.startsWith('.')) return null;
    final short = stem.length > 60 ? stem.substring(0, 60).trim() : stem;
    return '$short$ext';
  }

  /// Whether [bytes] look like the audio [name] says they are, by the first
  /// few bytes — enough to stop a renamed text file or image being kept.
  static bool looksLikeAudio(String name, Uint8List bytes) {
    if (bytes.length < 12) return false;
    bool starts(String s) {
      for (var i = 0; i < s.length; i++) {
        if (bytes[i] != s.codeUnitAt(i)) return false;
      }
      return true;
    }

    switch (p.extension(name).toLowerCase()) {
      case '.mp3':
        // An ID3 tag, or straight into an MPEG frame's sync bits.
        return starts('ID3') || (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0);
      case '.wav':
        return starts('RIFF') &&
            String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE';
      case '.ogg':
        return starts('OggS');
    }
    return false;
  }

  /// Keeps an upload, and returns the id to choose it by. Throws a
  /// [FormatException] saying what is wrong with it otherwise.
  Future<String> save(String name, Uint8List bytes) async {
    final safe = safeName(name);
    if (safe == null) {
      throw const FormatException('Only MP3, WAV or Ogg files can be used.');
    }
    if (bytes.length > maxUploadBytes) {
      throw const FormatException('That file is over 5 MB.');
    }
    if (!looksLikeAudio(safe, bytes)) {
      throw const FormatException("That file doesn't look like a sound.");
    }
    await Directory(uploadDir).create(recursive: true);
    await File(p.join(uploadDir, safe)).writeAsBytes(bytes, flush: true);
    return '$customPrefix$safe';
  }

  /// Forgets an upload. Built-ins cannot be deleted; false for those, and
  /// for anything not there.
  Future<bool> delete(String id) async {
    final file = _uploadFile(id);
    if (file == null || !await file.exists()) return false;
    await file.delete();
    return true;
  }

  File? _uploadFile(String id) {
    if (!id.startsWith(customPrefix)) return null;
    final name = id.substring(customPrefix.length);
    // Only ever a name that could have been saved — never a path.
    if (safeName(name) != name) return null;
    return File(p.join(uploadDir, name));
  }

  /// The sound's bytes, for the editor to preview in the browser. Null for
  /// `none` and anything unknown.
  Future<Uint8List?> bytes(String id) async {
    if (builtIn.containsKey(id)) {
      final data = await rootBundle.load(_asset(id));
      return data.buffer.asUint8List();
    }
    final file = _uploadFile(id);
    if (file == null || !await file.exists()) return null;
    return file.readAsBytes();
  }

  static String _asset(String id) => 'assets/sounds/timer/$id.wav';

  /// A file media_kit can play for [id], or null. Built-ins are copied out of
  /// the bundle on first use, the same way the share chime is.
  Future<String?> path(String id) async {
    if (builtIn.containsKey(id)) {
      final out = File(p.join(_cacheDir, '$id.wav'));
      if (!await out.exists()) {
        final data = await rootBundle.load(_asset(id));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      return out.path;
    }
    final file = _uploadFile(id);
    if (file == null || !await file.exists()) return null;
    return file.path;
  }

  /// Plays [id] and returns once it has finished, or after [maxPlay]. Quietly
  /// does nothing for `none`, or for an upload that has since been deleted:
  /// the timer still says it is done.
  Future<void> play(String id, {double volume = 100}) async {
    if (id == none) return;
    try {
      final file = await path(id);
      if (file == null) {
        debugPrint('TimerSounds: no sound called $id');
        return;
      }
      // Its own player, like the chime and the voice, so a timer going off
      // does not stop the music.
      final player = _player ??= Player();
      await player.setVolume(volume);
      final stopped = _stopped = Completer<void>();
      await player.open(Media(file));
      final finished = await Future.any([
        player.stream.completed.firstWhere((done) => done),
        stopped.future.then((_) => true),
      ]).timeout(maxPlay, onTimeout: () => false);
      if (!finished) await player.stop();
    } catch (e) {
      debugPrint('TimerSounds: $e');
    }
  }

  /// Stops whatever is playing.
  Future<void> stop() async {
    final stopped = _stopped;
    if (stopped != null && !stopped.isCompleted) stopped.complete();
    try {
      await _player?.stop();
    } catch (_) {}
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}
