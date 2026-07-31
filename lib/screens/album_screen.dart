import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/immich_models.dart';
import '../services/config_service.dart';
import '../services/immich_service.dart';
import '../services/media_source.dart';
import '../widgets/remote_image.dart';
import 'gallery_screen.dart';
import 'slideshow_screen.dart';

class AlbumScreen extends StatefulWidget {
  final Album album;
  const AlbumScreen({super.key, required this.album});

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  late final ImmichService _immich = context.read<ImmichService>();
  List<Asset>? _assets;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _assets = null;
      _error = null;
    });
    try {
      final a = await _immich.getAlbumAssets(widget.album.id);
      if (mounted) setState(() => _assets = a);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _openAt(int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        assets: _assets!,
        initialIndex: index,
        source: _immich,
      ),
    ));
  }

  void _startSlideshow() {
    final images = _assets!.where((a) => a.isImage).toList();
    if (images.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No photos in this album for a slideshow')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SlideshowScreen(
        images: images,
        source: _immich,
        settings: context.read<ConfigService>().slideshow,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final assets = _assets;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.album.name),
        actions: [
          if (assets != null && assets.any((a) => a.isImage))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: _startSlideshow,
                icon: const Icon(Icons.slideshow),
                label: const Text('Slideshow'),
              ),
            ),
        ],
      ),
      body: _buildBody(assets),
    );
  }

  Widget _buildBody(List<Asset>? assets) {
    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _load);
    }
    if (assets == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (assets.isEmpty) {
      return const Center(
        child: Text('This album is empty',
            style: TextStyle(fontSize: 20, color: Colors.white60)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: assets.length,
      itemBuilder: (context, i) {
        final a = assets[i];
        return _AssetTile(
          asset: a,
          source: _immich,
          onTap: () => _openAt(i),
        );
      },
    );
  }
}

class _AssetTile extends StatelessWidget {
  final Asset asset;
  final MediaSource source;
  final VoidCallback onTap;
  const _AssetTile({
    required this.asset,
    required this.source,
    required this.onTap,
  });

  String _dur(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RemoteImage(
              url: source.thumbUrl(asset.id),
              fallbackUrl: asset.isImage ? source.originalUrl(asset.id) : null,
              headers: source.authHeaders,
            ),
            if (asset.isVideo)
              Positioned.fill(
                child: Container(
                  alignment: Alignment.bottomRight,
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 20),
                      if (asset.duration != null) ...[
                        const SizedBox(width: 4),
                        Text(_dur(asset.duration!),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                      ],
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

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
