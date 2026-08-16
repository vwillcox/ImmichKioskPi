import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../dashboard/dashboard_fonts.dart';
import '../dashboard/dashboard_model.dart';
import '../dashboard/dashboard_theme.dart';
import '../dashboard/live_preview.dart';
import '../config/app_config.dart' show SenderToken;
import '../dashboard/widget_registry.dart';
import 'config_service.dart';

/// Hosts the dashboard's web editor and the small API behind it.
///
/// The editor is a browser page rather than a screen on the kiosk because
/// arranging a grid on a wall-mounted touchscreen with no keyboard is
/// miserable, and the phone you would use instead is already in your hand.
///
/// Everything the editor needs to draw itself — the widget palette, each
/// type's settings form, the theme list — is served from the registry rather
/// than written into the page. That is what makes a new widget or theme show
/// up in the browser without the editor being touched.
class DashboardService extends ChangeNotifier {
  DashboardService(
    this._config, {
    PreviewData Function()? previewData,
    Future<Map<String, String>> Function()? albums,
  })  : _previewData = previewData,
        _albums = albums,
        themes = ThemeRepository(ThemeRepository.defaultDirectory());

  final ConfigService _config;

  /// The albums on the Immich server, id to name, for options that let you
  /// pick one. A function rather than a list because which albums exist is
  /// the server's business and changes without this app restarting.
  final Future<Map<String, String>> Function()? _albums;

  /// Read fresh each time rather than held, so the editor's preview shows the
  /// weather and the track as they are now, not as they were at startup.
  final PreviewData Function()? _previewData;
  final ThemeRepository themes;

  HttpServer? _server;
  String? _editorHtml;

  DashboardSettings get settings => _config.config.dashboard;

  /// Where to point a browser. The host's own address is resolved once so the
  /// kiosk can show something you can actually type in, rather than
  /// "localhost", which is useless from the sofa.
  String _host = 'this device';
  String get editorAddress => 'http://$_host:${settings.editorPort}';

  Future<void> start() async {
    await themes.load();
    _host = await _localAddress();
    await _bind();
  }

  /// Rebinds when the port changes; otherwise leaves a working server alone.
  Future<void> refreshFromSettings() async {
    if (_server != null && _server!.port == settings.editorPort) {
      if (!settings.enabled) await _stop();
      return;
    }
    await _bind();
  }

  Future<void> _stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _bind() async {
    await _stop();
    if (!settings.enabled) return;
    try {
      _server = await HttpServer.bind(
          InternetAddress.anyIPv4, settings.editorPort, shared: true);
      debugPrint('Dashboard editor on :${settings.editorPort}');
      _server!.listen(_handle, onError: (Object e) {
        debugPrint('Dashboard: server error: $e');
      });
    } catch (e) {
      debugPrint('Dashboard: could not bind ${settings.editorPort}: $e');
    }
  }

  /// Interfaces that exist but are no use to a browser on the sofa. This Pi
  /// runs Docker, whose bridge answers first and would otherwise be shown on
  /// screen as the address to type.
  static final RegExp _virtualInterface =
      RegExp(r'^(docker|br-|veth|virbr|tun|tap|vmnet|zt)');

  /// The address to type into a browser on the same network.
  static Future<String> _localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final real = interfaces
          .where((i) => !_virtualInterface.hasMatch(i.name))
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .toList();
      // A home network address before anything else — a container or VPN
      // subnet may be perfectly real and still unreachable from the sofa.
      //
      // Written as two checks rather than firstWhere with a fallback because
      // newer SDKs narrow this list to InterfaceAddress, and an orElse
      // returning a plain InternetAddress no longer type-checks there.
      final home = real.where(
          (a) => a.address.startsWith('192.168.') || a.address.startsWith('10.'));
      if (home.isNotEmpty) return home.first.address;
      if (real.isNotEmpty) return real.first.address;
    } catch (e) {
      debugPrint('Dashboard: could not resolve local address: $e');
    }
    return 'this device';
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    try {
      // The editor is served to a browser on the same network, which is also
      // where the requests come from. No credentials are involved and nothing
      // here reaches beyond this app's own configuration.
      request.response.headers
        ..set('Access-Control-Allow-Origin', '*')
        ..set('Cache-Control', 'no-store');

      if (request.method == 'OPTIONS') {
        request.response.headers
          ..set('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS')
          ..set('Access-Control-Allow-Headers', 'Content-Type');
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      if (path == '/' || path == '/index.html') {
        return await _serveEditor(request);
      }
      if (path == '/api/schema' && request.method == 'GET') {
        return await _json(request, {
          'grid': {
            'columns': DashboardGrid.columns,
            'rows': DashboardGrid.rows,
          },
          'widgetTypes': WidgetRegistry.all.map((t) => t.toJson()).toList(),
          'themes': themes.all
              .map((t) => {'id': t.id, 'name': t.name, ...t.toJson()})
              .toList(),
          'fonts': kDashboardFonts.map((f) => f.toJson()).toList(),
          'fontScales': kFontScales,
          // Choice lists the widgets cannot declare for themselves, keyed by
          // the name an option asks for with `choicesFrom`.
          'lists': {'albums': await _albumChoices()},
        });
      }
      if (path == '/api/preview' && request.method == 'GET') {
        return await _json(request, _previewLines());
      }
      if (path == '/api/dashboard' && request.method == 'GET') {
        return await _json(request, settings.toJson());
      }
      if (path == '/api/dashboard' && request.method == 'PUT') {
        return await _save(request);
      }

      // Managing who may share to the panel. Held to the local network
      // whatever the port is exposed to — see [_isLocal].
      if (path == '/senders' || path == '/senders/') {
        if (!_requireLocal(request)) return;
        return await _serveAsset(
            request, 'assets/dashboard/senders.html', ContentType.html);
      }
      if (path == '/api/senders') {
        if (!_requireLocal(request)) return;
        switch (request.method) {
          case 'GET':
            return await _json(request, {
              'senders': [
                for (final t in _config.config.shareInbox.senderTokens)
                  {'name': t.name, 'token': t.token},
              ],
              'port': _config.config.shareInbox.listenPort,
            });
          case 'POST':
            return await _addSender(request);
          case 'DELETE':
            return await _removeSender(request);
        }
      }

      if (path.startsWith('/fonts/') && request.method == 'GET') {
        return await _serveFont(request, path.substring('/fonts/'.length));
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (e) {
      debugPrint('Dashboard: $path failed: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// What each widget would be showing right now, keyed by widget id.
  ///
  /// A type without a live callback, or one whose service has nothing yet, is
  /// simply absent — the editor falls back to that type's stand-in lines
  /// rather than showing an empty tile.
  Map<String, dynamic> _previewLines() {
    final data = _previewData?.call() ?? const PreviewData();
    final out = <String, dynamic>{};
    for (final w in settings.widgets) {
      final type = WidgetRegistry.find(w.type);
      final live = type?.live;
      if (live == null) continue;
      try {
        final lines = live(w, data);
        if (lines.isNotEmpty) {
          out[w.id] = lines.map((l) => l.toJson()).toList();
        }
      } catch (e) {
        debugPrint('Dashboard: live preview for ${w.type} failed: $e');
      }
    }
    return out;
  }

  Future<void> _serveEditor(HttpRequest request) async {
    _editorHtml ??= await rootBundle.loadString('assets/dashboard/editor.html');
    request.response
      ..headers.contentType = ContentType.html
      ..write(_editorHtml);
    await request.response.close();
  }

  final Map<String, String> _assets = {};

  Future<void> _serveAsset(
      HttpRequest request, String asset, ContentType type) async {
    _assets[asset] ??= await rootBundle.loadString(asset);
    request.response
      ..headers.contentType = type
      ..write(_assets[asset]);
    await request.response.close();
  }

  /// Whether the request came from this machine or the local network.
  ///
  /// The sender-token pages hand out credentials, so they are refused to
  /// anything off-LAN rather than trusting that nobody has forwarded the
  /// port. A reverse proxy in front of this would defeat it — every request
  /// would then appear to come from the proxy — which is precisely why these
  /// pages should not be proxied.
  static bool _isLocal(InternetAddress? address) {
    if (address == null) return false;
    if (address.isLoopback) return true;
    final a = address.address;
    if (a.startsWith('192.168.') || a.startsWith('10.')) return true;
    // 172.16.0.0 - 172.31.255.255
    final m = RegExp(r'^172\.(\d{1,2})\.').firstMatch(a);
    if (m != null) {
      final second = int.parse(m.group(1)!);
      if (second >= 16 && second <= 31) return true;
    }
    // Link-local, and IPv6 unique-local / loopback.
    return a.startsWith('169.254.') || a.startsWith('fd') || a == '::1';
  }

  @visibleForTesting
  static bool debugIsLocal(InternetAddress address) => _isLocal(address);

  bool _requireLocal(HttpRequest request) {
    final remote = request.connectionInfo?.remoteAddress;
    if (_isLocal(remote)) return true;
    debugPrint('Dashboard: refused senders page from ${remote?.address}');
    request.response.statusCode = HttpStatus.forbidden;
    request.response.write('Available on the local network only.');
    unawaited(request.response.close());
    return false;
  }

  static final _rand = Random.secure();

  /// The same alphabet and length the kiosk's own Settings screen uses, so a
  /// token made here is indistinguishable from one made there.
  static String _newToken() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(32, (_) => chars[_rand.nextInt(chars.length)]).join();
  }

  Future<void> _addSender(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body);
    final name = (data is Map ? '${data['name'] ?? ''}' : '').trim();
    if (name.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final tokens = _config.config.shareInbox.senderTokens;
    if (tokens.any((t) => t.name.toLowerCase() == name.toLowerCase())) {
      request.response.statusCode = HttpStatus.conflict;
      await request.response.close();
      return;
    }
    final token = SenderToken(name: name, token: _newToken());
    tokens.add(token);
    await _config.save();
    // The inbox reads this same list on every request, so it is live at once
    // — no restart, unlike editing the file underneath it.
    await _json(request, {'name': token.name, 'token': token.token});
  }

  Future<void> _removeSender(HttpRequest request) async {
    final name = request.uri.queryParameters['name'] ?? '';
    final tokens = _config.config.shareInbox.senderTokens;
    final before = tokens.length;
    tokens.removeWhere((t) => t.name == name);
    if (tokens.length == before) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    await _config.save();
    await _json(request, {'removed': name});
  }

  /// The same font files the panel draws with, so the editor's preview shows
  /// the typeface you are actually choosing rather than an approximation of
  /// it. Only the bundled ones — the name is checked against the catalogue
  /// rather than used to reach into the asset bundle.
  Future<void> _serveFont(HttpRequest request, String file) async {
    final known = kDashboardFonts.any((f) => f.file == file && file.isNotEmpty);
    if (!known) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final bytes = await rootBundle.load('assets/fonts/$file');
    request.response
      ..headers.contentType = ContentType('font', 'ttf')
      ..headers.set('Cache-Control', 'public, max-age=86400')
      ..add(bytes.buffer.asUint8List());
    await request.response.close();
  }

  Future<void> _json(HttpRequest request, Object body) async {
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _save(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body);
    if (data is! Map<String, dynamic>) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final incoming = DashboardSettings.fromJson(data);
    final current = settings;
    // The editor owns the layout and the theme; it has no business changing
    // whether the mode exists or which port it is served on, both of which
    // belong to the kiosk's own settings screen.
    current.themeId = incoming.themeId;
    current.roundedCorners = incoming.roundedCorners;
    current.tileShadows = incoming.tileShadows;
    current.pageSeconds = incoming.pageSeconds;
    current.tapToFlip = incoming.tapToFlip;
    current.widgets = incoming.widgets;
    await _config.save();
    notifyListeners();

    await _json(request, {'ok': true, 'widgets': current.widgets.length});
  }

  /// Album names for the editor, or nothing if they cannot be fetched.
  ///
  /// A failure here must not take the whole schema down with it: without the
  /// list the album picker falls back to its declared choices, but without a
  /// schema the editor cannot draw itself at all.
  Future<Map<String, String>> _albumChoices() async {
    final fetch = _albums;
    if (fetch == null) return const {};
    try {
      return await fetch();
    } catch (e) {
      debugPrint('Dashboard: could not list albums for the editor: $e');
      return const {};
    }
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }
}
