import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/spotify_service.dart';

/// The panels reachable from the expanded now-playing player when Spotify is
/// the active source: which device is playing, what's coming up next, and
/// somewhere to start something new from.
///
/// All of these load when opened and never poll — see the note in
/// [SpotifyService] about how tightly these endpoints are rate-limited
/// compared to the player one.

const _panelBg = Color(0xFF1B1E27);

Widget _panelShell({
  required BuildContext context,
  required String title,
  required Widget child,
  double maxHeight = 620,
}) {
  return Dialog(
    backgroundColor: _panelBg,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 620, maxHeight: maxHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  iconSize: 28,
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Flexible(child: child),
          ],
        ),
      ),
    ),
  );
}

Widget _emptyNote(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 16)),
      ),
    );

Widget _loading() => const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );

/// Square artwork for a list row, falling back to a music glyph.
class _RowArt extends StatelessWidget {
  final String? url;
  const _RowArt({required this.url});

  @override
  Widget build(BuildContext context) {
    const size = 56.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? const ColoredBox(
                color: Color(0xFF2A2F3E),
                child: Icon(Icons.music_note, color: Colors.white38),
              )
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                placeholder: (context, _) => const ColoredBox(
                  color: Color(0xFF2A2F3E),
                ),
                errorWidget: (context, url, error) => const ColoredBox(
                  color: Color(0xFF2A2F3E),
                  child: Icon(Icons.music_note, color: Colors.white38),
                ),
              ),
      ),
    );
  }
}

// ---- Devices --------------------------------------------------------------

/// Move playback between the account's Spotify Connect devices — the kiosk
/// itself, a phone, a speaker — without reaching for the Spotify app.
class SpotifyDevicesDialog extends StatefulWidget {
  final SpotifyService service;
  const SpotifyDevicesDialog({super.key, required this.service});

  @override
  State<SpotifyDevicesDialog> createState() => _SpotifyDevicesDialogState();
}

class _SpotifyDevicesDialogState extends State<SpotifyDevicesDialog> {
  late final Future<List<SpotifyDevice>> _future = widget.service.loadDevices();

  IconData _iconFor(String type) => switch (type.toLowerCase()) {
        'computer' => Icons.computer,
        'smartphone' => Icons.smartphone,
        'tablet' => Icons.tablet,
        'tv' => Icons.tv,
        'castvideo' || 'castaudio' => Icons.cast,
        'avr' || 'stb' => Icons.speaker_group,
        _ => Icons.speaker,
      };

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return _panelShell(
      context: context,
      title: 'Play on',
      child: FutureBuilder<List<SpotifyDevice>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _loading();
          }
          final devices = snapshot.data ?? const [];
          if (devices.isEmpty) {
            return _emptyNote(
                'No Spotify devices found.\nOpen Spotify somewhere to wake one up.');
          }
          return ListView.separated(
            shrinkWrap: true,
            itemCount: devices.length,
            separatorBuilder: (context, _) =>
                const Divider(color: Colors.white12, height: 1),
            itemBuilder: (context, i) {
              final d = devices[i];
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                leading: Icon(_iconFor(d.type),
                    size: 30, color: d.isActive ? accent : Colors.white70),
                title: Text(
                  d.name,
                  style: TextStyle(
                    color: d.isActive ? accent : Colors.white,
                    fontSize: 19,
                    fontWeight: d.isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                subtitle: d.isActive
                    ? Text('Playing here',
                        style: TextStyle(color: accent, fontSize: 14))
                    : null,
                trailing: d.isActive
                    ? Icon(Icons.graphic_eq, color: accent)
                    : const Icon(Icons.chevron_right, color: Colors.white38),
                onTap: d.isActive
                    ? null
                    : () {
                        widget.service.transferPlayback(d.id);
                        Navigator.of(context).pop();
                      },
              );
            },
          );
        },
      ),
    );
  }
}

// ---- Queue ----------------------------------------------------------------

/// What's coming up next.
class SpotifyQueueDialog extends StatefulWidget {
  final SpotifyService service;
  const SpotifyQueueDialog({super.key, required this.service});

  @override
  State<SpotifyQueueDialog> createState() => _SpotifyQueueDialogState();
}

class _SpotifyQueueDialogState extends State<SpotifyQueueDialog> {
  late final Future<List<SpotifyItem>> _future = widget.service.loadQueue();

  @override
  Widget build(BuildContext context) {
    return _panelShell(
      context: context,
      title: 'Up next',
      child: FutureBuilder<List<SpotifyItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _loading();
          }
          final items = snapshot.data ?? const [];
          if (items.isEmpty) return _emptyNote('Nothing queued up');
          return ListView.separated(
            shrinkWrap: true,
            itemCount: items.length,
            separatorBuilder: (context, _) =>
                const Divider(color: Colors.white12, height: 1),
            itemBuilder: (context, i) {
              final item = items[i];
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                leading: _RowArt(url: item.artUrl),
                title: Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
                subtitle: Text(item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 15)),
              );
            },
          );
        },
      ),
    );
  }
}

// ---- Browse ---------------------------------------------------------------

/// Somewhere to start something from without picking up a phone: the
/// account's playlists, what was played recently, and its top tracks.
class SpotifyBrowseDialog extends StatelessWidget {
  final SpotifyService service;
  const SpotifyBrowseDialog({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: _panelShell(
        context: context,
        title: 'Play something',
        maxHeight: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              tabs: [
                Tab(text: 'Playlists'),
                Tab(text: 'Recent'),
                Tab(text: 'Top'),
              ],
            ),
            Flexible(
              child: TabBarView(
                children: [
                  _ItemList(
                    service: service,
                    load: service.loadPlaylistItems,
                    empty: 'No playlists',
                  ),
                  _ItemList(
                    service: service,
                    load: service.loadRecentlyPlayed,
                    empty: 'Nothing played recently.\n'
                        'If this stays empty, reconnect Spotify in Settings '
                        'to grant the extra permission.',
                  ),
                  _ItemList(
                    service: service,
                    load: service.loadTopTracks,
                    empty: 'No top tracks yet.\n'
                        'If this stays empty, reconnect Spotify in Settings '
                        'to grant the extra permission.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tab's worth of playable items. Loads when first built, so switching
/// to a tab is what triggers its request rather than opening the dialog.
class _ItemList extends StatefulWidget {
  final SpotifyService service;
  final Future<List<SpotifyItem>> Function() load;
  final String empty;
  const _ItemList({
    required this.service,
    required this.load,
    required this.empty,
  });

  @override
  State<_ItemList> createState() => _ItemListState();
}

class _ItemListState extends State<_ItemList>
    with AutomaticKeepAliveClientMixin {
  late final Future<List<SpotifyItem>> _future = widget.load();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<SpotifyItem>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return _loading();
        final items = snapshot.data ?? const [];
        if (items.isEmpty) return _emptyNote(widget.empty);
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (context, _) =>
              const Divider(color: Colors.white12, height: 1),
          itemBuilder: (context, i) {
            final item = items[i];
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              leading: _RowArt(url: item.artUrl),
              title: Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 18)),
              subtitle: item.subtitle.isEmpty
                  ? null
                  : Text(item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 15)),
              // Playing replaces what's on; queueing is the gentler option, so
              // it stays a separate explicit tap rather than the row default.
              trailing: item.isContext
                  ? null
                  : IconButton(
                      iconSize: 28,
                      tooltip: 'Add to queue',
                      icon: const Icon(Icons.queue_music,
                          color: Colors.white54),
                      onPressed: () {
                        widget.service.queue(item);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Queued ${item.title}')),
                        );
                      },
                    ),
              onTap: () {
                widget.service.play(item);
                Navigator.of(context).pop();
              },
            );
          },
        );
      },
    );
  }
}
