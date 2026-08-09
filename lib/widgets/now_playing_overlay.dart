import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'burn_in_drift.dart';

import '../config/app_config.dart';
import '../services/config_service.dart';
import '../services/now_playing_service.dart';
import '../services/playback_source.dart';
import '../services/spotify_service.dart';

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

  /// Start already expanded to the full player rather than the small corner
  /// card. Used on the home screen — there's no slideshow to keep clear
  /// there, so if music is playing there's nothing better to show than the
  /// player itself; tapping it still shrinks to the corner like anywhere
  /// else, uncovering the album grid to go start a slideshow.
  final bool startExpanded;

  const NowPlayingOverlay({
    super.key,
    this.margin = const EdgeInsets.all(28),
    this.startExpanded = false,
  });

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

  /// Only set on the home screen (see [NowPlayingOverlay.startExpanded]) —
  /// shrinking there is meant as a brief "let me pick an album" detour, not
  /// a standing preference, so it pops back up on its own if nothing came of
  /// it within [_autoExpandDelay].
  Timer? _autoExpandTimer;
  static const Duration _autoExpandDelay = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    if (widget.startExpanded) _controller.value = 1;
    startDrift();
  }

  @override
  void dispose() {
    _autoExpandTimer?.cancel();
    stopDrift();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_expanded) {
      _controller.reverse();
      if (widget.startExpanded) {
        _autoExpandTimer?.cancel();
        _autoExpandTimer = Timer(_autoExpandDelay, () {
          if (mounted && !_expanded) _controller.forward();
        });
      }
    } else {
      _autoExpandTimer?.cancel();
      _controller.forward();
    }
  }

  static const Size _collapsedSize = Size(420, 150);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ConfigService>().config.nowPlaying;
    // Both sources are watched unconditionally so the overlay rebuilds
    // whichever one changes; Spotify wins whenever it has something to show,
    // since it's the richer of the two (real seek position, per-device
    // volume, high-res artwork) — the AVRCP source is the fallback for
    // whatever else the phone might be playing (a podcast app, YouTube Music)
    // that Spotify's API knows nothing about.
    final spotify = context.watch<SpotifyService>();
    final avrcp = context.watch<NowPlayingService>();
    final service = spotify.available ? spotify : avrcp;
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
                            // On the home screen there's no photo worth
                            // seeing through it, so go fully opaque and hide
                            // the album grid outright; over the slideshow,
                            // dim rather than blot out the photo entirely.
                            color: Colors.black
                                .withValues(alpha: (widget.startExpanded ? 1.0 : 0.6) * v),
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
    // Over the slideshow, cap the height so the card hugs its content rather
    // than leaving a lot of empty space above and below on a 1200px-tall
    // panel and blotting out more of the photo than it needs to. On the home
    // screen there's a solid black backdrop behind it instead of a photo, so
    // it's free to grow to fill almost the whole screen.
    final maxWidth = widget.startExpanded ? 2400.0 : 1400.0;
    final maxHeight = widget.startExpanded ? 1400.0 : 620.0;
    final width = (screen.width - inset * 2).clamp(0.0, maxWidth);
    final height = (screen.height - inset * 2).clamp(0.0, maxHeight);
    return Rect.fromLTWH((screen.width - width) / 2,
        (screen.height - height) / 2, width, height);
  }
}

class _Panel extends StatelessWidget {
  final PlaybackSource service;
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
            if (detailOpacity > 0)
              Opacity(
                opacity: detailOpacity,
                child: _ArtworkBackdrop(url: service.artUrl),
              ),
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

/// The current track's art, blown up behind the expanded player and blurred
/// so it stays a backdrop rather than competing with the sharp square
/// artwork already shown in the content on top. Fades to solid black by
/// halfway down so the title/controls always sit on a plain, readable
/// background rather than on top of the image itself.
class _ArtworkBackdrop extends StatelessWidget {
  final String? url;
  const _ArtworkBackdrop({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url == null) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: CachedNetworkImage(
            imageUrl: url!,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.1),
                Colors.black,
              ],
              stops: const [0.0, 0.9],
            ),
          ),
        ),
      ],
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
  final PlaybackSource service;
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
  final PlaybackSource service;
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
              Icon(service.sourceIcon, color: const Color(0xFF7FB6FF), size: 26),
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
                      _ProgressBar(service: service),
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
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Its own full-width bar rather than squeezed into the text
          // column: bigger buttons, spread out, so they're quick and
          // forgiving to hit on a touchscreen rather than needing precision.
          const SizedBox(height: 24),
          _Controls(service: service),
          if (service.hasVolume) ...[
            const SizedBox(height: 16),
            _VolumeRow(service: service),
          ],
        ],
      ),
    );
  }
}

/// The track's progress bar. Becomes a draggable seek slider when the source
/// supports it (Spotify); otherwise it's the plain display-only bar AVRCP has
/// always had, since BlueZ's MediaPlayer1 has no absolute-seek method to
/// back a drag gesture with.
class _ProgressBar extends StatefulWidget {
  final PlaybackSource service;
  const _ProgressBar({required this.service});

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  // While dragging, show the finger's own position rather than fighting with
  // live updates from the poller; only commit the seek on release.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final n = widget.service.now;

    if (!widget.service.canSeek) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: n.progress,
          minHeight: 8,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation(Color(0xFF7FB6FF)),
        ),
      );
    }

    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 10,
        activeTrackColor: const Color(0xFF7FB6FF),
        inactiveTrackColor: Colors.white24,
        thumbColor: const Color(0xFF7FB6FF),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 16),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 30),
      ),
      child: Slider(
        value: (_dragValue ?? n.progress).clamp(0.0, 1.0),
        onChanged: (v) => setState(() => _dragValue = v),
        onChangeEnd: (v) {
          widget.service.seek(n.duration * v);
          setState(() => _dragValue = null);
        },
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  final PlaybackSource service;
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

    // A full-width bar rather than packed to one side, with bigger buttons
    // throughout — this is meant to be hit quickly without looking, not
    // aimed at precisely.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(
          icon: Icons.skip_previous,
          size: 88,
          onTap: service.previous,
        ),
        const SizedBox(width: 22),
        _RoundButton(
          icon: n.isPlaying ? Icons.pause : Icons.play_arrow,
          size: 116,
          filled: true,
          onTap: service.playPause,
        ),
        const SizedBox(width: 22),
        _RoundButton(icon: Icons.skip_next, size: 88, onTap: service.next),
        const SizedBox(width: 48),
        _RoundButton(
          icon: repeatIcon,
          size: 76,
          active: repeatOn,
          activeColor: accent,
          onTap: service.cycleRepeat,
        ),
        const SizedBox(width: 16),
        _RoundButton(
          icon: Icons.shuffle,
          size: 76,
          active: n.shuffle,
          activeColor: accent,
          onTap: service.toggleShuffle,
        ),
        if (service.canLike) ...[
          const SizedBox(width: 16),
          _RoundButton(
            icon: service.isLiked ? Icons.favorite : Icons.favorite_border,
            size: 76,
            active: service.isLiked,
            activeColor: const Color(0xFFFF6B81),
            onTap: service.toggleLike,
          ),
        ],
        if (service.canAddToPlaylist) ...[
          const SizedBox(width: 16),
          _RoundButton(
            icon: Icons.playlist_add,
            size: 76,
            onTap: () => showDialog(
              context: context,
              builder: (_) => _PlaylistPickerDialog(service: service),
            ),
          ),
        ],
      ],
    );
  }
}

/// Lets the user add the current track to one of their Spotify playlists.
/// Loads the list lazily when opened; tapping a playlist adds the track and
/// closes the dialog immediately, matching the fire-and-forget feedback the
/// rest of the transport controls already use.
class _PlaylistPickerDialog extends StatefulWidget {
  final PlaybackSource service;
  const _PlaylistPickerDialog({required this.service});

  @override
  State<_PlaylistPickerDialog> createState() => _PlaylistPickerDialogState();
}

class _PlaylistPickerDialogState extends State<_PlaylistPickerDialog> {
  late final Future<List<PlaylistInfo>> _future = widget.service.loadPlaylists();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B1E27),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Add to playlist',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Flexible(
                child: FutureBuilder<List<PlaylistInfo>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        ),
                      );
                    }
                    final playlists = snapshot.data ?? const [];
                    if (playlists.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: Text('No playlists found',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 16)),
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: playlists.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: Colors.white12, height: 1),
                      itemBuilder: (context, i) {
                        final p = playlists[i];
                        return ListTile(
                          title: Text(
                            p.name,
                            style:
                                const TextStyle(color: Colors.white, fontSize: 18),
                          ),
                          onTap: () {
                            widget.service.addToPlaylist(p.id);
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
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

/// Mute button plus a volume slider. For AVRCP this drives absolute volume on
/// the Bluetooth transport (so it changes the level on the phone too); for
/// Spotify it drives the active Spotify Connect device's own volume — a
/// different knob from the phone's Bluetooth volume, only shown when that
/// device reports it supports remote volume at all.
class _VolumeRow extends StatelessWidget {
  final PlaybackSource service;
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
          size: 72,
          active: muted,
          activeColor: const Color(0xFFFF8A8A),
          onTap: service.toggleMute,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 10,
              activeTrackColor: muted ? Colors.white24 : accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: muted ? Colors.white54 : accent,
              // Big thumb and overlay: this is driven by fingers.
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 18),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 32),
            ),
            child: Slider(
              value: v,
              onChanged: service.setVolume,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 70,
          child: Text(
            '${(v * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white70, fontSize: 22),
          ),
        ),
      ],
    );
  }
}
