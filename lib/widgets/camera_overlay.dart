import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../screens/camera_screen.dart';
import '../services/camera_service.dart';
import 'burn_in_drift.dart';

/// The live view from the phone acting as a wireless camera.
///
/// Sits above every screen (added in `main.dart`'s `MaterialApp.builder`, like
/// the shared-content popup) so the camera can be brought up over a slideshow
/// or the album grid alike. This is the small corner window; tapping it opens
/// [CameraScreen], which is where the picture goes full screen and where
/// pinching zooms the phone's sensor rather than scaling the picture here.
///
/// The stream is opened when the window appears and closed the moment it goes
/// away — the phone only encodes while somebody is actually looking.
class CameraOverlay extends StatefulWidget {
  const CameraOverlay({super.key, required this.navigatorKey});

  /// The overlay is a *sibling* of the Navigator, not a descendant, so
  /// `Navigator.of(context)` can't find it by walking up the tree.
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<CameraOverlay> createState() => _CameraOverlayState();
}

class _CameraOverlayState extends State<CameraOverlay> with BurnInDriftMixin {
  final GlobalKey _windowKey = GlobalKey();

  Player? _player;
  VideoController? _video;
  bool _starting = false;
  bool _streaming = false;

  /// True while [CameraScreen] is up. The corner window is a sibling of the
  /// Navigator, so without this it stays painted on top of the page.
  bool _fullScreen = false;

  String? _hud;
  Timer? _hudTimer;

  @override
  void initState() {
    super.initState();
    startDrift();
  }

  @override
  void dispose() {
    stopDrift();
    _hudTimer?.cancel();
    unawaited(_player?.dispose());
    super.dispose();
  }

  /// Bring up the player and hand libmpv its render target, once.
  ///
  /// The [Video] widget must be in the tree and painted *before* any media is
  /// opened. Open a stream first and libmpv finds it has nowhere to draw, so
  /// it falls back to a video output that opens its own window — which on
  /// this compositor lands on top of the kiosk as a rectangle that never
  /// repaints, over the middle of the picture.
  Future<void> _ensurePlayer() async {
    if (_player != null) return;
    final player = Player();
    final video = VideoController(
      player,
      // Same reason as the video player: hardware decoding on the Pi's GL
      // path renders a solid frame instead of the picture.
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );
    setState(() {
      _player = player;
      _video = video;
    });
    // VideoController's constructor returns before it has done anything: the
    // native controller that registers the texture and hands libmpv its
    // render context is only built on a post-frame callback, asynchronously.
    // This future is what completes when that is actually in place.
    await video.platform.future;
  }

  Future<void> _startStream(CameraService service) async {
    if (_streaming || _starting) return;
    _starting = true;
    try {
      await _ensurePlayer();
      final player = _player;
      if (player == null || !mounted) return;

      // Asked not to buffer and to show frames untimed, mpv draws each one as
      // it lands rather than running behind what the camera is looking at,
      // which is what a live view wants. RTSP over TCP because UDP loses
      // frames on this network. The stream carries an audio track we have no
      // use for.
      final native = player.platform;
      if (native is NativePlayer) {
        for (final o in const [
          ['rtsp-transport', 'tcp'],
          ['cache', 'no'],
          ['untimed', 'yes'],
          ['video-latency-hacks', 'yes'],
          ['interpolation', 'no'],
          ['demuxer-lavf-analyzeduration', '0.1'],
          ['network-timeout', '5'],
          ['aid', 'no'],
        ]) {
          try {
            await native.setProperty(o[0], o[1]);
          } catch (e) {
            debugPrint('CameraOverlay: mpv option ${o[0]} rejected: $e');
          }
        }
      }

      // Wait for the lens/size/zoom to be applied before connecting: those
      // restart the camera on the phone, and a stream opened across that
      // restart keeps the geometry it saw first.
      await service.ready;
      if (!mounted || !service.isOpen) return;

      await player.open(Media(service.streamUrl));
      _streaming = true;
    } catch (e) {
      debugPrint('CameraOverlay: could not open stream: $e');
    } finally {
      _starting = false;
    }
  }

  /// Drop the connection to the phone without tearing down the player: the
  /// render target is expensive to establish and, as above, getting it wrong
  /// costs a stray window. The player is disposed in [dispose].
  Future<void> _stopStream() async {
    if (!_streaming) return;
    _streaming = false;
    await _player?.stop();
  }

  static const Size _collapsedSize = Size(480, 270);

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CameraService>();

    if (!service.isOpen) {
      if (_streaming) unawaited(_stopStream());
      return const SizedBox.shrink();
    }
    // Hidden, but the stream stays up: the page is showing it.
    if (_fullScreen) return const SizedBox.shrink();

    // After the frame, not during it: bringing the player up calls setState.
    if (!_streaming && !_starting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && service.isOpen) unawaited(_startStream(service));
      });
    }

    final window = _Window(
      key: _windowKey,
      service: service,
      video: _video,
      hud: _hud,
      onTap: _openFullScreen,
    );

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screen = Size(constraints.maxWidth, constraints.maxHeight);
          final rect = applyDrift(_collapsedRect(screen), screen);
          return Stack(
            children: [Positioned.fromRect(rect: rect, child: window)],
          );
        },
      ),
    );
  }

  /// Full screen is a route of its own rather than this window grown to fill
  /// the panel — see [CameraScreen]. This window's stream is dropped while it
  /// is up so the phone is only ever asked for one.
  Future<void> _openFullScreen() async {
    final navigator = widget.navigatorKey.currentState;
    final player = _player;
    final video = _video;
    if (navigator == null || player == null || video == null) return;

    // The page borrows this player rather than building its own: two alive at
    // once and the second never opens, and disposing this one to make room
    // leaves its replacement hanging before it registers a texture. The
    // stream simply stays up while the page shows it instead of this window.
    setState(() => _fullScreen = true);
    await navigator.push(MaterialPageRoute(
      builder: (_) => CameraScreen(player: player, controller: video),
    ));
    if (mounted) setState(() => _fullScreen = false);
  }

  Rect _collapsedRect(Size screen) {
    const size = _collapsedSize;
    const m = 28.0;
    // Bottom left — the now-playing panel and weather take the other corners.
    return Rect.fromLTWH(
        m, screen.height - size.height - m, size.width, size.height);
  }
}

class _Window extends StatelessWidget {
  const _Window({
    super.key,
    required this.service,
    required this.video,
    required this.hud,
    required this.onTap,
  });

  final CameraService service;
  final VideoController? video;
  final String? hud;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {

    final content = Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video != null)
                RotatedBox(
                  quarterTurns: service.settings.viewQuarterTurns,
                  child: Video(
                    controller: video!,
                    controls: NoVideoControls,
                    fit: BoxFit.contain,
                    fill: Colors.black,
                  ),
                )
              else
                const Center(
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              // Taps are handled by a layer of its own *above* the picture
              // rather than by an ancestor: the video widget takes part in
              // the gesture arena too, and when it wins the tap that should
              // have expanded the window goes nowhere.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                ),
              ),
              if (service.lastError != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      service.lastError!,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
                ),
              if (hud != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      hud!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              // Close button, always available so the small window can be
              // dismissed without expanding it first.
              Positioned(
                top: 8,
                right: 8,
                child: CameraRoundButton(
                  icon: Icons.close,
                  size: 40,
                  onPressed: service.close,
                ),
              ),
            ],
          ),
        );

    return ClipRRect(borderRadius: BorderRadius.circular(24), child: content);
  }
}

/// Zoom, lens and torch, shown along the bottom of the full-screen view.
class CameraControls extends StatelessWidget {
  const CameraControls({super.key, required this.service});

  final CameraService service;

  @override
  Widget build(BuildContext context) {
    final lenses = service.status?.lenses ?? const [];
    final battery = service.status?.batteryPercent;

    return Container(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.75),
          ],
        ),
      ),
      // Taps on the controls must not reach the expand/collapse handler
      // underneath, or adjusting the zoom would shrink the window.
      child: GestureDetector(
        onTap: () {},
        child: Row(
          children: [
            if (lenses.length > 1)
              for (final lens in lenses)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _PillButton(
                    label: lens.facing == 'front' ? 'Front' : 'Back',
                    selected: lens.id == service.cameraId,
                    onPressed: () => service.selectCamera(lens.id),
                  ),
                ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  const Icon(Icons.zoom_out, color: Colors.white70, size: 32),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 8,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 18),
                      ),
                      child: Slider(
                        value: service.zoom
                            .clamp(service.minZoom, service.maxZoom),
                        min: service.minZoom,
                        max: service.maxZoom,
                        onChanged: service.setZoom,
                      ),
                    ),
                  ),
                  const Icon(Icons.zoom_in, color: Colors.white70, size: 32),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 96,
                    child: Text(
                      '${service.zoom.toStringAsFixed(1)}×',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            CameraRoundButton(
              icon: service.torch ? Icons.flashlight_on : Icons.flashlight_off,
              size: 64,
              onPressed: () => service.setTorch(!service.torch),
            ),
            if (battery != null) ...[
              const SizedBox(width: 20),
              Row(
                children: [
                  Icon(
                    battery <= 20
                        ? Icons.battery_alert
                        : Icons.battery_full,
                    color: battery <= 20 ? Colors.orangeAccent : Colors.white70,
                    size: 28,
                  ),
                  const SizedBox(width: 6),
                  Text('$battery%',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 22)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class CameraRoundButton extends StatelessWidget {
  const CameraRoundButton({
    super.key,
    required this.icon,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.55),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? Theme.of(context).colorScheme.primary
          : Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 22),
          ),
        ),
      ),
    );
  }
}
