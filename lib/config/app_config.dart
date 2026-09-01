/// Persistent app configuration (connection, slideshow, weather overlay).
library;

import '../dashboard/dashboard_model.dart';

enum SlideshowTransition { fade, slide, kenBurns, pageTurn }

SlideshowTransition _transitionFromString(String? s) {
  switch (s) {
    case 'slide':
      return SlideshowTransition.slide;
    case 'kenBurns':
      return SlideshowTransition.kenBurns;
    case 'pageTurn':
      return SlideshowTransition.pageTurn;
    case 'fade':
    default:
      return SlideshowTransition.fade;
  }
}

String transitionToString(SlideshowTransition t) {
  switch (t) {
    case SlideshowTransition.slide:
      return 'slide';
    case SlideshowTransition.kenBurns:
      return 'kenBurns';
    case SlideshowTransition.pageTurn:
      return 'pageTurn';
    case SlideshowTransition.fade:
      return 'fade';
  }
}

class SlideshowSettings {
  int intervalSeconds;
  SlideshowTransition transition;
  bool shuffle;
  bool includeVideos;

  SlideshowSettings({
    this.intervalSeconds = 6,
    this.transition = SlideshowTransition.fade,
    this.shuffle = true,
    this.includeVideos = false,
  });

  factory SlideshowSettings.fromJson(Map<String, dynamic> j) {
    return SlideshowSettings(
      intervalSeconds: (j['intervalSeconds'] as num?)?.toInt() ?? 6,
      transition: _transitionFromString(j['transition'] as String?),
      shuffle: j['shuffle'] as bool? ?? true,
      includeVideos: j['includeVideos'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'intervalSeconds': intervalSeconds,
        'transition': transitionToString(transition),
        'shuffle': shuffle,
        'includeVideos': includeVideos,
      };
}

enum OverlayCorner { topLeft, topRight, bottomLeft, bottomRight }

/// The panels that float in a corner. Their positions are managed together
/// so that two can never be assigned the same one — see
/// [AppConfig.assignCorner].
enum OverlaySlot { weather, nowPlaying, camera }

String slotLabel(OverlaySlot s) {
  switch (s) {
    case OverlaySlot.weather:
      return 'Weather';
    case OverlaySlot.nowPlaying:
      return 'Now playing';
    case OverlaySlot.camera:
      return 'Camera';
  }
}

OverlayCorner _cornerFromString(String? s) {
  switch (s) {
    case 'topLeft':
      return OverlayCorner.topLeft;
    case 'bottomLeft':
      return OverlayCorner.bottomLeft;
    case 'bottomRight':
      return OverlayCorner.bottomRight;
    case 'topRight':
    default:
      return OverlayCorner.topRight;
  }
}

String cornerToString(OverlayCorner c) => c.name;

String cornerLabel(OverlayCorner c) {
  switch (c) {
    case OverlayCorner.topLeft:
      return 'Top left';
    case OverlayCorner.topRight:
      return 'Top right';
    case OverlayCorner.bottomLeft:
      return 'Bottom left';
    case OverlayCorner.bottomRight:
      return 'Bottom right';
  }
}

class WeatherSettings {
  bool enabled;

  /// What the user typed: a UK postcode ("CO1 1ZY") or a place name.
  String location;
  OverlayCorner corner;

  /// true = °C, false = °F
  bool metric;

  /// Show the indoor reading from a Govee BLE sensor alongside the forecast.
  bool showIndoor;

  // Cached resolution of [location] so we don't geocode on every launch.
  double? latitude;
  double? longitude;
  String? resolvedLabel;

  WeatherSettings({
    this.enabled = true,
    this.location = 'CO1 1ZY',
    this.corner = OverlayCorner.topRight,
    this.metric = true,
    this.showIndoor = true,
    this.latitude,
    this.longitude,
    this.resolvedLabel,
  });

  factory WeatherSettings.fromJson(Map<String, dynamic> j) => WeatherSettings(
        enabled: j['enabled'] as bool? ?? true,
        location: j['location'] as String? ?? 'CO1 1ZY',
        corner: _cornerFromString(j['corner'] as String?),
        metric: j['metric'] as bool? ?? true,
        showIndoor: j['showIndoor'] as bool? ?? true,
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        resolvedLabel: j['resolvedLabel'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'location': location,
        'corner': cornerToString(corner),
        'metric': metric,
        'showIndoor': showIndoor,
        'latitude': latitude,
        'longitude': longitude,
        'resolvedLabel': resolvedLabel,
      };
}


/// What the full-screen player draws between the scrubber and the transport.
enum VisualiserStyle { off, bars, wave }

String visualiserToString(VisualiserStyle v) => v.name;

String visualiserLabel(VisualiserStyle v) {
  switch (v) {
    case VisualiserStyle.off:
      return 'Off';
    case VisualiserStyle.bars:
      return 'Bars';
    case VisualiserStyle.wave:
      return 'Waveform';
  }
}

/// The next style in the cycle, for tapping the visualiser itself.
VisualiserStyle nextVisualiser(VisualiserStyle v) =>
    VisualiserStyle.values[(v.index + 1) % VisualiserStyle.values.length];

VisualiserStyle _visualiserFromString(String? s) {
  return VisualiserStyle.values.firstWhere(
    (v) => v.name == s,
    orElse: () => VisualiserStyle.bars,
  );
}

/// Now-playing overlay (what the paired phone is playing, via Bluetooth AVRCP).
class NowPlayingSettings {
  bool enabled;
  OverlayCorner corner;

  /// Whether the Pi plays the phone's audio (A2DP sink). Turn this off to keep
  /// audio on the phone — headphones, say — and use this display purely as a
  /// remote control. Metadata and transport keep working either way.
  bool playAudioHere;

  /// The visualiser in the expanded player.
  ///
  /// It draws what is coming out of *this* device's speaker, so it only has
  /// anything to show while [playAudioHere] is on, or while Spotify is playing
  /// through the Pi rather than through some other speaker.
  VisualiserStyle visualiser;

  NowPlayingSettings({
    this.enabled = true,
    this.corner = OverlayCorner.bottomLeft,
    this.playAudioHere = true,
    this.visualiser = VisualiserStyle.bars,
  });

  factory NowPlayingSettings.fromJson(Map<String, dynamic> j) {
    return NowPlayingSettings(
      enabled: j['enabled'] as bool? ?? true,
      corner: _cornerFromString(j['corner'] as String?),
      playAudioHere: j['playAudioHere'] as bool? ?? true,
      visualiser: _visualiserFromString(j['visualiser'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'corner': cornerToString(corner),
        'playAudioHere': playAudioHere,
        'visualiser': visualiserToString(visualiser),
      };
}

/// Where the indoor temperature comes from.
///
/// Home Assistant already watches the Govee sensor over Bluetooth full-time, so
/// the kiosk reads the value from there rather than scanning for itself. That
/// keeps one radio owner instead of two, and Home Assistant's history is better
/// than anything this app kept on its own.
class HomeAssistantSettings {
  /// Whether to read the indoor sensor at all.
  ///
  /// Separate from whether it is *configured*, so the feature can be switched
  /// off without discarding the URL, token and entity ids — a long-lived
  /// token is not something you want to have to re-issue because you turned
  /// a reading off for a week.
  bool enabled;

  /// Base URL, no trailing slash. Home Assistant runs on the same Pi.
  String baseUrl;

  /// Long-lived access token: Home Assistant profile -> Security -> Long-lived
  /// access tokens. Without one the indoor reading is simply not shown.
  String token;

  String temperatureEntity;
  String humidityEntity;
  String batteryEntity;

  HomeAssistantSettings({
    this.enabled = true,
    this.baseUrl = 'http://localhost:8123',
    this.token = '',
    this.temperatureEntity = '',
    this.humidityEntity = '',
    this.batteryEntity = '',
  });

  /// Everything needed to read the sensor, and permission to.
  ///
  /// The service polls on this alone, so switching [enabled] off stops the
  /// timers and clears the reading by the same path as never having set it
  /// up — no second code path to get wrong.
  bool get isConfigured =>
      enabled &&
      baseUrl.isNotEmpty &&
      token.isNotEmpty &&
      temperatureEntity.isNotEmpty;

  /// Set up, but deliberately switched off.
  bool get isPaused =>
      !enabled && baseUrl.isNotEmpty && token.isNotEmpty;

  factory HomeAssistantSettings.fromJson(Map<String, dynamic> j) =>
      HomeAssistantSettings(
        // Absent means on, so an existing config keeps working.
        enabled: j['enabled'] as bool? ?? true,
        baseUrl: (j['baseUrl'] as String? ?? 'http://localhost:8123')
            .replaceAll(RegExp(r'/+$'), ''),
        token: j['token'] as String? ?? '',
        temperatureEntity: j['temperatureEntity'] as String? ?? '',
        humidityEntity: j['humidityEntity'] as String? ?? '',
        batteryEntity: j['batteryEntity'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'baseUrl': baseUrl,
        'token': token,
        'temperatureEntity': temperatureEntity,
        'humidityEntity': humidityEntity,
        'batteryEntity': batteryEntity,
      };
}

/// A Spotify Premium account, controlled directly via the Web API rather
/// than through the phone's AVRCP link.
///
/// Authenticated with OAuth Authorization Code + PKCE, so there's no client
/// secret to store — only the Client ID (free, from a Spotify Developer
/// Dashboard app) and the refresh token obtained from the one-time login in
/// Settings. See [SpotifyService] for the flow itself.
class SpotifySettings {
  String clientId;
  String refreshToken;

  SpotifySettings({
    this.clientId = '',
    this.refreshToken = '',
  });

  bool get isConfigured => clientId.isNotEmpty && refreshToken.isNotEmpty;

  factory SpotifySettings.fromJson(Map<String, dynamic> j) => SpotifySettings(
        clientId: j['clientId'] as String? ?? '',
        refreshToken: j['refreshToken'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'refreshToken': refreshToken,
      };
}

/// A phone running the android-ip-camera app, used as a wireless camera.
///
/// The phone streams hardware-encoded H.264 from `/video/h264` and takes
/// control commands as query strings on any path (`/?zoom=5.0&ts=<millis>`),
/// so zoom happens on the phone's sensor rather than by cropping the picture
/// once it gets here.
class CameraSettings {
  bool enabled;

  /// `host:port` of the phone, e.g. `192.168.1.52:4444`.
  String address;
  String username;
  String password;

  /// Which lens to open on — the id from the phone's `/info.json`.
  String cameraId;

  /// Stream size asked of the phone. The panel is 1920x1200, so 1080p is as
  /// much as is worth sending.
  String streamResolution;

  /// Which corner the small window sits in.
  OverlayCorner corner;

  /// Degrees to turn the picture by on the phone, for when it ends up mounted
  /// on its side or upside down. Applied there rather than here so the whole
  /// frame is still used — but only its MJPEG encoder honours it.
  int rotate;

  /// Quarter turns applied to the picture *here*, as a last resort.
  ///
  /// The phone's streaming app composes for whatever orientation it believes
  /// it is in, and on this device it gets that wrong and stays wrong: the
  /// scene arrives on its side however the phone is held, locked, previewing
  /// or restarted, and its H.264 encoder ignores the rotate control entirely.
  /// Turning the picture here always works, at the cost of the frame no
  /// longer matching the panel's shape.
  int viewQuarterTurns;

  /// Zoom ratio the view opens at, and the most the phone will accept.
  double defaultZoom;
  double maxZoom;

  CameraSettings({
    this.enabled = false,
    this.address = '',
    this.username = '',
    this.password = '',
    this.cameraId = '0',
    this.corner = OverlayCorner.bottomRight,
    this.streamResolution = '1920x1080',
    this.rotate = 0,
    this.viewQuarterTurns = 0,
    this.defaultZoom = 1.0,
    this.maxZoom = 10.0,
  });

  bool get isConfigured => enabled && address.isNotEmpty;

  /// Base URL with credentials inlined — mpv authenticates from the URL.
  String get baseUrl {
    final creds = username.isEmpty
        ? ''
        : '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@';
    return 'http://$creds$address';
  }

  factory CameraSettings.fromJson(Map<String, dynamic> j) => CameraSettings(
        enabled: j['enabled'] as bool? ?? false,
        address: j['address'] as String? ?? '',
        username: j['username'] as String? ?? '',
        password: j['password'] as String? ?? '',
        cameraId: j['cameraId'] as String? ?? '0',
        // Bottom right by default rather than the shared fallback's top
        // right, which the weather panel already has.
        corner: j['corner'] == null
            ? OverlayCorner.bottomRight
            : _cornerFromString(j['corner'] as String?),
        streamResolution: j['streamResolution'] as String? ?? '1920x1080',
        rotate: (j['rotate'] as num?)?.toInt() ?? 0,
        viewQuarterTurns: (j['viewQuarterTurns'] as num?)?.toInt() ?? 0,
        defaultZoom: (j['defaultZoom'] as num?)?.toDouble() ?? 1.0,
        maxZoom: (j['maxZoom'] as num?)?.toDouble() ?? 10.0,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'address': address,
        'username': username,
        'password': password,
        'cameraId': cameraId,
        'corner': cornerToString(corner),
        'streamResolution': streamResolution,
        'rotate': rotate,
        'viewQuarterTurns': viewQuarterTurns,
        'defaultZoom': defaultZoom,
        'maxZoom': maxZoom,
      };
}

/// A Hisense VIDAA television, driven over its MQTT control protocol.
///
/// The defaults are the set this was built against. Only one client may hold
/// a session — the MQTT client id is derived from the UUID — so if you also
/// run the standalone remote app, give one of them a different UUID or they
/// will displace each other.
/// A UniFi console — a Dream Router, Dream Machine or Cloud Key.
class UnifiSettings {
  bool enabled;

  /// The console's address. UniFi OS serves everything over HTTPS on 443,
  /// including the Network application under /proxy/network.
  String host;

  /// An API key from Network → Settings → Control Plane → Integrations.
  ///
  /// Keys inherit the role of the admin that created them, so one made under
  /// a read-only admin can report the network but not restart it — which is
  /// all any of these widgets need.
  String apiKey;

  /// Which site to read. UniFi's own default site is literally called
  /// "default"; the id is discovered on first use and cached here.
  String siteId;

  /// Trust the console's certificate even though it is self-signed.
  ///
  /// A UniFi console on a home LAN presents a certificate for its
  /// `.id.ui.direct` name, not for its address, so a strict check fails
  /// against the very device you are holding. Defaults on because the
  /// alternative is the feature simply not working; turn it off if you have
  /// put a real certificate on the console.
  bool allowSelfSignedCert;

  /// How often to sample WAN throughput, in seconds.
  ///
  /// Its own interval because it is its own request: one small call for the
  /// gateway's statistics, rather than the whole device-and-client sweep. A
  /// second is comfortable; the floor exists because below that the console
  /// returns the same figures twice and it is pure load for no data.
  int throughputPollSeconds;

  /// How long to keep throughput history, in hours.
  ///
  /// Kept as per-minute aggregates rather than raw samples, so a day costs
  /// 1,440 entries instead of 86,400.
  int throughputHours;

  UnifiSettings({
    this.enabled = false,
    this.host = '192.168.1.1',
    this.apiKey = '',
    this.siteId = '',
    this.allowSelfSignedCert = true,
    this.throughputPollSeconds = 1,
    this.throughputHours = 24,
  });

  bool get isConfigured => enabled && host.isNotEmpty && apiKey.isNotEmpty;

  factory UnifiSettings.fromJson(Map<String, dynamic> j) => UnifiSettings(
        enabled: j['enabled'] as bool? ?? false,
        host: (j['host'] as String? ?? '192.168.1.1')
            .replaceAll(RegExp(r'^https?://'), '')
            .replaceAll(RegExp(r'/+$'), ''),
        apiKey: j['apiKey'] as String? ?? '',
        siteId: j['siteId'] as String? ?? '',
        allowSelfSignedCert: j['allowSelfSignedCert'] as bool? ?? true,
        throughputPollSeconds:
            ((j['throughputPollSeconds'] as num?)?.toInt() ?? 1).clamp(1, 60),
        throughputHours:
            ((j['throughputHours'] as num?)?.toInt() ?? 24).clamp(1, 72),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'host': host,
        'apiKey': apiKey,
        'siteId': siteId,
        'allowSelfSignedCert': allowSelfSignedCert,
        'throughputPollSeconds': throughputPollSeconds,
        'throughputHours': throughputHours,
      };
}

class TvSettings {
  bool enabled;

  /// The television's address on the network.
  String host;

  /// Identifies this controller to the set. Pairing is per UUID: change it
  /// and the television will ask for a PIN again.
  String uuid;

  TvSettings({
    this.enabled = false,
    this.host = '192.168.1.156',
    this.uuid = '7a:8d:88:86:27:93',
  });

  bool get isConfigured => enabled && host.isNotEmpty && uuid.isNotEmpty;

  factory TvSettings.fromJson(Map<String, dynamic> j) => TvSettings(
        enabled: j['enabled'] as bool? ?? false,
        host: j['host'] as String? ?? '192.168.1.156',
        uuid: j['uuid'] as String? ?? '7a:8d:88:86:27:93',
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'host': host,
        'uuid': uuid,
      };
}

/// Turning the panel off by itself when there's nothing worth showing.
///
/// The screen is switched via the same host-side `screen_control.py` service
/// Alexa already drives (see the README), so "off" dims the backlight rather
/// than cutting the DSI output — that service watches the touchscreen and
/// brings it back up on a touch. This just decides *when* to ask it to.
class ScreenSettings {
  bool autoOffEnabled;

  /// How long with no slideshow, nothing playing and no touches before the
  /// panel switches itself off.
  int idleMinutes;

  /// Bring the screen back up by itself when music starts.
  bool wakeOnMusic;

  ScreenSettings({
    this.autoOffEnabled = false,
    this.idleMinutes = 15,
    this.wakeOnMusic = true,
  });

  factory ScreenSettings.fromJson(Map<String, dynamic> j) => ScreenSettings(
        autoOffEnabled: j['autoOffEnabled'] as bool? ?? false,
        idleMinutes: (j['idleMinutes'] as num?)?.toInt() ?? 15,
        wakeOnMusic: j['wakeOnMusic'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'autoOffEnabled': autoOffEnabled,
        'idleMinutes': idleMinutes,
        'wakeOnMusic': wakeOnMusic,
      };
}

/// A person allowed to share content to the kiosk from the companion app —
/// [name] is shown as attribution on incoming shares ("From: Mum's phone"),
/// [token] is the bearer credential their app was set up with.
class SenderToken {
  String name;
  String token;

  SenderToken({required this.name, required this.token});

  factory SenderToken.fromJson(Map<String, dynamic> j) => SenderToken(
        name: j['name'] as String? ?? '',
        token: j['token'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'name': name, 'token': token};
}

/// Lets people with the companion app share a photo, GIF, video, web link or
/// text to the kiosk from anywhere (Android's share sheet). The kiosk itself
/// listens for these — no separate relay — see [ShareInboxService].
class ShareInboxSettings {
  /// Port the kiosk's own HTTP listener binds to. Whatever's in front of it
  /// on the network (a reverse proxy, port forwarding) is the user's own
  /// concern — this app only needs to know which local port to bind.
  int listenPort;

  /// Mute the incoming-share chime. Also toggleable from the home screen's
  /// top bar, since it's meant to be reached quickly.
  bool dndMuted;

  /// The chime plays through its own player instance, separate from
  /// whatever's playing music/video, so this is independent of that
  /// volume — turning music down (or up) doesn't touch this. 0-100.
  double notificationVolume;

  /// Read incoming text notes aloud.
  bool speakNotes;

  /// Say who sent it before reading the note.
  bool speakSender;

  /// How loud speech is, 0–100.
  ///
  /// Deliberately below the chime's default. A voice at the level of music
  /// is startling in a quiet room — it is speech arriving unannounced, not
  /// something you chose to play.
  double speechVolume;

  List<SenderToken> senderTokens;

  /// Refuse anything that arrives unencrypted.
  ///
  /// Off by default because turning it on stops older copies of the phone app
  /// working — every sender has to be updated first. On, it is what makes the
  /// guarantee real: otherwise anyone able to reach the port can simply omit
  /// the encryption and be accepted.
  bool requireEncryption;

  ShareInboxSettings({
    this.listenPort = 8081,
    this.dndMuted = false,
    this.notificationVolume = 80,
    this.speakNotes = false,
    this.speakSender = true,
    this.speechVolume = 45,
    this.requireEncryption = false,
    List<SenderToken>? senderTokens,
  }) : senderTokens = senderTokens ?? [];

  factory ShareInboxSettings.fromJson(Map<String, dynamic> j) {
    return ShareInboxSettings(
      listenPort: (j['listenPort'] as num?)?.toInt() ?? 8081,
      requireEncryption: j['requireEncryption'] as bool? ?? false,
      dndMuted: j['dndMuted'] as bool? ?? false,
      notificationVolume: (j['notificationVolume'] as num?)?.toDouble() ?? 80,
      speakNotes: j['speakNotes'] as bool? ?? false,
      speakSender: j['speakSender'] as bool? ?? true,
      speechVolume:
          ((j['speechVolume'] as num?)?.toDouble() ?? 45).clamp(0, 100),
      senderTokens: (j['senderTokens'] as List?)
              ?.map((t) => SenderToken.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'listenPort': listenPort,
        'requireEncryption': requireEncryption,
        'dndMuted': dndMuted,
        'notificationVolume': notificationVolume,
        'speakNotes': speakNotes,
        'speakSender': speakSender,
        'speechVolume': speechVolume,
        'senderTokens': senderTokens.map((t) => t.toJson()).toList(),
      };
}

class AppConfig {
  String immichUrl;
  String apiKey;
  // Login credentials for the server-side Locked Folder (session auth).
  String immichEmail;
  String immichPassword;
  SlideshowSettings slideshow;
  WeatherSettings weather;
  NowPlayingSettings nowPlaying;
  HomeAssistantSettings homeAssistant;
  SpotifySettings spotify;
  ShareInboxSettings shareInbox;
  ScreenSettings screen;
  CameraSettings camera;
  DashboardSettings dashboard;
  TvSettings tv;
  UnifiSettings unifi;

  /// Video player volume (0-100) and mute, remembered between videos.
  double videoVolume;
  bool videoMuted;

  AppConfig({
    this.immichUrl = '',
    this.apiKey = '',
    this.immichEmail = '',
    this.immichPassword = '',
    SlideshowSettings? slideshow,
    WeatherSettings? weather,
    NowPlayingSettings? nowPlaying,
    HomeAssistantSettings? homeAssistant,
    SpotifySettings? spotify,
    ShareInboxSettings? shareInbox,
    ScreenSettings? screen,
    CameraSettings? camera,
    DashboardSettings? dashboard,
    TvSettings? tv,
    UnifiSettings? unifi,
    this.videoVolume = 100,
    this.videoMuted = false,
  })  : slideshow = slideshow ?? SlideshowSettings(),
        weather = weather ?? WeatherSettings(),
        nowPlaying = nowPlaying ?? NowPlayingSettings(),
        homeAssistant = homeAssistant ?? HomeAssistantSettings(),
        spotify = spotify ?? SpotifySettings(),
        shareInbox = shareInbox ?? ShareInboxSettings(),
        screen = screen ?? ScreenSettings(),
        camera = camera ?? CameraSettings(),
        dashboard = dashboard ?? DashboardSettings(),
        tv = tv ?? TvSettings(),
        unifi = unifi ?? UnifiSettings();

  bool get isConfigured => immichUrl.isNotEmpty && apiKey.isNotEmpty;

  OverlayCorner cornerOf(OverlaySlot slot) {
    switch (slot) {
      case OverlaySlot.weather:
        return weather.corner;
      case OverlaySlot.nowPlaying:
        return nowPlaying.corner;
      case OverlaySlot.camera:
        return camera.corner;
    }
  }

  void _setCorner(OverlaySlot slot, OverlayCorner corner) {
    switch (slot) {
      case OverlaySlot.weather:
        weather.corner = corner;
      case OverlaySlot.nowPlaying:
        nowPlaying.corner = corner;
      case OverlaySlot.camera:
        camera.corner = corner;
    }
  }

  /// Move [slot] to [corner], displacing whatever was already there into the
  /// corner [slot] is leaving.
  ///
  /// Three panels and four corners, so every request can be honoured — which
  /// is why this swaps rather than refusing. Two panels can therefore never
  /// end up stacked on top of each other, without the settings screen having
  /// to validate anything or grey options out.
  void assignCorner(OverlaySlot slot, OverlayCorner corner) {
    final vacated = cornerOf(slot);
    if (vacated == corner) return;
    for (final other in OverlaySlot.values) {
      if (other != slot && cornerOf(other) == corner) {
        _setCorner(other, vacated);
      }
    }
    _setCorner(slot, corner);
  }

  /// Settled configurations written before the camera had a corner of its own
  /// can arrive with two panels in the same place. Move the later one to
  /// whichever corner is still free.
  void _separateCorners() {
    final taken = <OverlayCorner>{};
    for (final slot in OverlaySlot.values) {
      final corner = cornerOf(slot);
      if (taken.add(corner)) continue;
      final free = OverlayCorner.values.firstWhere((c) => !taken.contains(c));
      _setCorner(slot, free);
      taken.add(free);
    }
  }

  factory AppConfig.fromJson(Map<String, dynamic> j) {
    return _fromJson(j).._separateCorners();
  }

  static AppConfig _fromJson(Map<String, dynamic> j) {
    return AppConfig(
      immichUrl: (j['immichUrl'] as String? ?? '').replaceAll(RegExp(r'/+$'), ''),
      apiKey: j['apiKey'] as String? ?? '',
      immichEmail: j['immichEmail'] as String? ?? '',
      immichPassword: j['immichPassword'] as String? ?? '',
      slideshow: j['slideshow'] is Map<String, dynamic>
          ? SlideshowSettings.fromJson(j['slideshow'] as Map<String, dynamic>)
          : SlideshowSettings(),
      weather: j['weather'] is Map<String, dynamic>
          ? WeatherSettings.fromJson(j['weather'] as Map<String, dynamic>)
          : WeatherSettings(),
      nowPlaying: j['nowPlaying'] is Map<String, dynamic>
          ? NowPlayingSettings.fromJson(j['nowPlaying'] as Map<String, dynamic>)
          : NowPlayingSettings(),
      homeAssistant: j['homeAssistant'] is Map<String, dynamic>
          ? HomeAssistantSettings.fromJson(
              j['homeAssistant'] as Map<String, dynamic>)
          : HomeAssistantSettings(),
      spotify: j['spotify'] is Map<String, dynamic>
          ? SpotifySettings.fromJson(j['spotify'] as Map<String, dynamic>)
          : SpotifySettings(),
      shareInbox: j['shareInbox'] is Map<String, dynamic>
          ? ShareInboxSettings.fromJson(j['shareInbox'] as Map<String, dynamic>)
          : ShareInboxSettings(),
      screen: j['screen'] is Map<String, dynamic>
          ? ScreenSettings.fromJson(j['screen'] as Map<String, dynamic>)
          : ScreenSettings(),
      camera: j['camera'] is Map<String, dynamic>
          ? CameraSettings.fromJson(j['camera'] as Map<String, dynamic>)
          : CameraSettings(),
      dashboard: j['dashboard'] is Map<String, dynamic>
          ? DashboardSettings.fromJson(j['dashboard'] as Map<String, dynamic>)
          : DashboardSettings(),
      tv: j['tv'] is Map<String, dynamic>
          ? TvSettings.fromJson(j['tv'] as Map<String, dynamic>)
          : TvSettings(),
      unifi: j['unifi'] is Map<String, dynamic>
          ? UnifiSettings.fromJson(j['unifi'] as Map<String, dynamic>)
          : UnifiSettings(),
      videoVolume: (j['videoVolume'] as num?)?.toDouble() ?? 100,
      videoMuted: j['videoMuted'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'immichUrl': immichUrl,
        'apiKey': apiKey,
        'immichEmail': immichEmail,
        'immichPassword': immichPassword,
        'slideshow': slideshow.toJson(),
        'weather': weather.toJson(),
        'nowPlaying': nowPlaying.toJson(),
        'homeAssistant': homeAssistant.toJson(),
        'spotify': spotify.toJson(),
        'shareInbox': shareInbox.toJson(),
        'screen': screen.toJson(),
        'camera': camera.toJson(),
        'dashboard': dashboard.toJson(),
        'tv': tv.toJson(),
        'unifi': unifi.toJson(),
        'videoVolume': videoVolume,
        'videoMuted': videoMuted,
      };
}
