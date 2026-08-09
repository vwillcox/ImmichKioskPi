import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'burn_in_drift.dart';
import '../models/immich_models.dart';
import '../screens/shared_image_screen.dart';
import '../screens/shared_text_screen.dart';
import '../screens/video_player_screen.dart';
import '../services/local_file_media_source.dart';
import '../services/share_inbox_service.dart';

/// A small corner notification whenever something new has been shared to
/// the kiosk. Placed once, globally, in `main.dart`'s `MaterialApp.builder`
/// so it can pop up over *any* screen — settings, a slideshow, a video —
/// rather than only the couple of screens the now-playing overlay lives in.
///
/// Unlike the now-playing overlay, there's no in-place expanded state:
/// tapping the card navigates straight to whatever viewer suits the content
/// (or, for a web link, out to Chromium), since that's a different screen
/// entirely rather than a bigger version of this one.
class IncomingShareOverlay extends StatefulWidget {
  const IncomingShareOverlay({super.key});

  @override
  State<IncomingShareOverlay> createState() => _IncomingShareOverlayState();
}

class _IncomingShareOverlayState extends State<IncomingShareOverlay>
    with BurnInDriftMixin {
  static const Size _size = Size(400, 120);
  static const EdgeInsets _margin = EdgeInsets.all(28);

  /// How long a shared web page stays open in Chromium before the kiosk
  /// takes its own focus back — there's no keyboard or window chrome on this
  /// bare labwc session for the user to close it with otherwise.
  static const Duration _webViewTimeout = Duration(seconds: 60);
  static const String _kioskAppId = 'info.talktech.immichkioskpi';

  @override
  void initState() {
    super.initState();
    startDrift();
  }

  @override
  void dispose() {
    stopDrift();
    super.dispose();
  }

  Future<void> _open(ShareInboxService service, SharedItem item) async {
    service.dequeue();
    switch (item.type) {
      case ShareType.image:
      case ShareType.gif:
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              SharedImageScreen(path: item.localPath!, sender: item.sender),
        ));
      case ShareType.video:
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            asset: Asset(
                id: 'shared',
                type: AssetType.video,
                fileName: item.localPath!.split('/').last),
            source: LocalFileMediaSource(item.localPath!),
          ),
        ));
      case ShareType.text:
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              SharedTextScreen(text: item.content!, sender: item.sender),
        ));
      case ShareType.link:
        await _openLink(item.content!);
    }
  }

  Future<void> _openLink(String url) async {
    final chromium = await Process.run('which', ['chromium']);
    if (chromium.exitCode != 0) {
      debugPrint('IncomingShareOverlay: chromium not found, cannot open $url');
      return;
    }
    Process? proc;
    try {
      proc = await Process.start('chromium', [
        '--app=$url',
        '--ozone-platform=wayland',
        '--password-store=basic',
      ]);
    } catch (e) {
      debugPrint('IncomingShareOverlay: could not open browser: $e');
      return;
    }
    Timer(_webViewTimeout, () async {
      try {
        await Process.run(
            'wlrctl', ['toplevel', 'focus', 'app_id:$_kioskAppId']);
      } catch (_) {
        // wlrctl not installed — nothing more to do, the user can switch
        // back by touch same as they would for any other window.
      }
      proc?.kill();
    });
  }

  Rect _cardRect(Size screen) {
    final left = screen.width - _size.width - _margin.right;
    final top = screen.height - _size.height - _margin.bottom;
    return Rect.fromLTWH(left, top, _size.width, _size.height);
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ShareInboxService>();
    final item = service.current;
    if (item == null) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screen = Size(constraints.maxWidth, constraints.maxHeight);
            final rect = applyDrift(_cardRect(screen), screen);
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey(item),
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, (1 - t) * 16),
                        child: child,
                      ),
                    ),
                    child: _Card(
                      item: item,
                      pendingCount: service.pendingCount,
                      onTap: () => _open(service, item),
                      onDismiss: service.dequeue,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final SharedItem item;
  final int pendingCount;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _Card({
    required this.item,
    required this.pendingCount,
    required this.onTap,
    required this.onDismiss,
  });

  IconData get _icon => switch (item.type) {
        ShareType.image => Icons.image,
        ShareType.gif => Icons.gif_box,
        ShareType.video => Icons.movie,
        ShareType.link => Icons.link,
        ShareType.text => Icons.notes,
      };

  String get _label => switch (item.type) {
        ShareType.image => 'Photo shared',
        ShareType.gif => 'GIF shared',
        ShareType.video => 'Video shared',
        ShareType.link => 'Link shared',
        ShareType.text => 'Note shared',
      };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 18,
                spreadRadius: 2,
              ),
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2F3E),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(_icon, color: const Color(0xFF7FB6FF), size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      'From ${item.sender}${pendingCount > 1 ? ' · +${pendingCount - 1} more' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 22),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
