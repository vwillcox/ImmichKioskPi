import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/kiosk_browser.dart';
import '../widgets/incoming_share_overlay.dart' show kBrowserCloseGutter;

/// Opens a web page in a browser window on top of the kiosk, with a close
/// button the kiosk itself owns.
///
/// Flutter has no Linux WebView, so the page is a real browser window rather
/// than something embedded, and neither browser gives a close control worth
/// using here: Chromium's app-mode one is a few pixels tall and cannot be
/// scaled (`--force-device-scale-factor` only affects page rendering, and
/// Ozone bypasses `GDK_SCALE`), while Firefox's `--kiosk` takes the whole
/// screen. So the window stops short of the bottom of the screen and this
/// route fills the strip beneath it with a button big enough for a thumb.
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

    if (await KioskBrowser.resolve() == null) {
      if (mounted) {
        setState(() => _error = 'No browser is installed on this device.');
      }
      return;
    }

    final proc = await KioskBrowser.open(
      widget.url,
      profile: 'article-viewer',
      screen: screen,
      bottomGutter: kBrowserCloseGutter,
      chromeless: true,
    );
    if (proc == null) {
      if (mounted) setState(() => _error = 'Could not open the page.');
      return;
    }
    if (!mounted) {
      proc.kill();
      return;
    }
    setState(() => _browser = proc);
    _timer = Timer(widget.timeout, _close);
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
