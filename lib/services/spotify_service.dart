import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, IconData;

import '../config/app_config.dart' show SpotifySettings;
import 'config_service.dart';
import 'now_playing_service.dart' show NowPlaying;
import 'playback_source.dart';

/// A Spotify Connect device the account can play on.
class SpotifyDevice {
  final String id;
  final String name;
  final String type;
  final bool isActive;
  const SpotifyDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isActive,
  });
}

/// Something that can be shown in a list and played or queued — a playlist,
/// a recently-played track, a top track. [uri] is what gets handed back to
/// Spotify to act on it.
class SpotifyItem {
  final String uri;
  final String title;
  final String subtitle;
  final String? artUrl;

  /// Playlists and albums are *contexts* (played with `context_uri`); tracks
  /// are individual (played with `uris`, or queued). They're handled
  /// differently by the play endpoint, so the distinction has to survive.
  final bool isContext;

  const SpotifyItem({
    required this.uri,
    required this.title,
    this.subtitle = '',
    this.artUrl,
    required this.isContext,
  });
}

/// Full playback control for a Spotify Premium account via the Web API:
/// play/pause/next/previous/seek/shuffle/repeat/volume, for whatever is
/// playing on any of the account's Spotify Connect devices (the phone, a
/// speaker, a computer). This is a control/display layer only — audio still
/// comes out of wherever Spotify is already routing it, typically the phone
/// over the same Bluetooth link the AVRCP source already uses. The Pi is not
/// made into a Spotify Connect playback target itself.
///
/// Authenticates with OAuth 2.0 Authorization Code + PKCE, so only a Client
/// ID is needed (free, from a Spotify Developer Dashboard app) — no secret to
/// protect on a kiosk. The one-time login opens a real browser window on the
/// Pi's own screen; a loopback HTTP server catches the redirect.
class SpotifyService extends ChangeNotifier implements PlaybackSource {
  static const _authorizeUrl = 'https://accounts.spotify.com/authorize';
  static const _tokenUrl = 'https://accounts.spotify.com/api/token';
  static const _apiBase = 'https://api.spotify.com/v1';

  /// Register this exact URI as a Redirect URI on the Spotify app in the
  /// Developer Dashboard.
  static const int redirectPort = 8909;
  static const String redirectUri = 'http://127.0.0.1:$redirectPort/callback';

  static const _scopes = 'user-read-playback-state user-modify-playback-state '
      'user-read-currently-playing user-library-read user-library-modify '
      'playlist-read-private playlist-modify-public playlist-modify-private '
      'user-read-recently-played user-top-read';

  static const Duration idleTimeout = Duration(minutes: 1);
  static const Duration _activePoll = Duration(seconds: 2);
  static const Duration _idlePoll = Duration(seconds: 10);
  /// Advances the shown position between real polls, so the progress bar
  /// moves smoothly instead of jumping once every [_activePoll] — the same
  /// reason AVRCP has its own 1-second position timer. Purely local; doesn't
  /// touch the network.
  static const Duration _tick = Duration(milliseconds: 250);

  final ConfigService _configService;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 8),
  ));

  SpotifyService(this._configService);

  SpotifySettings get _settings => _configService.config.spotify;

  String? _accessToken;
  DateTime? _accessTokenExpiry;
  Timer? _pollTimer;
  Timer? _tickTimer;
  bool _fastPolling = false;

  NowPlaying _now = const NowPlaying();
  @override
  NowPlaying get now => _now;

  String? _artUrl;
  @override
  String? get artUrl => _artUrl;

  bool _available = false;
  @override
  bool get available => _available;

  Timer? _idleTimer;
  bool _idleHidden = false;
  @override
  bool get idleHidden => _idleHidden;

  bool _deviceHasVolume = false;
  @override
  bool get hasVolume => _deviceHasVolume;
  int _volumePercent = 0;
  int _volumeBeforeMute = 0;
  @override
  double get volume => (_volumePercent / 100).clamp(0.0, 1.0);
  @override
  bool get muted => _volumePercent == 0;

  @override
  bool get canSeek => true;
  @override
  IconData get sourceIcon => Icons.podcasts;

  /// The track a liked-status request is currently in flight for — guards
  /// against a slow response landing after the track has already moved on.
  String? _likedCheckedForTrackId;
  bool _isLiked = false;

  /// Re-checked periodically rather than every single poll: liking/unliking
  /// from Spotify itself (the phone, the web player) while this same track
  /// keeps playing here otherwise never gets picked up, since nothing else
  /// about the player state changes to prompt a recheck.
  ///
  /// Kept deliberately infrequent. This endpoint is rate-limited far more
  /// tightly than the player one, and its answer changes rarely — polling it
  /// every 2s (the main poll interval) earned an hours-long 429 block, and
  /// even 20s was more than it tolerates sustained.
  DateTime? _lastLikedRecheckAt;
  String? _lastLikedRecheckTrackId;
  static const Duration _likedRecheckInterval = Duration(minutes: 1);

  /// When Spotify 429s, it says how long to stay away for — sometimes hours.
  /// Retrying regardless (as this used to) never recovers and only keeps the
  /// block alive, so nothing touches the API again until this passes.
  DateTime? _rateLimitedUntil;

  bool get _rateLimited {
    final until = _rateLimitedUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _rateLimitedUntil = null;
    return false;
  }

  /// Records a `Retry-After` if [e] is a 429. Returns true if it was one.
  bool _noteIfRateLimited(Object e, String what) {
    if (e is! DioException || e.response?.statusCode != 429) return false;
    final header = e.response?.headers.value('retry-after');
    final seconds = int.tryParse(header ?? '') ?? 60;
    _rateLimitedUntil = DateTime.now().add(Duration(seconds: seconds));
    debugPrint('Spotify rate-limited on $what; backing off ${seconds}s '
        '(until $_rateLimitedUntil)');
    return true;
  }

  @override
  bool get canLike => true;
  @override
  bool get isLiked => _isLiked;
  @override
  bool get canAddToPlaylist => true;

  Future<void> start() async {
    if (_settings.isConfigured) _beginPolling();
  }

  /// Call after settings change — right after [connect] or [disconnect].
  void refreshFromSettings() {
    _pollTimer?.cancel();
    if (_settings.isConfigured) {
      _beginPolling();
    } else {
      _tickTimer?.cancel();
      _tickTimer = null;
      _accessToken = null;
      _available = false;
      _now = const NowPlaying();
      _artUrl = null;
      notifyListeners();
    }
  }

  void _beginPolling() {
    unawaited(_poll());
    _speedUpPolling();
    _tickTimer ??= Timer.periodic(_tick, (_) => _advancePosition());
  }

  void _advancePosition() {
    if (!_now.isPlaying) return;
    final next = _now.position + _tick;
    // Let the next real poll settle the track change rather than guessing
    // what comes next (repeat, shuffle, end of queue, ...).
    if (next >= _now.duration) return;
    _now = _now.copyWith(position: next);
    notifyListeners();
  }

  // ---- OAuth: Authorization Code + PKCE -----------------------------------

  static final Random _rand = Random.secure();

  static String _randomUrlSafe(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(length, (_) => chars[_rand.nextInt(chars.length)])
        .join();
  }

  static String _base64UrlNoPad(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// The PKCE code_challenge for a given code_verifier: base64url(SHA-256()),
  /// no padding, per RFC 7636. Split out so it can be checked against the
  /// RFC's own worked example without needing a live OAuth round trip.
  @visibleForTesting
  static String codeChallengeFor(String verifier) =>
      _base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

  /// Opens a browser for the one-time Spotify login, catches the redirect on
  /// a loopback server, and exchanges the code for tokens. Returns null on
  /// success, or a message to show the user on failure.
  /// The command to open a URL in a real, visible browser window on this
  /// screen — not xdg-open, which on this Pi's bare labwc session (no full
  /// desktop environment) resolves to Chromium, but with defaults that
  /// crash it outright: it picks the X11 ozone platform and dies with
  /// "Missing X server or $DISPLAY", and even forced onto Wayland it blocks
  /// on a GNOME-Keyring "choose a password" prompt with nothing to do with
  /// Spotify. Both are suppressed by the flags below. Falls back to
  /// xdg-open on a machine where Chromium isn't the browser.
  Future<({String executable, List<String> args})> _browserCommand(
      String url) async {
    final chromium = await Process.run('which', ['chromium']);
    if (chromium.exitCode == 0) {
      return (
        executable: 'chromium',
        args: [
          '--ozone-platform=wayland',
          '--password-store=basic',
          '--new-window',
          url,
        ],
      );
    }
    return (executable: 'xdg-open', args: [url]);
  }

  Future<String?> connect(String clientId) async {
    final verifier = _randomUrlSafe(64);
    final challenge = codeChallengeFor(verifier);
    final state = _randomUrlSafe(16);

    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, redirectPort);
    } catch (e) {
      return 'Could not open port $redirectPort locally: $e';
    }

    final authUrl = Uri.parse(_authorizeUrl).replace(queryParameters: {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'scope': _scopes,
      'state': state,
    });

    try {
      final browser = await _browserCommand(authUrl.toString());
      await Process.start(browser.executable, browser.args);
    } catch (e) {
      await server.close(force: true);
      return 'Could not open a browser: $e';
    }

    String? code;
    String? error;
    try {
      final request = await server.first.timeout(const Duration(minutes: 3));
      final params = request.uri.queryParameters;
      if (params['state'] != state) {
        error = 'Spotify redirect did not match — try again.';
      } else if (params['error'] != null) {
        error = 'Spotify said: ${params['error']}';
      } else {
        code = params['code'];
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_callbackPage(error == null))
        ..close();
    } on TimeoutException {
      error = 'Timed out waiting for the Spotify login to complete.';
    } finally {
      await server.close(force: true);
    }
    if (error != null) return error;
    if (code == null) return 'Spotify did not return an authorization code.';

    try {
      final r = await _dio.post(
        _tokenUrl,
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'client_id': clientId,
          'code_verifier': verifier,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = r.data as Map;
      _accessToken = data['access_token'] as String;
      _accessTokenExpiry = DateTime.now()
          .add(Duration(seconds: (data['expires_in'] as int) - 60));
      final refreshToken = data['refresh_token'] as String?;
      if (refreshToken == null) return 'Spotify did not return a refresh token.';

      _settings.clientId = clientId;
      _settings.refreshToken = refreshToken;
      await _configService.save();
      refreshFromSettings();
      return null;
    } on DioException catch (e) {
      return 'Spotify rejected the login: ${e.response?.data ?? e.message}';
    }
  }

  String _callbackPage(bool ok) => '''
<!doctype html><html><body style="background:#111;color:#eee;font-family:sans-serif;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
<div style="text-align:center">
<h2>${ok ? 'Spotify connected' : 'Something went wrong'}</h2>
<p>${ok ? 'You can close this window.' : 'Go back to the kiosk and try again.'}</p>
</div></body></html>''';

  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _accessToken = null;
    _settings.clientId = '';
    _settings.refreshToken = '';
    await _configService.save();
    refreshFromSettings();
  }

  Future<String?> _validAccessToken() async {
    if (_accessToken != null &&
        _accessTokenExpiry != null &&
        DateTime.now().isBefore(_accessTokenExpiry!)) {
      return _accessToken;
    }
    return _refreshAccessToken();
  }

  Future<String?> _refreshAccessToken() async {
    if (!_settings.isConfigured) return null;
    try {
      final r = await _dio.post(
        _tokenUrl,
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': _settings.refreshToken,
          'client_id': _settings.clientId,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = r.data as Map;
      _accessToken = data['access_token'] as String;
      _accessTokenExpiry = DateTime.now()
          .add(Duration(seconds: (data['expires_in'] as int) - 60));
      // Spotify sometimes rotates the refresh token on use.
      final newRefresh = data['refresh_token'] as String?;
      if (newRefresh != null && newRefresh != _settings.refreshToken) {
        _settings.refreshToken = newRefresh;
        unawaited(_configService.save());
      }
      return _accessToken;
    } on DioException catch (e) {
      // A revoked/expired refresh token needs the user to reconnect from
      // Settings; leave the stored value alone rather than silently clearing
      // it, so what's wrong stays visible instead of just looking unset.
      debugPrint('Spotify token refresh failed: $e');
      return null;
    }
  }

  // ---- Polling --------------------------------------------------------------

  Future<void> _poll() async {
    final token = await _validAccessToken();
    if (token == null) return;
    try {
      final r = await _dio.get(
        '$_apiBase/me/player',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (r.statusCode == 204 || r.data is! Map) {
        _applyNothingPlaying();
        return;
      }
      _applyPlayerState((r.data as Map).cast<String, dynamic>());
    } catch (e) {
      if (!_noteIfRateLimited(e, 'player poll')) {
        debugPrint('Spotify poll error: $e');
      }
    }
  }

  void _applyNothingPlaying() {
    if (_available) {
      _available = false;
      _now = const NowPlaying();
      _artUrl = null;
      _isLiked = false;
      _likedCheckedForTrackId = null;
      _lastLikedRecheckAt = null;
      _lastLikedRecheckTrackId = null;
      notifyListeners();
    }
    _slowDownPolling();
  }

  void _applyPlayerState(Map<String, dynamic> data) {
    final item = data['item'] as Map<String, dynamic>?;
    if (item == null) {
      _applyNothingPlaying();
      return;
    }
    _speedUpPolling();

    final artists = (item['artists'] as List? ?? [])
        .map((a) => (a as Map)['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .join(', ');
    final album = item['album'] as Map<String, dynamic>?;
    final images = (album?['images'] as List? ?? []);
    final art = images.isNotEmpty ? images.first['url'] as String? : null;

    final device = data['device'] as Map<String, dynamic>?;
    final repeatState = data['repeat_state'] as String? ?? 'off';

    final trackId = item['id'] as String? ?? '';
    _now = NowPlaying(
      title: item['name'] as String? ?? '',
      artist: artists,
      album: album?['name'] as String? ?? '',
      duration: Duration(milliseconds: item['duration_ms'] as int? ?? 0),
      position: Duration(milliseconds: data['progress_ms'] as int? ?? 0),
      status: (data['is_playing'] as bool? ?? false) ? 'playing' : 'paused',
      repeat: repeatStateFrom(repeatState),
      shuffle: data['shuffle_state'] as bool? ?? false,
      deviceName: device?['name'] as String? ?? 'Spotify',
      trackId: trackId,
    );
    _artUrl = art;
    if (trackId.isNotEmpty && !_rateLimited) {
      final now = DateTime.now();
      final trackChanged = trackId != _lastLikedRecheckTrackId;
      final intervalElapsed = _lastLikedRecheckAt == null ||
          now.difference(_lastLikedRecheckAt!) >= _likedRecheckInterval;
      if (trackChanged || intervalElapsed) {
        _lastLikedRecheckAt = now;
        _lastLikedRecheckTrackId = trackId;
        unawaited(_refreshLikedStatus(trackId));
      }
    }
    _deviceHasVolume = device?['supports_volume'] as bool? ?? false;
    final vol = device?['volume_percent'];
    if (vol is int) {
      _volumePercent = vol;
      if (vol > 0) _volumeBeforeMute = vol;
    }
    _available = true;
    _updateIdleTimer();
    notifyListeners();
  }

  /// Poll briskly while a track is showing, and back off when nothing is —
  /// there's no point hammering the API once a minute has gone by with
  /// nothing to report.
  void _speedUpPolling() {
    if (_fastPolling) return;
    _fastPolling = true;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_activePoll, (_) => _poll());
  }

  void _slowDownPolling() {
    if (!_fastPolling) return;
    _fastPolling = false;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_idlePoll, (_) => _poll());
  }

  /// Playing -> show immediately and cancel any pending hide.
  /// Not playing -> start a one-shot timer that hides the panel afterwards.
  void _updateIdleTimer() {
    if (_now.isPlaying) {
      _idleTimer?.cancel();
      _idleTimer = null;
      if (_idleHidden) {
        _idleHidden = false;
        notifyListeners();
      }
      return;
    }
    if (_idleHidden || _idleTimer != null) return;
    _idleTimer = Timer(idleTimeout, () {
      _idleTimer = null;
      if (!_now.isPlaying) {
        _idleHidden = true;
        notifyListeners();
      }
    });
  }

  // ---- Controls ---------------------------------------------------------

  /// Omitting device_id targets whichever device is currently active on the
  /// account — the point of this being source-agnostic, rather than pinning
  /// control to one specific device.
  Future<void> _request(String method, String path,
      {Map<String, dynamic>? query}) async {
    final token = await _validAccessToken();
    if (token == null) return;
    try {
      await _dio.request(
        '$_apiBase$path',
        queryParameters: query,
        options: Options(
          method: method,
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
    } catch (e) {
      if (!_noteIfRateLimited(e, '$method $path')) {
        debugPrint('Spotify $method $path error: $e');
      }
    }
    // Reflect the change immediately rather than waiting for the next poll.
    unawaited(_poll());
  }

  @override
  Future<void> playPause() => _now.isPlaying
      ? _request('PUT', '/me/player/pause')
      : _request('PUT', '/me/player/play');
  @override
  Future<void> next() => _request('POST', '/me/player/next');
  @override
  Future<void> previous() => _request('POST', '/me/player/previous');
  @override
  Future<void> seek(Duration position) => _request('PUT', '/me/player/seek',
      query: {'position_ms': position.inMilliseconds});

  @override
  Future<void> cycleRepeat() async {
    final nextState = nextRepeatState(_now.repeat);
    await _request('PUT', '/me/player/repeat', query: {'state': nextState});
  }

  /// off -> repeat all -> repeat one -> off, matching the icon cycle the
  /// shared widget already uses for the AVRCP source. Takes/returns Spotify's
  /// own repeat_state vocabulary ('off'/'context'/'track'); [repeatStateFrom]
  /// converts the other way, from Spotify's vocabulary to the shared
  /// [NowPlaying.repeat] one the widget actually switches on.
  @visibleForTesting
  static String nextRepeatState(String uiRepeat) {
    const order = ['off', 'context', 'track'];
    final current = switch (uiRepeat) {
      'singletrack' => 'track',
      'alltracks' => 'context',
      _ => 'off',
    };
    return order[(order.indexOf(current) + 1) % order.length];
  }

  /// Spotify's repeat_state ('off'/'track'/'context') to the vocabulary
  /// [NowPlaying.repeat] already uses for the AVRCP source, so the shared
  /// widget's icon-switch works for either.
  @visibleForTesting
  static String repeatStateFrom(String spotifyRepeat) => switch (spotifyRepeat) {
        'track' => 'singletrack',
        'context' => 'alltracks',
        _ => 'off',
      };

  @override
  Future<void> toggleShuffle() => _request('PUT', '/me/player/shuffle',
      query: {'state': (!_now.shuffle).toString()});

  @override
  Future<void> setVolume(double fraction) async {
    final pct = (fraction.clamp(0.0, 1.0) * 100).round();
    _volumePercent = pct;
    if (pct > 0) _volumeBeforeMute = pct;
    notifyListeners();
    await _request('PUT', '/me/player/volume', query: {'volume_percent': pct});
  }

  @override
  Future<void> toggleMute() async {
    if (muted) {
      final restore = _volumeBeforeMute > 0 ? _volumeBeforeMute : 33;
      await setVolume(restore / 100);
    } else {
      _volumeBeforeMute = _volumePercent;
      await setVolume(0);
    }
  }

  // ---- Library & playlists -----------------------------------------------

  /// Spotify's February 2026 API change replaced the old per-type library
  /// endpoints (`/me/tracks`, `/me/tracks/contains`) with unified ones that
  /// take full URIs — the old ones now silently 403 instead of erroring
  /// usefully, which is how this was caught.
  static String _trackUri(String trackId) => 'spotify:track:$trackId';

  Future<void> _refreshLikedStatus(String trackId) async {
    if (_rateLimited) return;
    _likedCheckedForTrackId = trackId;
    final token = await _validAccessToken();
    if (token == null) return;
    try {
      final r = await _dio.get(
        '$_apiBase/me/library/contains',
        queryParameters: {'uris': _trackUri(trackId)},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (_likedCheckedForTrackId != trackId) return; // track changed meanwhile
      final list = r.data as List? ?? const [];
      _isLiked = list.isNotEmpty && list.first == true;
      notifyListeners();
    } catch (e) {
      if (!_noteIfRateLimited(e, 'liked-status')) {
        debugPrint('Spotify liked-status error: $e');
      }
    }
  }

  @override
  Future<void> toggleLike() async {
    final trackId = _now.trackId;
    if (trackId.isEmpty) return;
    final wasLiked = _isLiked;
    _isLiked = !wasLiked;
    notifyListeners();
    final token = await _validAccessToken();
    if (token == null) {
      _isLiked = wasLiked;
      notifyListeners();
      return;
    }
    try {
      await _dio.request(
        '$_apiBase/me/library',
        queryParameters: {'uris': _trackUri(trackId)},
        options: Options(
          method: wasLiked ? 'DELETE' : 'PUT',
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
    } catch (e) {
      _noteIfRateLimited(e, 'toggleLike');
      debugPrint('Spotify toggleLike error: $e');
      _isLiked = wasLiked;
      notifyListeners();
    }
  }

  @override
  Future<List<PlaylistInfo>> loadPlaylists() async {
    final token = await _validAccessToken();
    if (token == null) return const [];
    try {
      final r = await _dio.get(
        '$_apiBase/me/playlists',
        queryParameters: {'limit': 50},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final items = (r.data as Map)['items'] as List? ?? const [];
      return items
          .map((p) => PlaylistInfo(
                id: (p as Map)['id'] as String,
                name: p['name'] as String? ?? '',
              ))
          .toList();
    } catch (e) {
      if (!_noteIfRateLimited(e, 'loadPlaylists')) {
        debugPrint('Spotify loadPlaylists error: $e');
      }
      return const [];
    }
  }

  @override
  Future<void> addToPlaylist(String playlistId) async {
    final trackId = _now.trackId;
    if (trackId.isEmpty) return;
    final token = await _validAccessToken();
    if (token == null) return;
    try {
      await _dio.post(
        '$_apiBase/playlists/$playlistId/items',
        data: {'uris': [_trackUri(trackId)]},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    } catch (e) {
      if (!_noteIfRateLimited(e, 'addToPlaylist')) {
        debugPrint('Spotify addToPlaylist error: $e');
      }
    }
  }

  // ---- Devices, queue and browsing ---------------------------------------
  //
  // Everything below is fetched on demand, when the user opens the relevant
  // panel — never polled. The player endpoint is the only thing this app
  // polls, deliberately: these are rate-limited more tightly, and a kiosk
  // left running for weeks would otherwise rack up an enormous number of
  // requests for lists nobody is looking at.

  /// Fetches one list of items from an endpoint, mapping each entry with
  /// [map]. Shared by the recently-played/top/playlist loaders, which differ
  /// only in where the list lives in the response and how a row is built.
  Future<List<SpotifyItem>> _loadItems(
    String path,
    String what, {
    Map<String, dynamic>? query,
    required SpotifyItem? Function(Map<String, dynamic>) map,
  }) async {
    if (_rateLimited) return const [];
    final token = await _validAccessToken();
    if (token == null) return const [];
    try {
      final r = await _dio.get(
        '$_apiBase$path',
        queryParameters: query,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final items = (r.data as Map)['items'] as List? ?? const [];
      return items
          .map((e) => map((e as Map).cast<String, dynamic>()))
          .whereType<SpotifyItem>()
          .toList();
    } catch (e) {
      if (!_noteIfRateLimited(e, what)) {
        debugPrint('Spotify $what error: $e');
      }
      return const [];
    }
  }

  static String? _imageOf(Map<String, dynamic>? owner) {
    final images = owner?['images'] as List?;
    if (images == null || images.isEmpty) return null;
    return (images.first as Map)['url'] as String?;
  }

  static String _artistsOf(Map<String, dynamic> track) =>
      (track['artists'] as List? ?? [])
          .map((a) => (a as Map)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .join(', ');

  static SpotifyItem? _trackToItem(Map<String, dynamic>? track) {
    if (track == null) return null;
    final uri = track['uri'] as String?;
    if (uri == null) return null;
    return SpotifyItem(
      uri: uri,
      title: track['name'] as String? ?? '',
      subtitle: _artistsOf(track),
      artUrl: _imageOf((track['album'] as Map?)?.cast<String, dynamic>()),
      isContext: false,
    );
  }

  Future<List<SpotifyDevice>> loadDevices() async {
    if (_rateLimited) return const [];
    final token = await _validAccessToken();
    if (token == null) return const [];
    try {
      final r = await _dio.get(
        '$_apiBase/me/player/devices',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final devices = (r.data as Map)['devices'] as List? ?? const [];
      return devices
          .map((d) => (d as Map).cast<String, dynamic>())
          // A device with no id can't be transferred to.
          .where((d) => d['id'] is String)
          .map((d) => SpotifyDevice(
                id: d['id'] as String,
                name: d['name'] as String? ?? 'Unknown',
                type: d['type'] as String? ?? '',
                isActive: d['is_active'] as bool? ?? false,
              ))
          .toList();
    } catch (e) {
      if (!_noteIfRateLimited(e, 'loadDevices')) {
        debugPrint('Spotify loadDevices error: $e');
      }
      return const [];
    }
  }

  /// Moves playback to [deviceId], keeping whatever is currently playing.
  Future<void> transferPlayback(String deviceId) async {
    final token = await _validAccessToken();
    if (token == null) return;
    try {
      await _dio.put(
        '$_apiBase/me/player',
        data: {
          'device_ids': [deviceId],
          // keep playing/paused as it was rather than forcing playback
          'play': _now.isPlaying,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    } catch (e) {
      if (!_noteIfRateLimited(e, 'transferPlayback')) {
        debugPrint('Spotify transferPlayback error: $e');
      }
    }
    unawaited(_poll());
  }

  /// What's coming up next. The response's `queue` is upcoming items only —
  /// `currently_playing` is separate and already shown by the panel.
  Future<List<SpotifyItem>> loadQueue() async {
    if (_rateLimited) return const [];
    final token = await _validAccessToken();
    if (token == null) return const [];
    try {
      final r = await _dio.get(
        '$_apiBase/me/player/queue',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final queue = (r.data as Map)['queue'] as List? ?? const [];
      return queue
          .map((t) => _trackToItem((t as Map).cast<String, dynamic>()))
          .whereType<SpotifyItem>()
          .toList();
    } catch (e) {
      if (!_noteIfRateLimited(e, 'loadQueue')) {
        debugPrint('Spotify loadQueue error: $e');
      }
      return const [];
    }
  }

  Future<List<SpotifyItem>> loadPlaylistItems() => _loadItems(
        '/me/playlists',
        'loadPlaylistItems',
        query: {'limit': 50},
        map: (p) {
          final uri = p['uri'] as String?;
          if (uri == null) return null;
          final tracks = (p['tracks'] as Map?)?['total'];
          return SpotifyItem(
            uri: uri,
            title: p['name'] as String? ?? '',
            subtitle: tracks is int ? '$tracks tracks' : '',
            artUrl: _imageOf(p),
            isContext: true,
          );
        },
      );

  Future<List<SpotifyItem>> loadRecentlyPlayed() => _loadItems(
        '/me/player/recently-played',
        'loadRecentlyPlayed',
        query: {'limit': 30},
        // each entry wraps the track under `track`
        map: (e) => _trackToItem((e['track'] as Map?)?.cast<String, dynamic>()),
      );

  Future<List<SpotifyItem>> loadTopTracks() => _loadItems(
        '/me/top/tracks',
        'loadTopTracks',
        query: {'limit': 30, 'time_range': 'medium_term'},
        map: (t) => _trackToItem(t),
      );

  /// Starts [item] playing on whatever device is currently active.
  Future<void> play(SpotifyItem item) async {
    final token = await _validAccessToken();
    if (token == null) return;
    try {
      await _dio.put(
        '$_apiBase/me/player/play',
        // a playlist/album is a context to play *within*; a single track is
        // not, and has to be passed as a one-item uri list instead
        data: item.isContext
            ? {'context_uri': item.uri}
            : {
                'uris': [item.uri]
              },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    } catch (e) {
      if (!_noteIfRateLimited(e, 'play')) {
        debugPrint('Spotify play error: $e');
      }
    }
    unawaited(_poll());
  }

  Future<void> queue(SpotifyItem item) async {
    if (item.isContext) return; // only tracks/episodes can be queued
    await _request('POST', '/me/player/queue', query: {'uri': item.uri});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _idleTimer?.cancel();
    _dio.close();
    super.dispose();
  }
}
