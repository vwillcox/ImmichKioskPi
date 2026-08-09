import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/immich_models.dart';
import '../services/media_cache.dart';
import '../services/media_source.dart';
import '../widgets/big_back_button.dart';
import '../widgets/now_playing_overlay.dart';
import '../widgets/weather_overlay.dart';

class SlideshowScreen extends StatefulWidget {
  final List<Asset> images;
  final MediaSource source;
  final SlideshowSettings settings;

  /// Optional label shown in the chrome, e.g. "3 albums".
  final String? title;

  const SlideshowScreen({
    super.key,
    required this.images,
    required this.source,
    required this.settings,
    this.title,
  });

  @override
  State<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends State<SlideshowScreen> {
  late List<Asset> _order;
  int _index = 0;
  bool _playing = true;
  bool _chrome = false;
  bool _ready = false; // first image decoded and ready to show
  bool _advancing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.images);
    if (widget.settings.shuffle) {
      _order.shuffle(Random());
    }
    // Decode the first image before showing anything, so the slideshow starts
    // on a fully-laid-out photo rather than animating an empty frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startWhenReady());
  }

  ImageProvider _providerFor(int i) => CachedNetworkImageProvider(
        widget.source.previewUrl(_order[i].id),
        headers: widget.source.authHeaders,
        cacheManager: ImmichKioskPiCache.manager,
      );

  /// Fully decode the image at [i]. Bounded so a broken/slow image can't stall
  /// the slideshow.
  Future<void> _decode(int i) async {
    if (!mounted || _order.isEmpty) return;
    try {
      await precacheImage(_providerFor(i), context)
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      // Fall through and display anyway; the Image widget shows its own error.
    }
  }

  Future<void> _startWhenReady() async {
    await _decode(_index);
    if (!mounted) return;
    setState(() => _ready = true);
    _start();
    _precacheNeighbor();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(seconds: widget.settings.intervalSeconds),
      (_) => _next(),
    );
    _playing = true;
  }

  void _stop() {
    _timer?.cancel();
    _playing = false;
  }

  /// Move to [target], but only swap once its image is decoded — that way the
  /// transition and Ken Burns pan always run on a complete, correctly-sized
  /// photo instead of starting mid-load.
  Future<void> _goTo(int target) async {
    if (_order.isEmpty || _advancing) return;
    _advancing = true;
    await _decode(target);
    if (mounted) setState(() => _index = target);
    _advancing = false;
    _precacheNeighbor();
  }

  void _next() => _goTo((_index + 1) % _order.length);

  void _prev() => _goTo((_index - 1 + _order.length) % _order.length);

  /// Pull a deep runway of upcoming slides into the cache. The Pi has ample
  /// disk and RAM, so keeping several ahead means transitions never wait on
  /// the network even if it hiccups.
  static const int _lookahead = 8;

  void _precacheNeighbor() {
    if (_order.length < 2 || !mounted) return;
    for (var step = 1; step <= _lookahead && step < _order.length; step++) {
      final i = (_index + step) % _order.length;
      precacheImage(_providerFor(i), context);
      // Also warm the small backdrop image used behind letterboxed photos.
      precacheImage(
        CachedNetworkImageProvider(
          widget.source.thumbUrl(_order[i].id),
          headers: widget.source.authHeaders,
          cacheManager: ImmichKioskPiCache.manager,
        ),
        context,
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_order.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('No photos to show',
              style: TextStyle(color: Colors.white70, fontSize: 20)),
        ),
      );
    }

    final asset = _order[_index];
    final t = widget.settings.transition;

    // Nothing is shown until the first photo is decoded, so no animation ever
    // runs against a half-loaded image.
    final Widget slide = !_ready
        ? const SizedBox.expand(
            key: ValueKey('loading'),
            child: Center(child: CircularProgressIndicator()),
          )
        : _SlideImage(
            key: ValueKey(asset.id),
            provider: _providerFor(_index),
            // Small, cheap image used only for the blurred backdrop.
            backdropProvider: CachedNetworkImageProvider(
              widget.source.thumbUrl(asset.id),
              headers: widget.source.authHeaders,
              cacheManager: ImmichKioskPiCache.manager,
            ),
            kenBurns: t == SlideshowTransition.kenBurns,
            durationSeconds: widget.settings.intervalSeconds,
          );

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        // Swipe left/right to change photo, swipe down to leave the slideshow.
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 200) return;
          _stop(); // manual navigation pauses the timer
          if (v < 0) {
            _next();
          } else {
            _prev();
          }
          setState(() {});
        },
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 300) Navigator.of(context).maybePop();
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 900),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) {
                  if (t == SlideshowTransition.slide) {
                    final inFromRight = Tween<Offset>(
                      begin: const Offset(1, 0),
                      end: Offset.zero,
                    ).animate(anim);
                    return SlideTransition(position: inFromRight, child: child);
                  }
                  if (t == SlideshowTransition.pageTurn) {
                    // The incoming photo rotates in from edge-on (as if it
                    // were the next page); the outgoing one rotates the same
                    // way out, hinged on the same edge, so they read as one
                    // continuous page turning rather than two independent
                    // animations. Capped at 90° so the mirrored back of the
                    // image is never visible. Transform itself isn't
                    // animation-aware — unlike FadeTransition/SlideTransition,
                    // it only reads anim.value once at build time — so it has
                    // to be driven explicitly via AnimatedBuilder or it just
                    // freezes at whatever angle it first built with.
                    return AnimatedBuilder(
                      animation: anim,
                      builder: (context, c) {
                        final angle = (1 - anim.value) * (pi / 2);
                        return Transform(
                          alignment: Alignment.centerLeft,
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, 0.0012)
                            ..rotateY(angle),
                          child: c,
                        );
                      },
                      child: child,
                    );
                  }
                  return FadeTransition(opacity: anim, child: child);
                },
                child: slide,
              ),
            ),

            // Weather overlay (photo-frame style). Slideshow only.
            const WeatherOverlay(),

            // What the paired phone is playing. Slideshow only.
            const NowPlayingOverlay(),

            // Controls
            AnimatedOpacity(
              opacity: _chrome ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_chrome,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.only(top: 6, left: 4, right: 16),
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
                          const SizedBox(width: 12),
                          if (widget.title != null)
                            Text(widget.title!,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 18)),
                          const Spacer(),
                          Text('${_index + 1} / ${_order.length}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 18)),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black87, Colors.transparent],
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            iconSize: 44,
                            icon: const Icon(Icons.skip_previous,
                                color: Colors.white),
                            onPressed: () {
                              _stop();
                              _prev();
                              setState(() {});
                            },
                          ),
                          const SizedBox(width: 24),
                          IconButton(
                            iconSize: 60,
                            icon: Icon(
                              _playing
                                  ? Icons.pause_circle
                                  : Icons.play_circle,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              setState(() {
                                if (_playing) {
                                  _stop();
                                } else {
                                  _start();
                                }
                              });
                            },
                          ),
                          const SizedBox(width: 24),
                          IconButton(
                            iconSize: 44,
                            icon: const Icon(Icons.skip_next,
                                color: Colors.white),
                            onPressed: () {
                              _stop();
                              _next();
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One slide. The photo is always shown whole (BoxFit.contain) and any Ken
/// Burns motion starts from that fitted state. A blurred, dimmed copy fills
/// the letterbox area so portrait photos don't sit on hard black bars.
class _SlideImage extends StatefulWidget {
  final ImageProvider provider;
  final ImageProvider? backdropProvider;
  final bool kenBurns;
  final int durationSeconds;
  const _SlideImage({
    super.key,
    required this.provider,
    this.backdropProvider,
    required this.kenBurns,
    required this.durationSeconds,
  });

  @override
  State<_SlideImage> createState() => _SlideImageState();
}

class _SlideImageState extends State<_SlideImage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(seconds: widget.durationSeconds + 1),
  );
  late final Alignment _from;
  late final Alignment _to;

  @override
  void initState() {
    super.initState();
    final r = Random();
    Alignment rnd() =>
        Alignment(r.nextDouble() * 1.4 - 0.7, r.nextDouble() * 1.4 - 0.7);
    _from = rnd();
    _to = rnd();
    if (widget.kenBurns) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The whole photo, scaled to fit the screen without cropping.
    final img = Image(
      image: widget.provider,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );

    Widget foreground = SizedBox.expand(child: img);
    if (widget.kenBurns) {
      foreground = AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          // Starts at 1.0 — the fitted image — then drifts gently.
          final scale = 1.0 + 0.10 * _c.value;
          final align = Alignment.lerp(_from, _to, _c.value)!;
          return Transform.scale(scale: scale, alignment: align, child: child);
        },
        child: foreground,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Static blurred fill. Uses the small thumbnail so the blur is cheap
        // on the Pi, and sits outside the Ken Burns transform so it isn't
        // re-blurred every frame.
        if (widget.backdropProvider != null)
          RepaintBoundary(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Image(
                image: widget.backdropProvider!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        const ColoredBox(color: Color(0x8C000000)),
        foreground,
      ],
    );
  }
}
