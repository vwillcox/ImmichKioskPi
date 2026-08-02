import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'burn_in_drift.dart';

import '../config/app_config.dart';
import '../services/config_service.dart';
import '../services/now_playing_service.dart';

String _fmt(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Shows what the paired phone is playing. Collapsed it's a corner card with
/// artwork, title and progress; tapping expands it to a full-screen player with
/// transport controls, and tapping again shrinks it back.
///
/// Place inside a Stack that fills the screen (slideshow only).
class NowPlayingOverlay extends StatefulWidget {
  final EdgeInsets margin;
  const NowPlayingOverlay({super.key, this.margin = const EdgeInsets.all(28)});

  @override
  State<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<NowPlayingOverlay>
    with SingleTickerProviderStateMixin, BurnInDriftMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 340),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  bool get _expanded => _controller.value > 0.5;

  @override
  void initState() {
    super.initState();
    startDrift();
  }

  @override
  void dispose() {
    stopDrift();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() => _expanded ? _controller.reverse() : _controller.forward();

  static const Size _collapsedSize = Size(420, 150);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ConfigService>().config.nowPlaying;
    final service = context.watch<NowPlayingService>();
    if (!settings.enabled ||
        !service.available ||
        !service.now.hasTrack ||
        service.idleHidden) {
      // Collapse if the music stopped while expanded.
      if (_controller.value != 0) _controller.reverse();
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screen = Size(constraints.maxWidth, constraints.maxHeight);
          final collapsed =
              applyDrift(_collapsedRect(screen, settings.corner), screen);
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
                          onTap: _toggle,
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.6 * v),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fromRect(
                    rect: rect,
                    child: GestureDetector(
                      onTap: _toggle,
                      child: _Panel(
                        service: service,
                        expansion: v,
                      ),
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

  Rect _collapsedRect(Size screen, OverlayCorner corner) {
    const size = _collapsedSize;
    final m = widget.margin;
    final isTop =
        corner == OverlayCorner.topLeft || corner == OverlayCorner.topRight;
    final isLeft =
        corner == OverlayCorner.topLeft || corner == OverlayCorner.bottomLeft;
    final left = isLeft ? m.left : screen.width - size.width - m.right;
    final top = isTop ? m.top : screen.height - size.height - m.bottom;
    return Rect.fromLTWH(left, top, size.width, size.height);
  }

  Rect _expandedRect(Size screen) {
    const inset = 28.0;
    // Cap the height so the card hugs its content rather than leaving a lot of
    // empty space above and below on a 1200px-tall panel.
    final width = (screen.width - inset * 2).clamp(0.0, 1400.0);
    final height = (screen.height - inset * 2).clamp(0.0, 620.0);
    return Rect.fromLTWH((screen.width - width) / 2,
        (screen.height - height) / 2, width, height);
  }
}

class _Panel extends StatelessWidget {
  final NowPlayingService service;
  final double expansion;
  const _Panel({required this.service, required this.expansion});

  @override
  Widget build(BuildContext context) {
    final collapsedOpacity = (1 - expansion * 2).clamp(0.0, 1.0);
    final detailOpacity = ((expansion - 0.5) * 2).clamp(0.0, 1.0);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66 + 0.22 * expansion),
        borderRadius: BorderRadius.circular(26 + 6 * expansion),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 18 + 20 * expansion,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26 + 6 * expansion),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (collapsedOpacity > 0)
              Opacity(
                opacity: collapsedOpacity,
                child: _CollapsedContent(service: service),
              ),
            if (detailOpacity > 0)
              Opacity(
                opacity: detailOpacity,
                child: _DetailContent(service: service),
              ),
          ],
        ),
      ),
    );
  }
}

/// Square album art, falling back to a music glyph while it resolves.
class _Artwork extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;
  const _Artwork({required this.url, required this.size, this.radius = 12});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? const ColoredBox(
                color: Color(0xFF232734),
                child: Icon(Icons.music_note, color: Colors.white38, size: 40),
              )
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                placeholder: (_, __) => const ColoredBox(
                  color: Color(0xFF232734),
                  child: Icon(Icons.music_note,
                      color: Colors.white38, size: 40),
                ),
                errorWidget: (_, __, ___) => const ColoredBox(
                  color: Color(0xFF232734),
                  child: Icon(Icons.music_note,
                      color: Colors.white38, size: 40),
                ),
              ),
      ),
    );
  }
}

class _CollapsedContent extends StatelessWidget {
  final NowPlayingService service;
  const _CollapsedContent({required this.service});

  @override
  Widget build(BuildContext context) {
    final n = service.now;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          _Artwork(url: service.artUrl, size: 114, radius: 14),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      n.isPlaying ? Icons.play_arrow : Icons.pause,
                      size: 20,
                      color: const Color(0xFF7FE3A1),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        n.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  n.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 19),
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: n.progress,
                    minHeight: 5,
                    backgroundColor: Colors.white24,
                    valueColor:
                        const AlwaysStoppedAnimation(Color(0xFF7FB6FF)),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${_fmt(n.position)} / ${_fmt(n.duration)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailContent extends StatelessWidget {
  final NowPlayingService service;
  const _DetailContent({required this.service});

  @override
  Widget build(BuildContext context) {
    final n = service.now;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 30, 40, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bluetooth_audio,
                  color: Color(0xFF7FB6FF), size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  n.deviceName.isEmpty ? 'Now playing' : n.deviceName,
                  style: const TextStyle(color: Colors.white70, fontSize: 22),
                ),
              ),
              const Icon(Icons.close_fullscreen,
                  color: Colors.white54, size: 28),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Artwork(url: service.artUrl, size: 330, radius: 20),
                const SizedBox(width: 36),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 44,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        n.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 28),
                      ),
                      if (n.album.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          n.album,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 22),
                        ),
                      ],
                      const SizedBox(height: 26),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: n.progress,
                          minHeight: 8,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation(
                              Color(0xFF7FB6FF)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(n.position),
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 18)),
                          Text(_fmt(n.duration),
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 18)),
                        ],
                      ),
                      const SizedBox(height: 22),
                      _Controls(service: service),
                      if (service.hasVolume) ...[
                        const SizedBox(height: 14),
                        _VolumeRow(service: service),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  final NowPlayingService service;
  const _Controls({required this.service});

  @override
  Widget build(BuildContext context) {
    final n = service.now;
    final accent = Theme.of(context).colorScheme.primary;

    IconData repeatIcon;
    switch (n.repeat) {
      case 'singletrack':
        repeatIcon = Icons.repeat_one;
        break;
      case 'alltracks':
      case 'group':
        repeatIcon = Icons.repeat;
        break;
      default:
        repeatIcon = Icons.repeat;
    }
    final repeatOn = n.repeat != 'off';

    return Row(
      children: [
        _RoundButton(
          icon: Icons.skip_previous,
          size: 66,
          onTap: service.previous,
        ),
        const SizedBox(width: 18),
        _RoundButton(
          icon: n.isPlaying ? Icons.pause : Icons.play_arrow,
          size: 86,
          filled: true,
          onTap: service.playPause,
        ),
        const SizedBox(width: 18),
        _RoundButton(icon: Icons.skip_next, size: 66, onTap: service.next),
        const Spacer(),
        _RoundButton(
          icon: repeatIcon,
          size: 58,
          active: repeatOn,
          activeColor: accent,
          onTap: service.cycleRepeat,
        ),
        const SizedBox(width: 12),
        _RoundButton(
          icon: Icons.shuffle,
          size: 58,
          active: n.shuffle,
          activeColor: accent,
          onTap: service.toggleShuffle,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool filled;
  final bool active;
  final Color? activeColor;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    required this.size,
    required this.onTap,
    this.filled = false,
    this.active = false,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final bg = filled
        ? Theme.of(context).colorScheme.primary
        : (active
            ? (activeColor ?? Colors.white).withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.10));
    final fg = active && !filled ? (activeColor ?? Colors.white) : Colors.white;
    return Material(
      color: bg,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: fg, size: size * 0.52),
        ),
      ),
    );
  }
}

/// Mute button plus a volume slider. Drives AVRCP absolute volume on the
/// Bluetooth transport, so it changes the level on the phone too.
class _VolumeRow extends StatelessWidget {
  final NowPlayingService service;
  const _VolumeRow({required this.service});

  IconData _icon(double v, bool muted) {
    if (muted) return Icons.volume_off;
    if (v < 0.02) return Icons.volume_mute;
    if (v < 0.5) return Icons.volume_down;
    return Icons.volume_up;
  }

  @override
  Widget build(BuildContext context) {
    final v = service.volume;
    final muted = service.muted;
    final accent = Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        _RoundButton(
          icon: _icon(v, muted),
          size: 58,
          active: muted,
          activeColor: const Color(0xFFFF8A8A),
          onTap: service.toggleMute,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 8,
              activeTrackColor: muted ? Colors.white24 : accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: muted ? Colors.white54 : accent,
              // Big thumb and overlay: this is driven by fingers.
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 15),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 28),
            ),
            child: Slider(
              value: v,
              onChanged: service.setVolume,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 62,
          child: Text(
            '${(v * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white70, fontSize: 20),
          ),
        ),
      ],
    );
  }
}
