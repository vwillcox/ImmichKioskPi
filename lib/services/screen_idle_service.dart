import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart' show ScreenSettings;
import 'config_service.dart';
import 'playback_source.dart';

/// Switches the panel off by itself once there's nothing worth showing —
/// no slideshow, nothing playing, and nobody touching it — and brings it
/// back when there is.
///
/// The screen itself is switched by `deploy/screen_control.py`, the same
/// host-side service Alexa drives, rather than by this app: it runs as the
/// user who owns the Wayland session and can talk to `wlopm`, and it keeps
/// working when the kiosk app isn't running. That also means "off" dims the
/// backlight rather than cutting the DSI output, so the touch panel stays
/// powered — `screen_control.py` watches it and brings the screen straight
/// back up on a touch, with no involvement from here.
///
/// So this only decides *when* to ask. Touches still reach the app as
/// ordinary pointer events, which is what keeps the idle timer honest.
class ScreenIdleService {
  static const String _base = 'http://127.0.0.1:8765';

  /// Checked often enough to be responsive without being busy — the timeout
  /// itself is in minutes.
  static const Duration _checkInterval = Duration(seconds: 20);

  final ConfigService _configService;

  /// Both playback sources; either one playing counts as "in use".
  final List<PlaybackSource> _sources;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
  ));

  Timer? _timer;
  DateTime _lastInteraction = DateTime.now();
  bool _slideshowRunning = false;
  bool _musicWasPlaying = false;

  /// Only ever undone by us. If the screen was switched off some other way
  /// — by Alexa, say — waking it on music would be fighting whoever did.
  bool _offByUs = false;

  ScreenIdleService(this._configService, this._sources);

  ScreenSettings get _settings => _configService.config.screen;

  void start() {
    _timer ??= Timer.periodic(_checkInterval, (_) => _tick());
  }

  void dispose() {
    _timer?.cancel();
    _dio.close();
  }

  /// Any touch anywhere in the app. Also cancels a pending switch-off, and
  /// means a touch that woke the screen doesn't immediately re-arm it.
  void noteInteraction() {
    _lastInteraction = DateTime.now();
    _offByUs = false;
  }

  /// Set by [SlideshowScreen] while it's on screen — a running slideshow is
  /// the whole point of the display, so it never counts as idle.
  set slideshowRunning(bool running) {
    _slideshowRunning = running;
    if (running) noteInteraction();
  }

  bool get _musicPlaying =>
      _sources.any((s) => s.available && s.now.isPlaying);

  Future<void> _tick() async {
    final playing = _musicPlaying;
    final startedPlaying = playing && !_musicWasPlaying;
    _musicWasPlaying = playing;

    if (startedPlaying && _settings.wakeOnMusic && _offByUs) {
      await _setScreen(on: true);
      return;
    }

    if (!_settings.autoOffEnabled || _offByUs) return;

    // Anything actually being displayed or listened to keeps it awake.
    if (playing || _slideshowRunning) {
      _lastInteraction = DateTime.now();
      return;
    }

    final idleFor = DateTime.now().difference(_lastInteraction);
    if (idleFor >= Duration(minutes: _settings.idleMinutes)) {
      await _setScreen(on: false);
    }
  }

  Future<void> _setScreen({required bool on}) async {
    try {
      await _dio.get('$_base/screen/${on ? 'on' : 'off'}');
      _offByUs = !on;
      if (on) _lastInteraction = DateTime.now();
      debugPrint('ScreenIdle: turned screen ${on ? 'on' : 'off'}');
    } catch (e) {
      // Not fatal — the screen just stays as it is. Most likely
      // screen-control.service isn't running; see the README.
      debugPrint('ScreenIdle: could not switch screen ${on ? 'on' : 'off'}: $e');
    }
  }
}
