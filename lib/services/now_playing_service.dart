import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, IconData;

import 'playback_source.dart';

/// What the connected phone is playing, read from BlueZ over D-Bus.
class NowPlaying {
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final Duration position;
  final String status; // 'playing' | 'paused' | 'stopped' | 'forward-seek' ...
  final String repeat; // 'off' | 'singletrack' | 'alltracks' | 'group'
  final bool shuffle;
  final String deviceName;

  /// Spotify's own track ID, for the library ("like") and playlist APIs.
  /// Empty for AVRCP, which has no such concept.
  final String trackId;

  const NowPlaying({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.status = 'stopped',
    this.repeat = 'off',
    this.shuffle = false,
    this.deviceName = '',
    this.trackId = '',
  });

  bool get isPlaying => status == 'playing';

  /// True when there's a real track to show (AVRCP reports "Not Provided"
  /// before the phone sends anything useful).
  bool get hasTrack =>
      title.isNotEmpty && title != 'Not Provided' && status != 'stopped';

  double get progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  /// Key used for artwork lookups — changes only when the track does.
  String get trackKey => '$artist|$title';
}

/// Reads "now playing" from a Bluetooth-connected phone via BlueZ's AVRCP
/// support (`org.bluez.MediaPlayer1`) and sends transport commands back.
///
/// The phone must be paired and streaming media audio to the Pi; that is what
/// brings the AVRCP control channel up. Album art isn't carried over AVRCP, so
/// it's looked up separately from the iTunes Search API by artist + title.
class NowPlayingService extends ChangeNotifier implements PlaybackSource {
  static const String _bluez = 'org.bluez';
  static const String _playerIface = 'org.bluez.MediaPlayer1';
  static const String _deviceIface = 'org.bluez.Device1';
  static const String _transportIface = 'org.bluez.MediaTransport1';
  /// AVRCP absolute volume is 0-127.
  static const int _maxVolume = 127;

  DBusClient? _client;
  DBusRemoteObject? _player;
  String? _playerPath;
  DBusRemoteObject? _transport;
  String? _transportPath;

  int _volume = 0; // raw AVRCP value, 0-127
  int _volumeBeforeMute = 0;

  /// Whether the Pi is set to take the phone's audio (A2DP sink enabled).
  /// When false the phone keeps its own audio — headphones, its own speaker —
  /// and this display is purely a remote control. AVRCP metadata and transport
  /// keep working either way.
  ///
  /// This mirrors the chosen setting rather than probing PipeWire links: links
  /// only exist while audio is actively streaming, so a paused track would
  /// otherwise look like the audio had been disconnected.
  bool get audioRouted => _preferAudioRouted;

  /// Volume as 0..1 for the UI.
  @override
  double get volume => (_volume / _maxVolume).clamp(0.0, 1.0);
  @override
  bool get muted => _volume == 0;
  @override
  bool get hasVolume => _transport != null;

  StreamSubscription<DBusSignal>? _signalSub;
  Timer? _positionTimer;

  /// How long the panel lingers after the music stops before hiding itself.
  static const Duration idleTimeout = Duration(minutes: 1);
  Timer? _idleTimer;
  bool _idleHidden = false;

  /// True once nothing has been playing for [idleTimeout]. Cleared the instant
  /// playback resumes, so the panel comes straight back.
  @override
  bool get idleHidden => _idleHidden;

  NowPlaying _now = const NowPlaying();
  @override
  NowPlaying get now => _now;

  @override
  bool get available => _player != null;

  String? _artUrl;
  @override
  String? get artUrl => _artUrl;
  String _artForKey = '';
  final Map<String, String?> _artCache = {};

  Future<void> start() async {
    try {
      _client = DBusClient.system();
      await _findPlayer();
      await _watchObjectManager();
      // BlueZ doesn't push Position updates, so poll while playing.
      _positionTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshPosition(),
      );
    } catch (e) {
      debugPrint('NowPlayingService.start error: $e');
    }
  }

  /// One subscription covers everything under org.bluez: the phone appearing
  /// and disappearing, and live property updates for the active player.
  Future<void> _watchObjectManager() async {
    final root =
        DBusRemoteObjectManager(_client!, name: _bluez, path: DBusObjectPath('/'));
    _signalSub = root.signals.listen((signal) {
      if (signal is DBusObjectManagerInterfacesAddedSignal) {
        if (signal.interfacesAndProperties.containsKey(_playerIface)) {
          _attach(signal.changedPath.value);
        }
      } else if (signal is DBusObjectManagerInterfacesRemovedSignal) {
        if (signal.interfaces.contains(_playerIface) &&
            signal.changedPath.value == _playerPath) {
          _detach();
        }
      } else if (signal is DBusObjectManagerInterfacesAddedSignal &&
          signal.interfacesAndProperties.containsKey(_transportIface)) {
        _attachTransport(signal.changedPath.value);
      } else if (signal is DBusPropertiesChangedSignal) {
        if (signal.propertiesInterface == _playerIface &&
            signal.path.value == _playerPath) {
          _applyProperties(signal.changedProperties);
        } else if (signal.propertiesInterface == _transportIface &&
            signal.path.value == _transportPath) {
          // The phone can change volume at its end too.
          final v = signal.changedProperties['Volume'];
          if (v != null) {
            _volume = v.asUint16();
            if (_volume > 0) _volumeBeforeMute = _volume;
            notifyListeners();
          }
        }
      }
    });
  }

  Future<void> _findPlayer() async {
    final root = DBusRemoteObjectManager(_client!, name: _bluez, path: DBusObjectPath('/'));
    final objects = await root.getManagedObjects();
    for (final entry in objects.entries) {
      if (entry.value.containsKey(_playerIface)) {
        await _attach(entry.key.value);
      }
      // Volume lives on the audio transport, not the player.
      if (entry.value.containsKey(_transportIface)) {
        _attachTransport(entry.key.value);
      }
    }
  }

  void _attachTransport(String path) {
    _transportPath = path;
    _transport =
        DBusRemoteObject(_client!, name: _bluez, path: DBusObjectPath(path));
    unawaited(_refreshVolume());
  }

  Future<void> _refreshVolume() async {
    try {
      final v = await _transport?.getProperty(_transportIface, 'Volume');
      if (v != null) {
        _volume = v.asUint16();
        if (_volume > 0) _volumeBeforeMute = _volume;
        notifyListeners();
      }
    } catch (_) {
      // Transport can disappear when the phone disconnects.
    }
  }

  /// Set volume from a 0..1 slider value.
  @override
  Future<void> setVolume(double fraction) async {
    final raw = (fraction.clamp(0.0, 1.0) * _maxVolume).round();
    _volume = raw;
    if (raw > 0) _volumeBeforeMute = raw;
    notifyListeners();
    try {
      await _transport?.setProperty(
          _transportIface, 'Volume', DBusUint16(raw));
    } catch (e) {
      debugPrint('setVolume error: $e');
    }
  }

  /// Mute drops the volume to zero and remembers where it was.
  @override
  Future<void> toggleMute() async {
    if (muted) {
      final restore = _volumeBeforeMute > 0 ? _volumeBeforeMute : _maxVolume ~/ 3;
      await setVolume(restore / _maxVolume);
    } else {
      _volumeBeforeMute = _volume;
      await setVolume(0);
    }
  }

  Future<void> _attach(String path) async {
    _playerPath = path;
    _player = DBusRemoteObject(_client!, name: _bluez, path: DBusObjectPath(path));
    await _refreshAll();
    // Re-apply the "control only" preference: PipeWire turns the audio profile
    // back on by itself when the phone reconnects.
    if (!_preferAudioRouted) await setAudioRouted(false);
  }

  /// Desired routing, set from Settings and re-applied on reconnect.
  bool _preferAudioRouted = true;
  set preferAudioRouted(bool v) {
    _preferAudioRouted = v;
    unawaited(setAudioRouted(v));
  }

  void _detach() {
    _player = null;
    _playerPath = null;
    _transport = null;
    _transportPath = null;
    _now = const NowPlaying();
    _artUrl = null;
    _artForKey = '';
    _idleTimer?.cancel();
    _idleTimer = null;
    _idleHidden = false;
    notifyListeners();
  }

  /// Friendly name of the phone, from the parent Device1 object.
  Future<String> _deviceName() async {
    try {
      final path = _playerPath;
      if (path == null) return '';
      final devicePath = path.substring(0, path.lastIndexOf('/'));
      final dev = DBusRemoteObject(_client!,
          name: _bluez, path: DBusObjectPath(devicePath));
      final v = await dev.getProperty(_deviceIface, 'Alias');
      return (v as DBusString).value;
    } catch (_) {
      return '';
    }
  }

  Future<void> _refreshAll() async {
    final p = _player;
    if (p == null) return;
    try {
      final props = await p.getAllProperties(_playerIface);
      final name = await _deviceName();
      _applyProperties(props, deviceName: name, notify: false);
      notifyListeners();
    } catch (e) {
      debugPrint('NowPlaying refresh error: $e');
    }
  }

  void _applyProperties(
    Map<String, DBusValue> props, {
    String? deviceName,
    bool notify = true,
  }) {
    var title = _now.title;
    var artist = _now.artist;
    var album = _now.album;
    var duration = _now.duration;

    final track = props['Track'];
    if (track != null) {
      final map = track.asStringVariantDict();
      String str(String key) =>
          map[key] is DBusString ? map[key]!.asString() : '';
      int uint(String key) =>
          map[key] is DBusUint32 ? map[key]!.asUint32() : 0;
      title = str('Title');
      artist = str('Artist');
      album = str('Album');
      duration = Duration(milliseconds: uint('Duration'));
    }

    final status = props['Status'] is DBusString
        ? (props['Status'] as DBusString).value
        : _now.status;
    final repeat = props['Repeat'] is DBusString
        ? (props['Repeat'] as DBusString).value
        : _now.repeat;
    final shuffleRaw = props['Shuffle'] is DBusString
        ? (props['Shuffle'] as DBusString).value
        : (_now.shuffle ? 'alltracks' : 'off');
    final position = props['Position'] is DBusUint32
        ? Duration(milliseconds: (props['Position'] as DBusUint32).value)
        : _now.position;

    _now = NowPlaying(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      position: position,
      status: status,
      repeat: repeat,
      shuffle: shuffleRaw != 'off',
      deviceName: deviceName ?? _now.deviceName,
    );

    _updateIdleTimer();

    if (_now.hasTrack && _now.trackKey != _artForKey) {
      _artForKey = _now.trackKey;
      unawaited(_lookupArtwork(_now.artist, _now.title));
    }
    if (notify) notifyListeners();
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
    // Already counting down: let the existing timer run rather than restarting
    // it on every unrelated property change.
    if (_idleHidden || _idleTimer != null) return;
    _idleTimer = Timer(idleTimeout, () {
      _idleTimer = null;
      if (!_now.isPlaying) {
        _idleHidden = true;
        notifyListeners();
      }
    });
  }

  Future<void> _refreshPosition() async {
    final p = _player;
    if (p == null || !_now.isPlaying) return;
    try {
      final v = await p.getProperty(_playerIface, 'Position');
      if (v is DBusUint32) {
        _now = NowPlaying(
          title: _now.title,
          artist: _now.artist,
          album: _now.album,
          duration: _now.duration,
          position: Duration(milliseconds: v.value),
          status: _now.status,
          repeat: _now.repeat,
          shuffle: _now.shuffle,
          deviceName: _now.deviceName,
        );
        notifyListeners();
      }
    } catch (_) {
      // The player can vanish mid-poll when the phone disconnects.
    }
  }

  // ---- Audio routing ------------------------------------------------------

  /// The Bluetooth card id in PipeWire, needed to switch its profile.
  Future<String?> _bluezCardId() async {
    try {
      final r = await Process.run('wpctl', ['status']);
      if (r.exitCode != 0) return null;
      for (final line in (r.stdout as String).split('\n')) {
        if (line.contains('[bluez5]')) {
          final m = RegExp(r'(\d+)\.').firstMatch(line);
          if (m != null) return m.group(1);
        }
      }
    } catch (e) {
      debugPrint('bluez card lookup error: $e');
    }
    return null;
  }

  /// Choose whether the Pi plays the phone's audio, or only controls it.
  ///
  /// Profile "off" stops the A2DP sink so the phone keeps its audio (e.g. to
  /// headphones) while AVRCP metadata and transport still work — verified on
  /// the device. Note PipeWire may re-enable the profile when the phone
  /// reconnects, so this is applied again on reconnect.
  Future<void> setAudioRouted(bool routed) async {
    _preferAudioRouted = routed;
    notifyListeners();
    final id = await _bluezCardId();
    if (id == null) return;
    try {
      // 0 = Off, 65536 = Audio Gateway (A2DP Source & HSP/HFP AG)
      await Process.run('wpctl', ['set-profile', id, routed ? '65536' : '0']);
    } catch (e) {
      debugPrint('setAudioRouted error: $e');
    }
  }

  // ---- Transport controls -------------------------------------------------

  Future<void> _call(String method) async {
    try {
      await _player?.callMethod(_playerIface, method, [],
          replySignature: DBusSignature(''));
    } catch (e) {
      debugPrint('NowPlaying $method error: $e');
    }
  }

  @override
  Future<void> playPause() =>
      _now.isPlaying ? _call('Pause') : _call('Play');
  @override
  Future<void> next() => _call('Next');
  @override
  Future<void> previous() => _call('Previous');

  /// BlueZ's AVRCP surface has no absolute-seek method, only relative
  /// fast-forward/rewind, so there's nothing faithful to do here.
  @override
  bool get canSeek => false;
  @override
  Future<void> seek(Duration position) async {}

  @override
  IconData get sourceIcon => Icons.bluetooth_audio;

  /// BlueZ's AVRCP surface has no library or playlist API — those are
  /// Spotify Web API concepts only.
  @override
  bool get canLike => false;
  @override
  bool get isLiked => false;
  @override
  Future<void> toggleLike() async {}
  @override
  bool get canAddToPlaylist => false;
  @override
  Future<List<PlaylistInfo>> loadPlaylists() async => const [];
  @override
  Future<void> addToPlaylist(String playlistId) async {}

  Future<void> _setProperty(String name, String value) async {
    try {
      await _player?.setProperty(_playerIface, name, DBusString(value));
    } catch (e) {
      debugPrint('NowPlaying set $name error: $e');
    }
  }

  /// Cycle off -> repeat this track -> repeat all -> off.
  @override
  Future<void> cycleRepeat() async {
    const order = ['off', 'singletrack', 'alltracks'];
    final i = order.indexOf(_now.repeat);
    await _setProperty('Repeat', order[(i + 1) % order.length]);
  }

  @override
  Future<void> toggleShuffle() =>
      _setProperty('Shuffle', _now.shuffle ? 'off' : 'alltracks');

  // ---- Album artwork ------------------------------------------------------

  /// AVRCP carries no cover art, so resolve it from the iTunes Search API.
  /// Searching by song (artist + title) is far more accurate than by album:
  /// AVRCP album strings often carry suffixes like "(Deluxe) [Explicit]".
  Future<void> _lookupArtwork(String artist, String title) async {
    final key = '$artist|$title';
    if (_artCache.containsKey(key)) {
      _artUrl = _artCache[key];
      notifyListeners();
      return;
    }
    _artUrl = null;
    notifyListeners();
    try {
      final r = await Dio().get(
        'https://itunes.apple.com/search',
        queryParameters: {
          'term': '$artist $title'.trim(),
          'entity': 'song',
          'limit': 3,
        },
        options: Options(
          // iTunes replies with Content-Type: text/javascript, so Dio won't
          // decode it automatically — take the body as text and parse it here.
          responseType: ResponseType.plain,
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final body = r.data is String
          ? jsonDecode(r.data as String) as Map<String, dynamic>
          : (r.data as Map).cast<String, dynamic>();
      final results = (body['results'] as List?) ?? const [];
      String? art;
      for (final item in results) {
        final a = (item['artistName'] ?? '').toString().toLowerCase();
        // Prefer a result whose artist actually matches.
        if (artist.isEmpty || a.contains(artist.toLowerCase().split(' ').first)) {
          art = (item['artworkUrl100'] ?? '').toString();
          break;
        }
      }
      art ??= results.isNotEmpty
          ? (results.first['artworkUrl100'] ?? '').toString()
          : null;
      if (art != null && art.isNotEmpty) {
        art = art.replaceAll('100x100bb', '600x600bb');
      } else {
        art = null;
      }
      _artCache[key] = art;
      if (_artForKey == key) {
        _artUrl = art;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('artwork lookup error: $e');
      _artCache[key] = null;
    }
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _idleTimer?.cancel();
    _signalSub?.cancel();
    _client?.close();
    super.dispose();
  }
}
