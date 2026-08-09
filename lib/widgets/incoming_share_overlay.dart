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
  /// This overlay sits as a *sibling* of the app's own Navigator — both are
  /// children of the Stack in main.dart's `MaterialApp.builder`, precisely
  /// so it can show up over any screen — which means `Navigator.of(context)`
  /// from inside it can't find that Navigator by walking up the tree; it's
  /// not an ancestor. A global key to the same Navigator sidesteps that.
  final GlobalKey<NavigatorState> navigatorKey;

  const IncomingShareOverlay({super.key, required this.navigatorKey});

  @override
  State<IncomingShareOverlay> createState() => _IncomingShareOverlayState();
}

class _IncomingShareOverlayState extends State<IncomingShareOverlay>
    with BurnInDriftMixin {
  static const Size _size = Size(400, 120);
  static const EdgeInsets _margin = EdgeInsets.all(28);

  /// How long a shared web page stays open in Chromium before the kiosk
  /// takes its own focus back and closes it — a safety net for whenever the
  /// close button below isn't used.
  static const Duration _webViewTimeout = Duration(minutes: 2);
  static const String _kioskAppId = 'info.talktech.immichkioskpi';

  /// The open link-viewer's process, if any — kept so the close button and
  /// the timeout can both actually end the same one.
  Process? _browserProc;
  Timer? _webViewTimer;

  @override
  void initState() {
    super.initState();
    startDrift();
  }

  @override
  void dispose() {
    stopDrift();
    _webViewTimer?.cancel();
    super.dispose();
  }

  Future<void> _open(ShareInboxService service, SharedItem item) async {
    service.dequeue();
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    switch (item.type) {
      case ShareType.image:
      case ShareType.gif:
        await navigator.push(MaterialPageRoute(
          builder: (_) =>
              SharedImageScreen(path: item.localPath!, sender: item.sender),
        ));
      case ShareType.video:
        await navigator.push(MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            asset: Asset(
                id: 'shared',
                type: AssetType.video,
                fileName: item.localPath!.split('/').last),
            source: LocalFileMediaSource(item.localPath!),
          ),
        ));
      case ShareType.text:
        await navigator.push(MaterialPageRoute(
          builder: (_) =>
              SharedTextScreen(text: item.content!, sender: item.sender),
        ));
      case ShareType.link:
        await _openLink(item.content!);
    }
  }

  /// Chromium's own app-mode title bar draws its own close button rather
  /// than getting one from a window manager — and on this bare Wayland/Ozone
  /// setup that button turns out not to be resizable at all (neither
  /// `--force-device-scale-factor`, which only touches Chromium's own page
  /// rendering, nor `GDK_SCALE`, which Ozone bypasses entirely since it
  /// isn't going through GTK, has any effect on it). Rather than fight
  /// that, the window is sized smaller than the screen — labwc centers it,
  /// leaving the kiosk visible (and tappable) in the margin — and a real,
  /// large close button lives there instead, part of the kiosk's own UI.
  Future<void> _openLink(String url) async {
    // Read before any `await` — using BuildContext after one risks the
    // widget having been unmounted in the meantime.
    final screen = MediaQuery.sizeOf(context);
    final windowWidth = (screen.width * 0.82).round();
    final windowHeight = (screen.height * 0.78).round();

    final chromium = await Process.run('which', ['chromium']);
    if (chromium.exitCode != 0) {
      debugPrint('IncomingShareOverlay: chromium not found, cannot open $url');
      return;
    }
    Process? proc;
    try {
      final home = Platform.environment['HOME'];
      proc = await Process.start('chromium', [
        '--app=$url',
        '--ozone-platform=wayland',
        '--password-store=basic',
        '--window-size=$windowWidth,$windowHeight',
        // Chromium is single-instance per profile: without its own
        // profile, this would just hand the URL to whatever chromium
        // window already happens to be open (e.g. the one Spotify login
        // uses) instead of starting fresh — silently ignoring every flag
        // here, and leaving nothing to actually kill on close/timeout.
        if (home != null)
          '--user-data-dir=$home/.cache/immich_kiosk_pi/chromium-share-viewer',
      ]);
    } catch (e) {
      debugPrint('IncomingShareOverlay: could not open browser: $e');
      return;
    }
    setState(() => _browserProc = proc);
    _webViewTimer = Timer(_webViewTimeout, _closeLinkViewer);
  }

  Future<void> _closeLinkViewer() async {
    _webViewTimer?.cancel();
    _webViewTimer = null;
    final proc = _browserProc;
    if (proc == null) return;
    setState(() => _browserProc = null);
    try {
      await Process.run('wlrctl', ['toplevel', 'focus', 'app_id:$_kioskAppId']);
    } catch (_) {
      // wlrctl not installed — the close below still ends the page; the
      // user can switch back by touch same as for any other window.
    }
    proc.kill();
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
    final linkOpen = _browserProc != null;
    if (item == null && !linkOpen) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screen = Size(constraints.maxWidth, constraints.maxHeight);
            final rect = applyDrift(_cardRect(screen), screen);
            return Stack(
              children: [
                if (item != null)
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
                // The shared page's own window is sized smaller than the
                // screen precisely so this stays visible (and tappable)
                // in the margin around it — see _openLink.
                if (linkOpen)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 28,
                    child: Center(
                      child: _CloseLinkButton(onTap: _closeLinkViewer),
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

/// A large, unmissable "close the shared page" button, shown in the margin
/// left visible around the intentionally-undersized Chromium window (see
/// [_IncomingShareOverlayState._openLink]) — real and reliably tappable,
/// unlike Chromium's own tiny app-mode close button on this setup.
class _CloseLinkButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseLinkButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFB3261E),
      borderRadius: BorderRadius.circular(32),
      elevation: 6,
      child: InkWell(
        borderRadius: BorderRadius.circular(32),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 32, vertical: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close, color: Colors.white, size: 28),
              SizedBox(width: 10),
              Text(
                'Close shared page',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
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
