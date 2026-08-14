import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

/// Opens a web page in a browser window on top of the kiosk, with a close
/// button the kiosk itself owns.
///
/// Flutter has no Linux WebView, so the page is a real Chromium window rather
/// than something embedded. Chromium's own window controls on this compositor
/// are a few pixels tall and cannot be scaled — neither
/// `--force-device-scale-factor`, which only affects page rendering, nor
/// `GDK_SCALE`, which Ozone bypasses. So the window is deliberately sized
/// smaller than the screen; labwc centres it, and this route fills the margin
/// around it with a close button big enough to hit with a thumb.
///
/// The same technique the shared-link popup uses, factored out so the news
/// widget opens articles the same way.
class LinkViewerScreen extends StatefulWidget {
  const LinkViewerScreen({
    super.key,
    required this.url,
    this.title,
    this.timeout = const Duration(minutes: 5),
  });

  final String url;
  final String? title;

  /// Closes itself eventually. A kiosk left on an article is a kiosk showing
  /// an article tomorrow morning.
  final Duration timeout;

  @override
  State<LinkViewerScreen> createState() => _LinkViewerScreenState();
}

class _LinkViewerScreenState extends State<LinkViewerScreen> {
  static const String _kioskAppId = 'info.talktech.immichkioskpi';

  Process? _browser;
  Timer? _timer;
  String? _error;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _browser?.kill();
    super.dispose();
  }

  Future<void> _open() async {
    final screen = MediaQuery.sizeOf(context);
    final width = (screen.width * 0.82).round();
    final height = (screen.height * 0.74).round();

    final chromium = await Process.run('which', ['chromium']);
    if (chromium.exitCode != 0) {
      if (mounted) setState(() => _error = 'Chromium isn’t installed.');
      return;
    }
    try {
      final home = Platform.environment['HOME'];
      final proc = await Process.start('chromium', [
        '--app=${widget.url}',
        '--ozone-platform=wayland',
        '--password-store=basic',
        '--window-size=$width,$height',
        // Chromium is single-instance per profile: without one of its own it
        // would hand the URL to whatever window is already open and silently
        // ignore every flag here, leaving nothing to kill on the way out.
        if (home != null)
          '--user-data-dir=$home/.cache/immich_kiosk_pi/chromium-article-viewer',
      ]);
      if (!mounted) {
        proc.kill();
        return;
      }
      setState(() => _browser = proc);
      _timer = Timer(widget.timeout, _close);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open the page: $e');
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    _browser?.kill();
    _browser = null;
    try {
      await Process.run('wlrctl', ['toplevel', 'focus', 'app_id:$_kioskAppId']);
    } catch (_) {
      // wlrctl missing: killing the window is still enough to get back.
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title ?? widget.url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 18),
                    ),
                  ),
                  const SizedBox(width: 16),
                  FilledButton.icon(
                    onPressed: _close,
                    icon: const Icon(Icons.close, size: 30),
                    label: const Text('Close', style: TextStyle(fontSize: 22)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 30, vertical: 22),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: _error != null
                    ? Text(_error!,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 18))
                    : const Text(
                        'The page is open in front of this window.',
                        style:
                            TextStyle(color: Colors.white24, fontSize: 16),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
