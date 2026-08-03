/// Persistent app configuration (connection, slideshow, weather overlay).

enum SlideshowTransition { fade, slide, kenBurns }

SlideshowTransition _transitionFromString(String? s) {
  switch (s) {
    case 'slide':
      return SlideshowTransition.slide;
    case 'kenBurns':
      return SlideshowTransition.kenBurns;
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


/// Now-playing overlay (what the paired phone is playing, via Bluetooth AVRCP).
class NowPlayingSettings {
  bool enabled;
  OverlayCorner corner;

  /// Whether the Pi plays the phone's audio (A2DP sink). Turn this off to keep
  /// audio on the phone — headphones, say — and use this display purely as a
  /// remote control. Metadata and transport keep working either way.
  bool playAudioHere;

  NowPlayingSettings({
    this.enabled = true,
    this.corner = OverlayCorner.bottomLeft,
    this.playAudioHere = true,
  });

  factory NowPlayingSettings.fromJson(Map<String, dynamic> j) {
    return NowPlayingSettings(
      enabled: j['enabled'] as bool? ?? true,
      corner: _cornerFromString(j['corner'] as String?),
      playAudioHere: j['playAudioHere'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'corner': cornerToString(corner),
        'playAudioHere': playAudioHere,
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
    this.videoVolume = 100,
    this.videoMuted = false,
  })  : slideshow = slideshow ?? SlideshowSettings(),
        weather = weather ?? WeatherSettings(),
        nowPlaying = nowPlaying ?? NowPlayingSettings();

  bool get isConfigured => immichUrl.isNotEmpty && apiKey.isNotEmpty;

  factory AppConfig.fromJson(Map<String, dynamic> j) {
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
        'videoVolume': videoVolume,
        'videoMuted': videoMuted,
      };
}
