import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/immich_models.dart';
import '../services/immich_service.dart';
import '../services/config_service.dart';
import '../services/locked_folder_service.dart';
import '../widgets/remote_image.dart';
import 'album_screen.dart';
import 'locked_folder_screen.dart';
import 'pin_screen.dart';
import 'settings_screen.dart';
import 'slideshow_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ImmichService _immich = context.read<ImmichService>();
  List<Album>? _albums;
  String? _error;

  /// Ids of albums picked for a combined slideshow. Non-empty = selection mode.
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  /// Whether the VIDAA TV remote app is currently running, so the "TV Remote"
  /// button is only shown when it can actually flip to it.
  bool _remoteRunning = false;
  Timer? _remotePoll;
  static const String _remoteAppId = 'com.vwillcox.vidaa_remote';

  @override
  void initState() {
    super.initState();
    _loadFast();
    _checkRemote();
    _remotePoll =
        Timer.periodic(const Duration(seconds: 4), (_) => _checkRemote());
  }

  @override
  void dispose() {
    _remotePoll?.cancel();
    super.dispose();
  }

  /// Detect the remote's window via wlrctl; hide the button if wlrctl is
  /// missing or the remote isn't running.
  Future<void> _checkRemote() async {
    var running = false;
    try {
      final r = await Process.run('wlrctl', ['toplevel', 'list']);
      running = r.exitCode == 0 &&
          (r.stdout as String)
              .split('\n')
              .any((line) => line.startsWith('$_remoteAppId:'));
    } catch (_) {
      running = false;
    }
    if (mounted && running != _remoteRunning) {
      setState(() => _remoteRunning = running);
    }
  }

  /// Paint from the disk cache immediately (instant cold start), then refresh
  /// from the server in the background.
  Future<void> _loadFast() async {
    final cached = await _immich.getCachedAlbums();
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() => _albums = cached);
    }
    await _load(silent: cached != null && cached.isNotEmpty);
  }

  Future<void> _load({bool silent = false, bool force = false}) async {
    if (!silent) {
      setState(() {
        _albums = null;
        _error = null;
      });
    }
    try {
      final a = await _immich.getAlbums(forceRefresh: force);
      if (mounted) {
        setState(() {
          _albums = a;
          _error = null;
        });
      }
      // Warm every album cover into the disk cache in the background so the
      // whole grid is populated before it's scrolled.
      unawaited(_immich.warmAlbumCovers(a));
    } catch (e) {
      // Keep showing cached content if we have it; only surface a hard error
      // when there's nothing on screen.
      if (mounted && _albums == null) setState(() => _error = '$e');
    }
  }

  void _openAlbum(Album album) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlbumScreen(album: album),
    ));
  }

  // ---- Multi-select -----------------------------------------------------

  void _toggleSelect(Album album) {
    setState(() {
      if (!_selected.remove(album.id)) _selected.add(album.id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// Gather every photo from the selected albums into one slideshow.
  Future<void> _slideshowFromSelection() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final images = <Asset>[];
    final seen = <String>{};
    try {
      final results = await Future.wait(
        ids.map((id) => _immich.getAlbumAssets(id)),
      );
      for (final assets in results) {
        for (final a in assets) {
          if (a.isImage && seen.add(a.id)) images.add(a);
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _snack('Could not load the selected albums: $e');
      }
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss loading

    if (images.isEmpty) {
      _snack('No photos in the selected albums');
      return;
    }
    final count = ids.length;
    _clearSelection();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SlideshowScreen(
        images: images,
        source: _immich,
        settings: context.read<ConfigService>().slideshow,
        title: '$count album${count == 1 ? '' : 's'}',
      ),
    ));
  }

  Future<void> _openLockedFolder() async {
    final locked = context.read<LockedFolderService>();
    final pin = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => const PinScreen(
        title: 'Locked Folder',
        subtitle: 'Enter your Immich Locked Folder PIN',
      ),
    ));
    if (pin == null || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final result = await locked.unlock(pin);
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss loading

    switch (result) {
      case UnlockResult.success:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const LockedFolderScreen(),
        ));
      case UnlockResult.wrongPin:
        _snack('Incorrect PIN');
      case UnlockResult.notConfigured:
        _snack('Locked Folder login is not configured');
      case UnlockResult.error:
        _snack('Could not sign in to Immich for the Locked Folder');
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectionMode ? _selectionAppBar() : _normalAppBar(),
      // The weather overlay is deliberately not shown here — it's for the
      // slideshow (photo-frame mode) only.
      body: _buildBody(),
    );
  }

  PreferredSizeWidget _normalAppBar() => AppBar(
        title: const Text('Immich Kiosk - Pi'),
        actions: [
          if (_remoteRunning)
            IconButton(
              icon: const Icon(Icons.settings_remote),
              tooltip: 'TV Remote',
              onPressed: () => Process.run('wlrctl',
                  ['toplevel', 'focus', 'app_id:$_remoteAppId']),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => _load(force: true),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SettingsScreen(),
            )),
          ),
          const SizedBox(width: 8),
        ],
      );

  PreferredSizeWidget _selectionAppBar() => AppBar(
        backgroundColor: const Color(0xFF1E2740),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel selection',
          onPressed: _clearSelection,
        ),
        title: Text('${_selected.length} selected'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _slideshowFromSelection,
              icon: const Icon(Icons.slideshow),
              label: const Text('Slideshow'),
            ),
          ),
        ],
      );

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.white54),
              const SizedBox(height: 12),
              const Text('Could not reach Immich',
                  style: TextStyle(fontSize: 20)),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _load(force: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final albums = _albums;
    if (albums == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final showLocked = context.watch<LockedFolderService>().canUse;
    final tileCount = albums.length + (showLocked ? 1 : 0);

    if (albums.isEmpty && !showLocked) {
      return const Center(child: Text('No albums found'));
    }

    return RefreshIndicator(
      onRefresh: () => _load(silent: true, force: true),
      child: GridView.builder(
        padding: const EdgeInsets.all(14),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 280,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          childAspectRatio: 0.85,
        ),
        itemCount: tileCount,
        itemBuilder: (context, i) {
          if (showLocked && i == 0) {
            return _LockedFolderTile(onTap: _openLockedFolder);
          }
          final album = albums[i - (showLocked ? 1 : 0)];
          return _AlbumTile(
            album: album,
            immich: _immich,
            selected: _selected.contains(album.id),
            selectionMode: _selectionMode,
            // In selection mode a tap toggles; otherwise it opens the album.
            onTap: () =>
                _selectionMode ? _toggleSelect(album) : _openAlbum(album),
            onLongPress: () => _toggleSelect(album),
          );
        },
      ),
    );
  }
}

class _LockedFolderTile extends StatelessWidget {
  final VoidCallback onTap;
  const _LockedFolderTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF2A2F3E),
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                    ],
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.lock, size: 56, color: Colors.white),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Locked Folder',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                  SizedBox(height: 2),
                  Text('PIN protected',
                      style: TextStyle(color: Colors.white54, fontSize: 14)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  final Album album;
  final ImmichService immich;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _AlbumTile({
    required this.album,
    required this.immich,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: selected
            ? BorderSide(color: accent, width: 3)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  album.thumbnailAssetId != null
                      ? RemoteImage(
                          url: immich.thumbUrl(album.thumbnailAssetId!),
                          fallbackUrl:
                              immich.previewUrl(album.thumbnailAssetId!),
                          headers: immich.authHeaders,
                        )
                      : const ColoredBox(
                          color: Color(0xFF20232E),
                          child: Icon(Icons.photo_album_outlined,
                              size: 48, color: Colors.white30),
                        ),
                  if (selected)
                    ColoredBox(color: accent.withValues(alpha: 0.28)),
                  if (selectionMode)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: AnimatedScale(
                        scale: selected ? 1.0 : 0.85,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          decoration: BoxDecoration(
                            color: selected ? accent : Colors.black54,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white70, width: 2),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            selected ? Icons.check : Icons.circle_outlined,
                            size: 22,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${album.assetCount} item${album.assetCount == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
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
