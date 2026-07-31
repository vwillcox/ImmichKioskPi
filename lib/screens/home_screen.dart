import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/immich_models.dart';
import '../services/immich_service.dart';
import '../services/locked_folder_service.dart';
import '../widgets/remote_image.dart';
import 'album_screen.dart';
import 'locked_folder_screen.dart';
import 'pin_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ImmichService _immich = context.read<ImmichService>();
  List<Album>? _albums;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _albums = null;
      _error = null;
    });
    try {
      final a = await _immich.getAlbums();
      if (mounted) setState(() => _albums = a);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _openAlbum(Album album) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlbumScreen(album: album),
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
      appBar: AppBar(
        title: const Text('TabletPi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
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
      ),
      // The weather overlay is deliberately not shown here — it's for the
      // slideshow (photo-frame mode) only.
      body: _buildBody(),
    );
  }

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
                onPressed: _load,
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
      onRefresh: _load,
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
            onTap: () => _openAlbum(album),
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
  final VoidCallback onTap;
  const _AlbumTile({
    required this.album,
    required this.immich,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: album.thumbnailAssetId != null
                  ? RemoteImage(
                      url: immich.thumbUrl(album.thumbnailAssetId!),
                      fallbackUrl: immich.previewUrl(album.thumbnailAssetId!),
                      headers: immich.authHeaders,
                    )
                  : const ColoredBox(
                      color: Color(0xFF20232E),
                      child: Icon(Icons.photo_album_outlined,
                          size: 48, color: Colors.white30),
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
