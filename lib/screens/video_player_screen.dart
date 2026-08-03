import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/immich_models.dart';
import '../services/media_source.dart';
import '../widgets/big_back_button.dart';

const List<double> kPlaybackSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

class VideoPlayerScreen extends StatefulWidget {
  final Asset asset;
  final MediaSource source;

  /// Optional hook run before opening the stream (e.g. re-elevate the Locked
  /// Folder session so the video doesn't 404).
  final Future<void> Function()? onBeforePlay;

  const VideoPlayerScreen({
    super.key,
    required this.asset,
    required this.source,
    this.onBeforePlay,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final Player _player = Player();
  // Force software decoding: some videos (e.g. portrait phone clips) render as a
  // solid blue frame under hardware decoding on the Pi's GL path — audio and the
  // timeline advance but the hardware surface can't be sampled. The Pi 5 decodes
  // these in software without trouble.
  late final VideoController _controller = VideoController(
    _player,
    configuration:
        const VideoControllerConfiguration(enableHardwareAcceleration: false),
  );
  final _subs = <StreamSubscription>[];
  final _transform = TransformationController();

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = true;
  double _rate = 1.0;
  bool _controlsVisible = true;
  bool _seeking = false;

  // Gesture feedback ("+10s", "70%") shown briefly in the centre.
  String? _hud;
  Timer? _hudTimer;
  double _volume = 100;
  double _volumeBeforeMute = 100;
  bool get _muted => _volume <= 0;

  /// Mute drops the volume to zero and remembers where it was, so unmuting
  /// returns to the same level.
  Future<void> _toggleMute() async {
    setState(() {
      if (_muted) {
        _volume = _volumeBeforeMute > 0 ? _volumeBeforeMute : 100;
      } else {
        _volumeBeforeMute = _volume;
        _volume = 0;
      }
    });
    await _applyVolume();
    _showHud(_muted ? 'Muted' : 'Volume ${_volume.round()}%');
  }

  /// Apply the level to the player. As well as mpv's `volume`, this sets mpv's
  /// dedicated `mute` property: volume alone was reported as still audible on
  /// this hardware, and `mute` silences the output regardless of how the
  /// volume scale is being applied.
  Future<void> _applyVolume() async {
    await _player.setVolume(_volume);
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('mute', _muted ? 'yes' : 'no');
      } catch (e) {
        debugPrint('mute property error: $e');
      }
    }
  }
  Duration _dragStartPosition = Duration.zero;
  bool _zoomed = false;

  void _showHud(String text) {
    _hudTimer?.cancel();
    setState(() => _hud = text);
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _skip(int seconds) {
    final target = _position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    _player.seek(clamped);
    _showHud('${seconds > 0 ? '+' : ''}${seconds}s');
  }

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onZoomChanged);
    _open();
    _subs.add(_player.stream.position.listen((p) {
      if (!_seeking && mounted) setState(() => _position = p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
  }

  Future<void> _open() async {
    if (widget.onBeforePlay != null) {
      await widget.onBeforePlay!();
    }
    await _player.open(Media(
      widget.source.videoUrl(widget.asset.id),
      httpHeaders: widget.source.authHeaders,
    ));
  }

  void _onZoomChanged() {
    final z = _transform.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed && mounted) setState(() => _zoomed = z);
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _transform.removeListener(_onZoomChanged);
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _setRate(double r) {
    _player.setRate(r);
    setState(() => _rate = r);
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inMilliseconds.toDouble();
    final pos = _position.inMilliseconds.clamp(0, total == 0 ? 0 : total).toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _controlsVisible = !_controlsVisible),
        // Double-tap the left/right third to skip; middle toggles play/pause.
        onDoubleTapDown: (d) {
          final w = MediaQuery.of(context).size.width;
          final x = d.globalPosition.dx;
          if (x < w / 3) {
            _skip(-10);
          } else if (x > w * 2 / 3) {
            _skip(10);
          } else {
            _player.playOrPause();
          }
        },
        onDoubleTap: () {},
        // Horizontal drag scrubs through the video.
        onHorizontalDragStart: _zoomed ? null : (_) => _dragStartPosition = _position,
        onHorizontalDragUpdate: _zoomed ? null : (d) {
          if (_duration == Duration.zero) return;
          final w = MediaQuery.of(context).size.width;
          // Full width of the screen ≈ the whole clip.
          final deltaMs =
              (d.localPosition.dx / w) * _duration.inMilliseconds;
          var target = _dragStartPosition + Duration(milliseconds: deltaMs.toInt());
          if (target < Duration.zero) target = Duration.zero;
          if (target > _duration) target = _duration;
          setState(() {
            _seeking = true;
            _position = target;
          });
          _showHud(_fmt(target));
        },
        onHorizontalDragEnd: _zoomed ? null : (_) async {
          await _player.seek(_position);
          if (mounted) setState(() => _seeking = false);
        },
        // Vertical drag adjusts volume; a flick down closes the player.
        onVerticalDragUpdate: _zoomed ? null : (d) {
          final h = MediaQuery.of(context).size.height;
          final next = (_volume - (d.delta.dy / h) * 200).clamp(0.0, 100.0);
          if ((next - _volume).abs() < 0.5) return;
          setState(() => _volume = next);
          if (_volume > 0) _volumeBeforeMute = _volume;
          unawaited(_applyVolume());
          _showHud(_volume <= 0 ? 'Muted' : 'Volume ${_volume.round()}%');
        },
        onVerticalDragEnd: _zoomed ? null : (d) {
          if ((d.primaryVelocity ?? 0) > 700) Navigator.of(context).maybePop();
        },
        child: Stack(
          children: [
            // Zoomable video surface. Single-finger panning is only enabled
            // once zoomed in — otherwise InteractiveViewer would win the
            // gesture arena and swallow the scrub/volume/dismiss drags.
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1.0,
                maxScale: 5.0,
                panEnabled: _zoomed,
                child: Video(
                  controller: _controller,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                ),
              ),
            ),

            // Top bar
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: Container(
                  padding: const EdgeInsets.only(top: 8, left: 4, right: 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 64 + 8), // room for the fixed back button
                      Expanded(
                        child: Text(
                          widget.asset.fileName ?? 'Video',
                          style: const TextStyle(color: Colors.white, fontSize: 18),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.zoom_out_map, color: Colors.white),
                        iconSize: 30,
                        onPressed: () => setState(
                            () => _transform.value = Matrix4.identity()),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Bottom controls
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: _BottomControls(
                    playing: _playing,
                    position: _position,
                    duration: _duration,
                    posValue: pos,
                    totalValue: total,
                    rate: _rate,
                    fmt: _fmt,
                    onPlayPause: _player.playOrPause,
                    volume: _volume,
                    muted: _muted,
                    onToggleMute: _toggleMute,
                    onSeekStart: () => setState(() => _seeking = true),
                    onSeekChanged: (v) => setState(
                        () => _position = Duration(milliseconds: v.toInt())),
                    onSeekEnd: (v) async {
                      await _player.seek(Duration(milliseconds: v.toInt()));
                      setState(() => _seeking = false);
                    },
                    onRate: _setRate,
                  ),
                ),
              ),
            ),

            // Transient gesture feedback (skip / scrub / volume).
            if (_hud != null)
              Center(
                child: AnimatedOpacity(
                  opacity: 1,
                  duration: const Duration(milliseconds: 120),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 26, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.66),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      _hud!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),

            // Always-visible, large back target.
            const Positioned(top: 10, left: 12, child: BigBackButton()),
          ],
        ),
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  final bool playing;
  final Duration position;
  final Duration duration;
  final double posValue;
  final double totalValue;
  final double rate;
  final String Function(Duration) fmt;
  final VoidCallback onPlayPause;
  final double volume;
  final bool muted;
  final VoidCallback onToggleMute;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onRate;

  const _BottomControls({
    required this.playing,
    required this.position,
    required this.duration,
    required this.posValue,
    required this.totalValue,
    required this.rate,
    required this.fmt,
    required this.onPlayPause,
    required this.volume,
    required this.muted,
    required this.onToggleMute,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onRate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Speed chips
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Center(
                    child: Icon(Icons.speed, color: Colors.white70, size: 22),
                  ),
                ),
                for (final s in kPlaybackSpeeds)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text('${s}x'),
                      selected: rate == s,
                      onSelected: (_) => onRate(s),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                iconSize: 44,
                icon: Icon(playing ? Icons.pause_circle : Icons.play_circle,
                    color: Colors.white),
                onPressed: onPlayPause,
              ),
              Text(fmt(position), style: const TextStyle(color: Colors.white)),
              Expanded(
                child: Slider(
                  min: 0,
                  max: totalValue <= 0 ? 1 : totalValue,
                  value: posValue,
                  onChangeStart: (_) => onSeekStart(),
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                ),
              ),
              Text(fmt(duration), style: const TextStyle(color: Colors.white)),
              const SizedBox(width: 8),
              IconButton(
                iconSize: 38,
                tooltip: muted ? 'Unmute' : 'Mute',
                icon: Icon(
                  muted
                      ? Icons.volume_off
                      : (volume < 50 ? Icons.volume_down : Icons.volume_up),
                  color: muted ? const Color(0xFFFF8A8A) : Colors.white,
                ),
                onPressed: onToggleMute,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
