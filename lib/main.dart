import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'models/immich_models.dart';
import 'dashboard/live_preview.dart';
import 'dashboard/photo_backdrop.dart';
import 'dashboard/tile_renderer.dart';
import 'services/air_quality_service.dart';
import 'services/brightness_service.dart';
import 'services/bins_service.dart';
import 'services/carbon_service.dart';
import 'services/chores_service.dart';
import 'services/govee_service.dart';
import 'services/home_assistant_service.dart';
import 'services/rain_service.dart';
import 'services/notes_service.dart';
import 'services/shopping_service.dart';
import 'services/timer_service.dart';
import 'services/timer_sounds.dart';
import 'dashboard/widgets/widgets.dart';
import 'services/audio_levels_service.dart';
import 'services/kiosk_control_service.dart';
import 'services/camera_service.dart';
import 'services/article_reader.dart';
import 'services/config_service.dart';
import 'services/playback_source.dart';
import 'services/dashboard_service.dart';
import 'services/feed_service.dart';
import 'services/immich_service.dart';
import 'services/indoor_sensor_service.dart';
import 'services/locked_folder_service.dart';
import 'services/media_cache.dart';
import 'services/now_playing_service.dart';
import 'services/screen_idle_service.dart';
import 'services/share_inbox_service.dart';
import 'services/spotify_service.dart';
import 'services/lan_speedtest_service.dart';
import 'services/speedtest_service.dart';
import 'services/tts_service.dart';
import 'services/tv_service.dart';
import 'services/unifi_service.dart';
import 'services/weather_service.dart';
import 'widgets/module_bar.dart' show openLockedFolder;
import 'screens/about_screen.dart';
import 'screens/album_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/gallery_screen.dart';
import 'screens/home_screen.dart';
import 'screens/locked_folder_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/slideshow_screen.dart';
import 'screens/video_player_screen.dart';
import 'widgets/camera_overlay.dart';
import 'widgets/incoming_share_overlay.dart';
import 'widgets/reading_bar.dart';
import 'widgets/now_playing_overlay.dart';
import 'app_paths.dart';
import 'theme.dart';
import 'dashboard/dashboard_theme.dart';
import 'look.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Before anything reads its settings: the project was ImmichKioskPi, and
  // its folders move to their new names on the first start after that.
  await AppPaths.migrate();
  // Big in-memory image budget — the Pi has 8 GB and revisited photos should
  // redisplay with no decode cost.
  HomeCanvasCache.configureImageCache();

  final config = ConfigService();
  await config.load();

  final weather = WeatherService(config);
  unawaited(weather.refresh());

  // Indoor temperature, read from Home Assistant rather than scanned for.
  final indoor = IndoorSensorService();
  unawaited(indoor.start(config.config.homeAssistant));

  // Reads what the paired phone is playing over Bluetooth AVRCP.
  final nowPlaying = NowPlayingService()
    ..preferAudioRouted = config.config.nowPlaying.playAudioHere;
  unawaited(nowPlaying.start());

  // Full playback control for a Spotify Premium account via the Web API,
  // shown in preference to the AVRCP source above whenever it has something
  // to show. A no-op until the one-time login is done in Settings.
  final spotify = SpotifyService(config);
  unawaited(spotify.start());

  // Lets the companion phone app share a photo/GIF/video/link/note to the
  // kiosk directly — no separate relay, just a small HTTP listener here.
  // Reads shared notes aloud. Built here and handed over rather than owned by
  // the inbox, so speech being unavailable is not the inbox's problem.
  final speech = TtsService();

  final shareInbox = ShareInboxService(config)..speech = speech;
  unawaited(shareInbox.start());

  // Reads a news article aloud, pausing whatever is playing while it does
  // and carrying it on afterwards — only if it was playing to begin with.
  PlaybackSource? pausedForReading;
  final reader = ArticleReader(
    output: PiperSpeechOutput(speech),
    voiceFor: speech.voiceFor,
    voiceId: speech.voiceId,
    volume: () => config.config.shareInbox.speechVolume,
    onStart: () {
      for (final PlaybackSource p in [spotify, nowPlaying]) {
        if (p.available && p.now.isPlaying) {
          pausedForReading = p;
          unawaited(p.playPause());
          return;
        }
      }
    },
    onEnd: () {
      final p = pausedForReading;
      pausedForReading = null;
      if (p != null && p.available && !p.now.isPlaying) {
        unawaited(p.playPause());
      }
    },
  );

  // Widget types have to be registered before anything reads the dashboard:
  // the editor's palette and each widget's settings form are both generated
  // from the registry.
  registerBuiltInWidgets();

  // Feeds for the dashboard's calendar and news widgets, shared by URL so two
  // widgets on the same feed cost one fetch.
  final feeds = FeedService()..start();

  // One instance, shared with the provider below rather than created twice:
  // it holds the album and asset caches, and a second copy would warm its own
  // from scratch.
  final immich = ImmichService(config);

  // Reads the UniFi console for the network widgets. One service, one poll,
  // five widgets — none of them should cost their own round trip.
  final unifi = UnifiService(config);
  unawaited(unifi.start());

  final dashboard = DashboardService(
    config,
    // Resolved on each request so the editor's preview reflects the moment
    // it was asked for.
    previewData: () => PreviewData(
      weather: weather,
      feeds: feeds,
      playback: spotify.available ? spotify : nowPlaying,
    ),
    // For the Immich widget's album picker. Cached by the service it calls,
    // so opening the editor does not hammer the server.
    albums: () async => {
      for (final a in await immich.getAlbums()) a.id: a.name,
    },
  );
  unawaited(dashboard.start());

  // Switches the panel off by itself when nothing's playing and no
  // slideshow is running — see ScreenIdleService for why the switching
  // itself is left to the host-side screen_control.py service.
  final screenIdle = ScreenIdleService(config, [spotify, nowPlaying])..start();

  // The backlight as it was left in Settings or the editor, rather than
  // whatever systemd restored — which after a shutdown while asleep is 1.
  final brightness = BrightnessService(config);
  unawaited(brightness.start());
  dashboard.brightness = brightness;

  // A share arriving is worth waking the panel for — unless Do Not Disturb is
  // on, which the screen service checks for itself.
  shareInbox.onItemArrived = screenIdle.wakeForNotification;

  // The household notes board. Text shared from the phone app goes on it as
  // well as popping up; the editor server has a page for posting to it.
  final notes = NotesService();
  unawaited(notes.load());
  shareInbox.onShared = (item) {
    if (item.type == ShareType.text && (item.content ?? '').trim().isNotEmpty) {
      notes.add(item.content!, from: item.sender);
    }
  };
  dashboard.notes = notes;

  // The shopping list, added to from phones and ticked off on the panel.
  final shopping = ShoppingService();
  unawaited(shopping.load());
  dashboard.shopping = shopping;

  // Chores ticked off, and the week's stars, kept across restarts.
  final chores = ChoresService();
  unawaited(chores.load());

  // Kitchen timers, owned up here so they keep running — and still speak —
  // after the panel has left the dashboard. The sound and the voice both
  // play at the speech volume, the one articles are read at: below the
  // music, and turned up or down with it from Settings or the editor.
  final timerSounds = TimerSounds();
  final timers = TimerService(
    speak: (text) => speech.speak(
      text,
      volume: config.config.shareInbox.speechVolume,
    ),
    play: (sound) => timerSounds.play(
      sound,
      volume: config.config.shareInbox.speechVolume,
    ),
    silence: timerSounds.stop,
    onFinished: screenIdle.wakeForNotification,
  );
  dashboard.timerSounds = timerSounds;

  // Bin-day reminders, spoken the evening before whether or not the
  // dashboard is showing.
  final bins = BinsService(config, speak: speech.speak)..start();

  // Home Assistant entities for the dashboard, over the connection set up
  // for the indoor sensor. Idle until a widget asks; the editor's entity
  // picker asks it for the list.
  // For the editor's preview of the photo background: the photo showing
  // now, or any photo if the dashboard is not up.
  dashboard.backgroundImage = () async {
    final id = PhotoBackdrop.current ??
        (await immich.getRandomAssets(count: 1)).firstOrNull?.id;
    return id == null ? null : immich.previewBytes(id);
  };

  final homeAssistant = HomeAssistantService(config);
  dashboard.haEntities = homeAssistant.choices;
  dashboard.voices = speech.voiceChoices;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: config),
        Provider<ImmichService>.value(value: immich),
        ChangeNotifierProvider.value(value: unifi),
        ChangeNotifierProvider(create: (_) => LockedFolderService(config)),
        ChangeNotifierProvider.value(value: weather),
        ChangeNotifierProvider.value(value: nowPlaying),
        ChangeNotifierProvider.value(value: spotify),
        ChangeNotifierProvider.value(value: indoor),
        ChangeNotifierProvider.value(value: shareInbox),
        ChangeNotifierProvider.value(value: reader),
        Provider<ScreenIdleService>.value(value: screenIdle),
        ChangeNotifierProvider.value(value: brightness),
        ChangeNotifierProvider(create: (_) => CameraService(config)),
        ChangeNotifierProvider.value(value: feeds),
        ChangeNotifierProvider.value(value: dashboard),
        ChangeNotifierProvider(create: (_) => TvService(config)),
        // Owned above the dashboard so a test keeps running while you
        // page away from the widget, and the result is still there when
        // you come back.
        ChangeNotifierProvider(create: (_) => SpeedtestService()),
        ChangeNotifierProvider(create: (_) => LanSpeedtestService()),
        // Idle until the visualiser asks it for something: creating it costs
        // nothing, and it starts no capture until a widget attaches.
        ChangeNotifierProvider(create: (_) => AudioLevelsService()),
        ChangeNotifierProvider.value(value: notes),
        ChangeNotifierProvider.value(value: shopping),
        ChangeNotifierProvider.value(value: chores),
        ChangeNotifierProvider.value(value: timers),
        ChangeNotifierProvider.value(value: bins),
        // Made when an Air & pollen widget first asks, and not before.
        ChangeNotifierProvider(create: (_) => AirQualityService(config)),
        ChangeNotifierProvider(create: (_) => CarbonService(config)),
        ChangeNotifierProvider(create: (_) => RainService(config)),
        ChangeNotifierProvider.value(value: homeAssistant),
        // Made when a Lights widget first asks; it then listens for Govee
        // devices on the home network.
        ChangeNotifierProvider(create: (_) => GoveeService()),
      ],
      child: const HomeCanvasApp(),
    ),
  );

  // Lets the TV remote app's copy of the control bar reach in here: open
  // the dashboard, Settings, the Locked Folder and so on. Local only — see
  // KioskControlService.
  unawaited(KioskControlService(
    state: () {
      final context = rootNavigatorKey.currentContext;
      final camera = context?.read<CameraService>();
      return KioskState(
        dashboard: config.config.dashboard.enabled,
        lockedFolder: context?.read<LockedFolderService>().canUse ?? false,
        camera: camera?.isConfigured ?? false,
        cameraOpen: camera?.isOpen ?? false,
        dnd: config.config.shareInbox.dndMuted,
      );
    },
    run: (command) => runKioskCommand(command, config),
    setDnd: (muted) {
      config.config.shareInbox.dndMuted = muted;
      unawaited(config.save());
    },
  ).start());
}

/// Carries out a command from [KioskControlService], the way the kiosk's own
/// control bar would.
void runKioskCommand(KioskCommand command, ConfigService config) {
  final navigator = rootNavigatorKey.currentState;
  final context = rootNavigatorKey.currentContext;
  if (navigator == null || context == null) return;
  switch (command) {
    case KioskCommand.photos:
      navigator.popUntil((route) => route.isFirst);
    case KioskCommand.dashboard:
      if (!config.config.dashboard.enabled) return;
      navigator.popUntil((route) => route.isFirst);
      navigator
          .push(MaterialPageRoute(builder: (_) => const DashboardScreen()));
    case KioskCommand.settings:
      navigator.push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    case KioskCommand.lockedFolder:
      if (context.read<LockedFolderService>().canUse) {
        unawaited(openLockedFolder(context));
      }
    case KioskCommand.camera:
      final camera = context.read<CameraService>();
      if (camera.isConfigured) camera.toggleOpen();
  }
}

/// The overlay added in [HomeCanvasApp]'s `builder` sits as a *sibling* of
/// this Navigator (both are children of the same Stack), not a descendant of
/// it, so `Navigator.of(context)` from inside the overlay can't find it by
/// walking up the tree. A global key to the same Navigator sidesteps that.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class HomeCanvasApp extends StatelessWidget {
  const HomeCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The theme chosen for the dashboard dresses the whole kiosk.
    // HOMECANVAS_TEST_THEME=<id> shows another without saving it, for
    // screenshots.
    final themeId =
        Platform.environment['HOMECANVAS_TEST_THEME'] ??
        context.select<ConfigService, String>(
          (c) => c.config.dashboard.themeId,
        );
    final look = context.select<DashboardService, DashboardTheme>(
      (d) => d.themes.byId(themeId),
    );
    return KioskLook(
      theme: look,
      child: _app(context, look),
    );
  }

  Widget _app(BuildContext context, DashboardTheme look) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'HomeCanvas',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(look),
      // The DSI touchscreen is delivered as mouse/unknown pointer events on
      // Flutter's Linux embedder, so enable drag-scrolling for every pointer
      // kind (otherwise touch drag doesn't scroll lists/grids).
      scrollBehavior: const _AppScrollBehavior(),
      // Stacked above the routed content itself (rather than added to each
      // screen individually) so a shared-content notification can pop up
      // over *any* screen — settings, a slideshow, a video — not just the
      // couple of screens the now-playing overlay lives in.
      builder: (context, child) => Listener(
        // Any touch counts as "someone's here", which is what stops the
        // idle timer switching the panel off mid-use. Listener sees the
        // event on the way down without consuming it, so nothing below
        // behaves any differently.
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => context.read<ScreenIdleService>().noteInteraction(),
        child: Stack(
          children: [
            ?child,
            IncomingShareOverlay(navigatorKey: rootNavigatorKey),
            // What is being read aloud, with its controls, over any screen.
            const ReadingBar(),
            CameraOverlay(navigatorKey: rootNavigatorKey),
            // Draws tiles off screen for the dashboard editor's preview.
            const TileRenderHost(),
          ],
        ),
      ),
      home: const _RootGate(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}

/// Shows setup until a connection is configured, then the album browser.
class _RootGate extends StatelessWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context) {
    // Dev aids for headless verification (only active when the env var is set):
    //   HOMECANVAS_TEST_VIDEO=<assetId>       boot into the video player
    //   HOMECANVAS_TEST_SLIDESHOW=<albumId>   boot into the slideshow
    //   HOMECANVAS_TEST_GALLERY=<albumId>     boot into the photo gallery
    //   HOMECANVAS_TEST_WEATHER=expanded      open the weather detail card
    //   HOMECANVAS_TEST_DASHBOARD=<page>      open the dashboard at a page
    final immich = context.read<ImmichService>();
    final testVideo = Platform.environment['HOMECANVAS_TEST_VIDEO'];
    if (testVideo != null && testVideo.isNotEmpty) {
      return VideoPlayerScreen(
        asset: Asset(id: testVideo, type: AssetType.video),
        source: immich,
      );
    }
    final testSlideshow = Platform.environment['HOMECANVAS_TEST_SLIDESHOW'];
    if (testSlideshow != null && testSlideshow.isNotEmpty) {
      return _DebugAlbumLoader(
        albumId: testSlideshow,
        immich: immich,
        builder: (imgs) => SlideshowScreen(
          images: imgs,
          source: immich,
          settings: context.read<ConfigService>().slideshow,
        ),
      );
    }
    final testGallery = Platform.environment['HOMECANVAS_TEST_GALLERY'];
    if (testGallery != null && testGallery.isNotEmpty) {
      return _DebugAlbumLoader(
        albumId: testGallery,
        immich: immich,
        builder: (imgs) => GalleryScreen(
          assets: imgs,
          initialIndex: int.tryParse(
                  Platform.environment['HOMECANVAS_TEST_GALLERY_INDEX'] ?? '') ??
              0,
          source: immich,
        ),
      );
    }

    final testAlbumGrid = Platform.environment['HOMECANVAS_TEST_ALBUMGRID'];
    if (testAlbumGrid != null && testAlbumGrid.isNotEmpty) {
      return AlbumScreen(
        album: Album(
          id: testAlbumGrid,
          name: Platform.environment['HOMECANVAS_TEST_ALBUMNAME'] ?? 'Album',
          assetCount: 0,
        ),
      );
    }
    if ((Platform.environment['HOMECANVAS_TEST_ABOUT'] ?? '').isNotEmpty) {
      return const AboutScreen();
    }
    if ((Platform.environment['HOMECANVAS_TEST_SETTINGS'] ?? '').isNotEmpty) {
      return const SettingsScreen();
    }
    final testDashboard = Platform.environment['HOMECANVAS_TEST_DASHBOARD'];
    if (testDashboard != null && testDashboard.isNotEmpty) {
      return DashboardScreen(initialPage: int.tryParse(testDashboard) ?? 0);
    }
    if ((Platform.environment['HOMECANVAS_TEST_NOWPLAYING'] ?? '').isNotEmpty) {
      return const Scaffold(
        backgroundColor: Color(0xFF101828),
        body: Stack(children: [NowPlayingOverlay()]),
      );
    }
    final testLocked = Platform.environment['HOMECANVAS_TEST_LOCKED'];
    if (testLocked != null && testLocked.isNotEmpty) {
      return _DebugLockedLoader(pin: testLocked);
    }
    final testLockedVideo = Platform.environment['HOMECANVAS_TEST_LOCKED_VIDEO'];
    if (testLockedVideo != null && testLockedVideo.isNotEmpty) {
      return _DebugLockedVideoLoader(pin: testLockedVideo);
    }

    final configured = context.watch<ConfigService>().isConfigured;
    return configured ? const HomeScreen() : const SetupScreen();
  }
}

/// Dev-only: unlock the Locked Folder with a PIN from the environment and show
/// it, to verify the Bearer-auth media path headlessly.
class _DebugLockedLoader extends StatefulWidget {
  final String pin;
  const _DebugLockedLoader({required this.pin});

  @override
  State<_DebugLockedLoader> createState() => _DebugLockedLoaderState();
}

class _DebugLockedLoaderState extends State<_DebugLockedLoader> {
  late final Future<UnlockResult> _future =
      context.read<LockedFolderService>().unlock(widget.pin);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UnlockResult>(
      future: _future,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.data == UnlockResult.success) {
          return const LockedFolderScreen();
        }
        return Scaffold(body: Center(child: Text('unlock: ${snap.data}')));
      },
    );
  }
}

/// Dev-only: unlock + play the first locked video via media_kit, to reproduce
/// the in-app Locked Folder video path headlessly.
class _DebugLockedVideoLoader extends StatefulWidget {
  final String pin;
  const _DebugLockedVideoLoader({required this.pin});

  @override
  State<_DebugLockedVideoLoader> createState() =>
      _DebugLockedVideoLoaderState();
}

class _DebugLockedVideoLoaderState extends State<_DebugLockedVideoLoader> {
  late final LockedFolderService _locked = context.read<LockedFolderService>();
  Asset? _video;
  String _status = 'unlocking…';

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final r = await _locked.unlock(widget.pin);
    if (r != UnlockResult.success) {
      setState(() => _status = 'unlock failed: $r');
      return;
    }
    final assets = await _locked.getLockedAssets();
    final v = assets.where((a) => a.isVideo).cast<Asset?>().firstWhere(
          (a) => true,
          orElse: () => null,
        );
    if (v == null) {
      setState(() => _status = 'no locked video found');
      return;
    }
    setState(() => _video = v);
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    if (v == null) {
      return Scaffold(body: Center(child: Text(_status)));
    }
    return VideoPlayerScreen(
      asset: v,
      source: _locked.mediaSource!,
      onBeforePlay: _locked.ensureElevated,
    );
  }
}

/// Dev-only: fetch an album's image assets, then hand them to [builder].
class _DebugAlbumLoader extends StatelessWidget {
  final String albumId;
  final ImmichService immich;
  final Widget Function(List<Asset> images) builder;
  const _DebugAlbumLoader({
    required this.albumId,
    required this.immich,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Asset>>(
      future: immich.getAlbumAssets(albumId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final imgs = snap.data!.where((a) => a.isImage).toList();
        return builder(imgs);
      },
    );
  }
}
