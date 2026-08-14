import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/now_playing_service.dart';
import '../../services/playback_source.dart';
import '../../services/spotify_service.dart';
import '../../widgets/remote_image.dart';
import '../widget_registry.dart';

/// What's playing, with transport controls.
///
/// Watches both sources the app knows about and shows whichever has
/// something, exactly as the corner overlay does: Spotify when it is active,
/// the phone over Bluetooth otherwise.
class DashboardSpotifyWidget extends StatelessWidget {
  const DashboardSpotifyWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final spotify = context.watch<SpotifyService>();
    final avrcp = context.watch<NowPlayingService>();
    final PlaybackSource source = spotify.available ? spotify : avrcp;

    if (!source.available || !source.now.hasTrack) {
      return Center(
        child: Text(
          'Nothing playing',
          style: TextStyle(color: t.textSecondary, fontSize: 16),
        ),
      );
    }

    final now = source.now;
    final art = source.artUrl;
    final showArt = w.option('showArtwork', true);
    final showControls = w.option('showControls', true);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showArt && art != null) ...[
          LayoutBuilder(
            builder: (context, c) {
              final side = c.maxHeight.clamp(0.0, 160.0);
              return ClipRRect(
                borderRadius: BorderRadius.circular(t.cornerRadius * 0.5),
                child: SizedBox(
                  width: side,
                  height: side,
                  child: RemoteImage(
                    url: art,
                    headers: const {},
                    fit: BoxFit.cover,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                now.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                now.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.textSecondary, fontSize: 15),
              ),
              if (now.duration > Duration.zero) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (now.position.inMilliseconds /
                            now.duration.inMilliseconds)
                        .clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: t.textSecondary.withValues(alpha: 0.25),
                    valueColor: AlwaysStoppedAnimation(t.accent),
                  ),
                ),
              ],
              if (showControls) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    _Button(
                      icon: Icons.skip_previous,
                      colour: t.textSecondary,
                      onPressed: source.previous,
                    ),
                    _Button(
                      icon: now.status == 'playing'
                          ? Icons.pause_circle
                          : Icons.play_circle,
                      colour: t.accent,
                      size: 38,
                      onPressed: source.playPause,
                    ),
                    _Button(
                      icon: Icons.skip_next,
                      colour: t.textSecondary,
                      onPressed: source.next,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.icon,
    required this.colour,
    required this.onPressed,
    this.size = 30,
  });

  final IconData icon;
  final Color colour;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: colour, size: size),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
      );
}

final spotifyWidgetType = DashboardWidgetType(
  type: 'spotify',
  name: 'Now playing',
  description:
      'The current track with transport controls. Shows Spotify when it is '
      'active, otherwise the phone over Bluetooth.',
  glyph: '🎵',
  defaultWidth: 5,
  defaultHeight: 2,
  minWidth: 3,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'showArtwork',
      label: 'Show artwork',
      kind: OptionKind.boolean,
      defaultValue: true,
    ),
    WidgetOption(
      key: 'showControls',
      label: 'Show transport controls',
      kind: OptionKind.boolean,
      defaultValue: true,
      help: 'Turn off for a display-only panel nobody can skip tracks on.',
    ),
  ],
  build: (context, w) => DashboardSpotifyWidget(w: w),
);
