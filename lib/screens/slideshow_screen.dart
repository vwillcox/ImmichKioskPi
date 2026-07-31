import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/immich_models.dart';
import '../services/media_source.dart';
import '../widgets/big_back_button.dart';
import '../widgets/weather_overlay.dart';

class SlideshowScreen extends StatefulWidget {
  final List<Asset> images;
  final MediaSource source;
  final SlideshowSettings settings;
  const SlideshowScreen({
    super.key,
    required this.images,
    required this.source,
    required this.settings,
  });

  @override
  State<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends State<SlideshowScreen> {
  late List<Asset> _order;
  int _index = 0;
  bool _playing = true;
  bool _chrome = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.images);
    if (widget.settings.shuffle) {
      _order.shuffle(Random());
    }
    _start();
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

  void _next() {
    if (_order.isEmpty) return;
    setState(() => _index = (_index + 1) % _order.length);
    _precacheNeighbor();
  }

  void _prev() {
    if (_order.isEmpty) return;
    setState(() => _index = (_index - 1 + _order.length) % _order.length);
  }

  void _precacheNeighbor() {
    if (_order.length < 2) return;
    final nextId = _order[(_index + 1) % _order.length].id;
    precacheImage(
      CachedNetworkImageProvider(widget.source.previewUrl(nextId),
          headers: widget.source.authHeaders),
      context,
    );
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
    final provider = CachedNetworkImageProvider(
      widget.source.previewUrl(asset.id),
      headers: widget.source.authHeaders,
    );
    final t = widget.settings.transition;

    Widget slide = _SlideImage(
      key: ValueKey(asset.id),
      provider: provider,
      kenBurns: t == SlideshowTransition.kenBurns,
      durationSeconds: widget.settings.intervalSeconds,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
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
                  return FadeTransition(opacity: anim, child: child);
                },
                child: slide,
              ),
            ),

            // Weather overlay (photo-frame style). Slideshow only.
            const WeatherOverlay(),

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

/// One slide. Optionally applies a slow Ken Burns zoom/pan while shown.
class _SlideImage extends StatefulWidget {
  final ImageProvider provider;
  final bool kenBurns;
  final int durationSeconds;
  const _SlideImage({
    super.key,
    required this.provider,
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
    final img = Image(
      image: widget.provider,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
    if (!widget.kenBurns) {
      return SizedBox.expand(child: img);
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final scale = 1.0 + 0.12 * _c.value;
        final align = Alignment.lerp(_from, _to, _c.value)!;
        return Transform.scale(
          scale: scale,
          alignment: align,
          child: child,
        );
      },
      child: SizedBox.expand(child: img),
    );
  }
}
