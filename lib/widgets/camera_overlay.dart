import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../services/camera_service.dart';
import 'burn_in_drift.dart';

/// The live view from the phone acting as a wireless camera.
///
/// Sits above every screen (added in `main.dart`'s `MaterialApp.builder`, like
/// the shared-content popup) so the camera can be brought up over a slideshow
/// or the album grid alike. It opens as a small window in the corner and
/// expands to fill the panel on a tap; pinching while expanded zooms the
/// phone's sensor rather than scaling the picture here, so zooming in gains
/// real detail instead of enlarging pixels.
///
/// The stream is opened when the window appears and closed the moment it goes
/// away — the phone only encodes while somebody is actually looking.
class CameraOverlay extends StatefulWidget {
  const CameraOverlay({super.key});

  @override
  State<CameraOverlay> createState() => _CameraOverlayState();
}

class _CameraOverlayState extends State<CameraOverlay>
    with SingleTickerProviderStateMixin, BurnInDriftMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<double> _t =
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);

  Player? _player;
  VideoController? _video;
  bool _starting = false;
  bool _streaming = false;

  /// Zoom at the moment a pinch began, so the gesture scales from there
  /// rather than compounding every update.
  double _zoomAtGestureStart = 1.0;

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
    _controller.dispose();
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

      // An MJPEG stream carries no timestamps, so left to itself mpv buffers
      // and invents them, and the picture runs behind what the camera is
      // actually looking at. Asked not to buffer and to show frames untimed,
      // it draws each one as it lands — which is what a live view wants.
      // There's no audio track to bother decoding.
      final native = player.platform;
      if (native is NativePlayer) {
        for (final o in const [
          ['demuxer-lavf-format', 'mpjpeg'],
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

  void _showHud(String text) {
    setState(() => _hud = text);
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _onScaleStart(CameraService service, ScaleStartDetails d) {
    _zoomAtGestureStart = service.zoom;
  }

  void _onScaleUpdate(CameraService service, ScaleUpdateDetails d) {
    // A single finger reports a scale of 1.0 while dragging, which would
    // otherwise be read as a zoom gesture and fight the tap handler.
    if (d.pointerCount < 2) return;
    service.setZoom(_zoomAtGestureStart * d.scale);
    _showHud('${service.zoom.toStringAsFixed(1)}×');
  }

  static const Size _collapsedSize = Size(480, 270);

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CameraService>();

    if (!service.isOpen) {
      if (_streaming) unawaited(_stopStream());
      if (_controller.value != 0) _controller.value = 0;
      return const SizedBox.shrink();
    }

    // After the frame, not during it: bringing the player up calls setState.
    if (!_streaming && !_starting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && service.isOpen) unawaited(_startStream(service));
      });
    }

    final target = service.isExpanded ? 1.0 : 0.0;
    if (_controller.value != target) {
      service.isExpanded ? _controller.forward() : _controller.reverse();
    }

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screen = Size(constraints.maxWidth, constraints.maxHeight);
          final collapsed = applyDrift(_collapsedRect(screen), screen);
          final expanded = _expandedRect(screen);

          return AnimatedBuilder(
            animation: _t,
            builder: (context, _) {
              final v = _t.value;
              final rect = Rect.lerp(collapsed, expanded, v)!;
              return Stack(
                children: [
                  if (v > 0.01)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: v < 0.5,
                        child: GestureDetector(
                          onTap: () => service.setExpanded(false),
                          child: Container(
                            color: Colors.black.withValues(alpha: v),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fromRect(
                    rect: rect,
                    child: _Window(
                      service: service,
                      video: _video,
                      expansion: v,
                      hud: _hud,
                      onTap: () => service.setExpanded(!service.isExpanded),
                      onScaleStart: (d) => _onScaleStart(service, d),
                      onScaleUpdate: (d) => _onScaleUpdate(service, d),
                      onResetZoom: () {
                        service.setZoom(service.minZoom);
                        _showHud('${service.minZoom.toStringAsFixed(1)}×');
                      },
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Rect _collapsedRect(Size screen) {
    const size = _collapsedSize;
    const m = 28.0;
    // Bottom left — the now-playing panel and weather take the other corners.
    return Rect.fromLTWH(
        m, screen.height - size.height - m, size.width, size.height);
  }

  Rect _expandedRect(Size screen) => Rect.fromLTWH(0, 0, screen.width, screen.height);
}

class _Window extends StatelessWidget {
  const _Window({
    required this.service,
    required this.video,
    required this.expansion,
    required this.hud,
    required this.onTap,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onResetZoom,
  });

  final CameraService service;
  final VideoController? video;
  final double expansion;
  final String? hud;
  final VoidCallback onTap;
  final void Function(ScaleStartDetails) onScaleStart;
  final void Function(ScaleUpdateDetails) onScaleUpdate;
  final VoidCallback onResetZoom;

  @override
  Widget build(BuildContext context) {
    final expanded = expansion > 0.5;
    final radius = BorderRadius.circular(24 * (1 - expansion));

    final content = Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video != null)
                Video(
                  controller: video!,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                  fill: Colors.black,
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
                  onDoubleTap: expanded ? onResetZoom : null,
                  onScaleStart: expanded ? onScaleStart : null,
                  onScaleUpdate: expanded ? onScaleUpdate : null,
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
                child: _IconButton(
                  icon: Icons.close,
                  size: expanded ? 64 : 40,
                  onPressed: service.close,
                ),
              ),
              if (expanded)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _ExpandedControls(service: service),
                ),
            ],
          ),
        );

    // Only clip while the corners are actually rounded. Full screen there is
    // nothing to clip, and a clip that size is an offscreen layer the Pi's
    // GL driver would rather not be asked for.
    return expansion < 0.01
        ? ClipRRect(borderRadius: radius, child: content)
        : content;
  }
}

/// Zoom, lens and torch, shown along the bottom while the view is full screen.
class _ExpandedControls extends StatelessWidget {
  const _ExpandedControls({required this.service});

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
            _IconButton(
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

class _IconButton extends StatelessWidget {
  const _IconButton({
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
