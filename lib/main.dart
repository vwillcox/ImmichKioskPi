import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'models/immich_models.dart';
import 'services/config_service.dart';
import 'services/immich_service.dart';
import 'services/indoor_sensor_service.dart';
import 'services/locked_folder_service.dart';
import 'services/media_cache.dart';
import 'services/now_playing_service.dart';
import 'services/weather_service.dart';
import 'screens/about_screen.dart';
import 'screens/album_screen.dart';
import 'screens/gallery_screen.dart';
import 'screens/home_screen.dart';
import 'screens/locked_folder_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/slideshow_screen.dart';
import 'screens/video_player_screen.dart';
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

  // Govee BLE thermometer, read passively from its advertisements.
  final indoor = IndoorSensorService();
  unawaited(indoor.start());

  // Reads what the paired phone is playing over Bluetooth AVRCP.
  final nowPlaying = NowPlayingService()
    ..preferAudioRouted = config.config.nowPlaying.playAudioHere;
  unawaited(nowPlaying.start());

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: config),
        Provider<ImmichService>(create: (_) => ImmichService(config)),
        ChangeNotifierProvider(create: (_) => LockedFolderService(config)),
        ChangeNotifierProvider.value(value: weather),
        ChangeNotifierProvider.value(value: nowPlaying),
        ChangeNotifierProvider.value(value: indoor),
      ],
      child: const ImmichKioskPiApp(),
    ),
  );
}

class ImmichKioskPiApp extends StatelessWidget {
  const ImmichKioskPiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ImmichKioskPi',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // The DSI touchscreen is delivered as mouse/unknown pointer events on
      // Flutter's Linux embedder, so enable drag-scrolling for every pointer
      // kind (otherwise touch drag doesn't scroll lists/grids).
      scrollBehavior: const _AppScrollBehavior(),
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
