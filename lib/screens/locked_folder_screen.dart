import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/immich_models.dart';
import '../services/locked_folder_service.dart';
import '../services/media_source.dart';
import '../widgets/remote_image.dart';
import 'gallery_screen.dart';

/// Shows the assets in Immich's server-side Locked Folder. Assumes the session
/// is already unlocked (navigated here after a successful PIN unlock). Re-locks
/// when the screen is popped.
class LockedFolderScreen extends StatefulWidget {
  const LockedFolderScreen({super.key});

  @override
  State<LockedFolderScreen> createState() => _LockedFolderScreenState();
}

class _LockedFolderScreenState extends State<LockedFolderScreen> {
  late final LockedFolderService _locked = context.read<LockedFolderService>();
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
      final a = await _locked.getLockedAssets();
      if (mounted) setState(() => _assets = a);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _relockAndLeave() async {
    await _locked.lock();
  }

  Future<void> _openAt(int index) async {
    await _locked.ensureElevated();
    final source = _locked.mediaSource;
    if (source == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GalleryScreen(
        assets: _assets!,
        initialIndex: index,
        source: source,
        onBeforeVideo: _locked.ensureElevated,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final source = _locked.mediaSource;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) => _relockAndLeave(),
      child: Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.lock, size: 22),
              SizedBox(width: 10),
              Text('Locked Folder'),
            ],
          ),
        ),
        body: _buildBody(source),
      ),
    );
  }

  Widget _buildBody(MediaSource? source) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.white54),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
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
    final assets = _assets;
    if (assets == null || source == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (assets.isEmpty) {
      return const Center(
        child: Text('The Locked Folder is empty',
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
        return GestureDetector(
          onTap: () => _openAt(i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RemoteImage(
                  url: source.thumbUrl(a.id),
                  fallbackUrl: a.isImage ? source.originalUrl(a.id) : null,
                  headers: source.authHeaders,
                ),
                if (a.isVideo)
                  const Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 22),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
