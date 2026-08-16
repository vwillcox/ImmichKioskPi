import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/immich_models.dart';
import '../../services/immich_service.dart';
import '../../widgets/remote_image.dart';
import '../widget_registry.dart';

/// Photos from Immich, either at random from the whole library or from one
/// album.
///
/// Its own widget rather than a corner of the slideshow: on a dashboard this
/// sits alongside the clock and the weather, and wants to change on a slow
/// timer rather than run as a show of its own.
class DashboardImmichWidget extends StatefulWidget {
  const DashboardImmichWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  State<DashboardImmichWidget> createState() => _DashboardImmichWidgetState();
}

class _DashboardImmichWidgetState extends State<DashboardImmichWidget> {
  final _rng = Random();

  List<Asset> _pool = const [];
  int _index = 0;
  Timer? _timer;
  bool _loading = true;
  String? _error;

  /// What the pool was fetched for. A changed source means the pool is stale
  /// however recently it was filled.
  String _fetchedFor = '';

  String get _source => widget.w.option('source', 'random');
  String get _albumId => widget.w.option('albumId', '');
  int get _everySeconds => widget.w.option('everySeconds', 60);

  String get _sourceKey => '$_source/$_albumId';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant DashboardImmichWidget old) {
    super.didUpdateWidget(old);
    // The editor can change the album or the interval under us.
    if (_sourceKey != _fetchedFor) unawaited(_load());
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    final seconds = _everySeconds;
    if (seconds <= 0) return;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) => _advance());
  }

  Future<void> _load() async {
    final key = _sourceKey;
    _fetchedFor = key;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final immich = context.read<ImmichService>();
      final assets = _source == 'album' && _albumId.isNotEmpty
          ? await immich.getAlbumAssets(_albumId)
          : await immich.getRandomAssets(count: 24);
      if (!mounted || _sourceKey != key) return;
      // Stills only. A video's poster frame would work, but the tile has no
      // way to play it and a frozen frame reads as a broken photo.
      final images = assets.where((a) => a.type == AssetType.image).toList();
      setState(() {
        _pool = images;
        _index = images.isEmpty ? 0 : _rng.nextInt(images.length);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _advance() {
    if (!mounted) return;
    if (_pool.length < 2) {
      // A random pool is worth refilling — the same twenty-four photos
      // forever is not really random. An album is not: it is the album.
      if (_source != 'album') unawaited(_load());
      return;
    }
    setState(() => _index = (_index + 1) % _pool.length);
    // Near the end of a random pool, quietly fetch another.
    if (_source != 'album' && _index == _pool.length - 1) {
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.w.theme;
    final fit = widget.w.option('fill', true) ? BoxFit.cover : BoxFit.contain;
    final showCaption = widget.w.option('caption', false);

    if (_loading && _pool.isEmpty) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: t.textSecondary),
        ),
      );
    }

    if (_error != null && _pool.isEmpty) {
      return Center(
        child: Text(
          'Could not reach Immich',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textSecondary, fontSize: 14),
        ),
      );
    }

    if (_pool.isEmpty) {
      return Center(
        child: Text(
          _source == 'album' && _albumId.isEmpty
              ? 'Pick an album in the widget settings'
              : 'No photos to show',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textSecondary, fontSize: 14),
        ),
      );
    }

    final asset = _pool[_index];
    // ImmichService is itself the x-api-key MediaSource, which is what normal
    // browsing uses; the Locked Folder's session-token one is deliberately not
    // reachable from a dashboard tile.
    final media = context.read<ImmichService>();

    return GestureDetector(
      // Tap for the next photo, so the tile is not only a timer.
      onTap: _advance,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Keyed by asset so a change cross-fades rather than swapping the
          // image inside one element, which flickers.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: RemoteImage(
              key: ValueKey(asset.id),
              url: media.previewUrl(asset.id),
              fallbackUrl: media.originalUrl(asset.id),
              headers: media.authHeaders,
              fit: fit,
            ),
          ),
          if (showCaption && (asset.fileName ?? '').isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.65),
                    ],
                  ),
                ),
                child: Text(
                  asset.fileName ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final immichWidgetType = DashboardWidgetType(
  type: 'immich',
  name: 'Photo',
  description:
      'A photo from your Immich server — at random from the whole library, or '
      'from one album. Changes on a timer, and on a tap.',
  glyph: '🖼️',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 2,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'source',
      label: 'Photos from',
      kind: OptionKind.choice,
      defaultValue: 'random',
      choices: {
        'random': 'Anywhere in the library',
        'album': 'One album',
      },
    ),
    WidgetOption(
      key: 'albumId',
      label: 'Album',
      kind: OptionKind.choice,
      defaultValue: '',
      // Filled by the kiosk: which albums exist is the server's business.
      choicesFrom: 'albums',
      help: 'Only used when the source above is set to one album.',
    ),
    WidgetOption(
      key: 'everySeconds',
      label: 'Change every (seconds)',
      kind: OptionKind.number,
      defaultValue: 60,
      help: '0 to hold one photo until tapped.',
    ),
    WidgetOption(
      key: 'fill',
      label: 'Fill the tile',
      kind: OptionKind.boolean,
      defaultValue: true,
      help: 'Off fits the whole photo inside the tile instead, letterboxed.',
    ),
    WidgetOption(
      key: 'caption',
      label: 'Show the file name',
      kind: OptionKind.boolean,
      defaultValue: false,
    ),
  ],
  preview: const [
    PreviewLine('🖼', scale: 0.42, centre: true),
    PreviewLine('Photo', scale: 0.10, muted: true, centre: true),
  ],
  build: (context, w) => DashboardImmichWidget(w: w),
);
