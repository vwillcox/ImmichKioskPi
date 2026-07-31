import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/immich_models.dart';
import '../services/media_source.dart';
import '../widgets/big_back_button.dart';
import 'video_player_screen.dart';

/// Full-screen swipeable gallery. Images support pinch-zoom, double-tap zoom,
/// and explicit +/- buttons (touchscreen-friendly). Videos show a poster with
/// a play button that opens the dedicated player.
class GalleryScreen extends StatefulWidget {
  final List<Asset> assets;
  final int initialIndex;
  final MediaSource source;

  /// Optional hook run before a video opens (Locked Folder re-elevation).
  final Future<void> Function()? onBeforeVideo;

  const GalleryScreen({
    super.key,
    required this.assets,
    required this.initialIndex,
    required this.source,
    this.onBeforeVideo,
  });

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _openVideo(Asset a) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(
        asset: a,
        source: widget.source,
        onBeforePlay: widget.onBeforeVideo,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            // Disable horizontal paging while a photo is zoomed so panning works.
            physics: _zoomed
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemCount: widget.assets.length,
            onPageChanged: (i) => setState(() {
              _index = i;
              _zoomed = false;
            }),
            itemBuilder: (context, i) {
              final a = widget.assets[i];
              if (a.isImage) {
                return ZoomablePhoto(
                  imageProvider: CachedNetworkImageProvider(
                    source.previewUrl(a.id),
                    headers: source.authHeaders,
                  ),
                  fallbackProvider: CachedNetworkImageProvider(
                    source.originalUrl(a.id),
                    headers: source.authHeaders,
                  ),
                  onZoomChanged: (z) {
                    if (z != _zoomed) setState(() => _zoomed = z);
                  },
                );
              }
              return _VideoPoster(
                asset: a,
                source: source,
                onPlay: () => _openVideo(a),
              );
            },
          ),

          // Always-visible top bar with a large back target.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.only(top: 8, left: 8, right: 20, bottom: 8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  const BigBackButton(),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${_index + 1} / ${widget.assets.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single pinch/double-tap/button zoomable photo.
class ZoomablePhoto extends StatefulWidget {
  final ImageProvider imageProvider;
  final ImageProvider? fallbackProvider;
  final ValueChanged<bool> onZoomChanged;
  const ZoomablePhoto({
    super.key,
    required this.imageProvider,
    this.fallbackProvider,
    required this.onZoomChanged,
  });

  @override
  State<ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<ZoomablePhoto>
    with SingleTickerProviderStateMixin {
  final TransformationController _tc = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _animation;
  TapDownDetails? _doubleTapDetails;
  bool _useFallback = false;
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_reportZoom);
  }

  void _reportZoom() {
    final scale = _tc.value.getMaxScaleOnAxis();
    widget.onZoomChanged(scale > 1.02);
  }

  @override
  void dispose() {
    _tc.removeListener(_reportZoom);
    _tc.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _animateTo(Matrix4 target) {
    _animation = Matrix4Tween(begin: _tc.value, end: target).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOut),
    )..addListener(() => _tc.value = _animation!.value);
    _anim.forward(from: 0);
  }

  void _handleDoubleTap() {
    final current = _tc.value.getMaxScaleOnAxis();
    if (current > 1.05) {
      _animateTo(Matrix4.identity());
    } else {
      final pos = _doubleTapDetails?.localPosition;
      const scale = 2.5;
      if (pos == null) {
        _animateTo(Matrix4.identity()..scale(scale));
      } else {
        final x = -pos.dx * (scale - 1);
        final y = -pos.dy * (scale - 1);
        _animateTo(Matrix4.identity()
          ..translate(x, y)
          ..scale(scale));
      }
    }
  }

  void _zoomBy(double factor) {
    final current = _tc.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(_minScale, _maxScale);
    _animateTo(Matrix4.identity()..scale(target));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GestureDetector(
          onDoubleTapDown: (d) => _doubleTapDetails = d,
          onDoubleTap: _handleDoubleTap,
          child: InteractiveViewer(
            transformationController: _tc,
            minScale: _minScale,
            maxScale: _maxScale,
            clipBehavior: Clip.none,
            child: Center(
              child: Image(
                image: _useFallback && widget.fallbackProvider != null
                    ? widget.fallbackProvider!
                    : widget.imageProvider,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, __, ___) {
                  if (!_useFallback && widget.fallbackProvider != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _useFallback = true);
                    });
                    return const Center(child: CircularProgressIndicator());
                  }
                  return const Center(
                    child: Icon(Icons.broken_image_outlined,
                        color: Colors.white38, size: 64),
                  );
                },
              ),
            ),
          ),
        ),
        // Explicit zoom controls (guaranteed single-touch on any hardware).
        Positioned(
          right: 16,
          bottom: 24,
          child: Column(
            children: [
              _ZoomButton(icon: Icons.add, onTap: () => _zoomBy(1.6)),
              const SizedBox(height: 12),
              _ZoomButton(icon: Icons.remove, onTap: () => _zoomBy(1 / 1.6)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ZoomButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, color: Colors.white, size: 30),
        ),
      ),
    );
  }
}

class _VideoPoster extends StatelessWidget {
  final Asset asset;
  final MediaSource source;
  final VoidCallback onPlay;
  const _VideoPoster({
    required this.asset,
    required this.source,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedNetworkImage(
          imageUrl: source.previewUrl(asset.id),
          httpHeaders: source.authHeaders,
          fit: BoxFit.contain,
        ),
        Center(
          child: Material(
            color: Colors.black45,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPlay,
              child: const Padding(
                padding: EdgeInsets.all(24),
                child: Icon(Icons.play_arrow, color: Colors.white, size: 64),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
