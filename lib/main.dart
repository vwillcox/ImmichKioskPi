import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'models/immich_models.dart';
import 'dashboard/live_preview.dart';
import 'dashboard/widgets/widgets.dart';
import 'services/camera_service.dart';
import 'services/config_service.dart';
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
import 'services/speedtest_service.dart';
import 'services/tv_service.dart';
import 'services/weather_service.dart';
import 'screens/about_screen.dart';
import 'screens/album_screen.dart';
import 'screens/gallery_screen.dart';
import 'screens/home_screen.dart';
import 'screens/locked_folder_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/slideshow_screen.dart';
import 'screens/video_player_screen.dart';
import 'widgets/camera_overlay.dart';
import 'widgets/incoming_share_overlay.dart';
import 'widgets/now_playing_overlay.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Big in-memory image budget — the Pi has 8 GB and revisited photos should
  // redisplay with no decode cost.
  ImmichKioskPiCache.configureImageCache();

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
  final shareInbox = ShareInboxService(config);
  unawaited(shareInbox.start());

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

  // A share arriving is worth waking the panel for — unless Do Not Disturb is
  // on, which the screen service checks for itself.
  shareInbox.onItemArrived = screenIdle.wakeForNotification;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: config),
        Provider<ImmichService>.value(value: immich),
        ChangeNotifierProvider(create: (_) => LockedFolderService(config)),
        ChangeNotifierProvider.value(value: weather),
        ChangeNotifierProvider.value(value: nowPlaying),
        ChangeNotifierProvider.value(value: spotify),
        ChangeNotifierProvider.value(value: indoor),
        ChangeNotifierProvider.value(value: shareInbox),
        Provider<ScreenIdleService>.value(value: screenIdle),
        ChangeNotifierProvider(create: (_) => CameraService(config)),
        ChangeNotifierProvider.value(value: feeds),
        ChangeNotifierProvider.value(value: dashboard),
        ChangeNotifierProvider(create: (_) => TvService(config)),
        // Owned above the dashboard so a test keeps running while you
        // page away from the widget, and the result is still there when
        // you come back.
        ChangeNotifierProvider(create: (_) => SpeedtestService()),
      ],
      child: const ImmichKioskPiApp(),
    ),
  );
}

/// The overlay added in [ImmichKioskPiApp]'s `builder` sits as a *sibling* of
/// this Navigator (both are children of the same Stack), not a descendant of
/// it, so `Navigator.of(context)` from inside the overlay can't find it by
/// walking up the tree. A global key to the same Navigator sidesteps that.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class ImmichKioskPiApp extends StatelessWidget {
  const ImmichKioskPiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'ImmichKioskPi',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
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
            CameraOverlay(navigatorKey: rootNavigatorKey),
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
    //   IMMICH_KIOSK_TEST_VIDEO=<assetId>       boot into the video player
    //   IMMICH_KIOSK_TEST_SLIDESHOW=<albumId>   boot into the slideshow
    //   IMMICH_KIOSK_TEST_GALLERY=<albumId>     boot into the photo gallery
    //   IMMICH_KIOSK_TEST_WEATHER=expanded      open the weather detail card
    final immich = context.read<ImmichService>();
    final testVideo = Platform.environment['IMMICH_KIOSK_TEST_VIDEO'];
    if (testVideo != null && testVideo.isNotEmpty) {
      return VideoPlayerScreen(
        asset: Asset(id: testVideo, type: AssetType.video),
        source: immich,
      );
    }
    final testSlideshow = Platform.environment['IMMICH_KIOSK_TEST_SLIDESHOW'];
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
    final testGallery = Platform.environment['IMMICH_KIOSK_TEST_GALLERY'];
    if (testGallery != null && testGallery.isNotEmpty) {
      return _DebugAlbumLoader(
        albumId: testGallery,
        immich: immich,
        builder: (imgs) => GalleryScreen(
          assets: imgs,
          initialIndex: int.tryParse(
                  Platform.environment['IMMICH_KIOSK_TEST_GALLERY_INDEX'] ?? '') ??
              0,
          source: immich,
        ),
      );
    }

    final testAlbumGrid = Platform.environment['IMMICH_KIOSK_TEST_ALBUMGRID'];
    if (testAlbumGrid != null && testAlbumGrid.isNotEmpty) {
      return AlbumScreen(
        album: Album(
          id: testAlbumGrid,
          name: Platform.environment['IMMICH_KIOSK_TEST_ALBUMNAME'] ?? 'Album',
          assetCount: 0,
        ),
      );
    }
    if ((Platform.environment['IMMICH_KIOSK_TEST_ABOUT'] ?? '').isNotEmpty) {
      return const AboutScreen();
    }
    if ((Platform.environment['IMMICH_KIOSK_TEST_NOWPLAYING'] ?? '').isNotEmpty) {
      return const Scaffold(
        backgroundColor: Color(0xFF101828),
        body: Stack(children: [NowPlayingOverlay()]),
      );
    }
    final testLocked = Platform.environment['IMMICH_KIOSK_TEST_LOCKED'];
    if (testLocked != null && testLocked.isNotEmpty) {
      return _DebugLockedLoader(pin: testLocked);
    }
    final testLockedVideo = Platform.environment['IMMICH_KIOSK_TEST_LOCKED_VIDEO'];
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
