import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Size;

import '../dashboard/dashboard_fonts.dart';
import '../dashboard/dashboard_model.dart';
import '../dashboard/dashboard_theme.dart';
import '../dashboard/live_preview.dart';
import '../dashboard/tile_renderer.dart';
import '../config/app_config.dart' show SenderToken;
import '../dashboard/widget_registry.dart';
import 'brightness_service.dart';
import 'config_service.dart';
import 'hue_relay.dart';
import 'notes_service.dart';
import 'shopping_service.dart';
import 'timer_sounds.dart';

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

  /// The same editor on [DashboardSettings.webPort] — 80 — when the Pi lets
  /// it have that port; null when it does not.
  HttpServer? _webServer;
  String? _editorHtml;

  /// Draws a tile with the real widget, as a PNG. Set by [TileRenderHost]
  /// once it is in the widget tree; null before then, or in tests, where the
  /// editor falls back to its text preview.
  Future<List<int>?> Function(TileRenderRequest)? renderTile;

  /// The household notes board, for its page and API. Null in tests.
  NotesService? notes;

  /// The shopping list, for its page and API. Null in tests.
  ShoppingService? shopping;

  /// The panel's backlight, for the editor's slider. Null in tests.
  BrightnessService? brightness;

  /// The timers' sounds, for the editor's list, its previews and uploads.
  /// Null in tests.
  TimerSounds? timerSounds;

  /// The photo behind the dashboard now, as JPEG bytes, for the editor to
  /// preview the photo background with. Null in tests.
  Future<List<int>?> Function()? backgroundImage;

  DashboardSettings get settings => _config.config.dashboard;

  /// Where to point a browser. The host's own address is resolved once so the
  /// kiosk can show something you can actually type in, rather than
  /// "localhost", which is useless from the sofa.
  ///
  /// Its mDNS name (homecanvas.local) when Avahi is announcing one — that
  /// survives the router handing out a new lease — otherwise the IP address.
  String _host = 'this device';
  String? _ip;
  String get editorAddress => 'http://$_host$_portSuffix';

  /// Nothing when the editor has port 80, which a browser assumes.
  String get _portSuffix => _webServer?.port == 80 && settings.enabled
      ? ''
      : ':${settings.editorPort}';

  /// The same editor by IP address, for a browser that can't resolve .local
  /// names (some Android versions). Null when [editorAddress] already is it.
  String? get editorIpAddress =>
      _ip == null || _ip == _host ? null : 'http://$_ip$_portSuffix';

  Future<void> start() async {
    await themes.load();
    final ip = await _localAddress();
    _ip = ip == 'this device' ? null : ip;
    _host = _mdnsName() ?? ip;
    await _bind();
  }

  /// This machine's name on the network as `<hostname>.local`, or null when
  /// nothing is announcing it. See scripts/set-hostname.sh.
  static String? _mdnsName() {
    try {
      // avahi-daemon writes its pid here while it runs, on Debian and
      // Raspberry Pi OS alike; without it the .local name resolves nowhere.
      if (!File('/run/avahi-daemon/pid').existsSync()) return null;
      final name = Platform.localHostname.split('.').first;
      if (name.isEmpty || name == 'localhost') return null;
      return '$name.local';
    } catch (e) {
      debugPrint('Dashboard: could not resolve mDNS name: $e');
      return null;
    }
  }

  /// Rebinds when a port or the relay changes; otherwise leaves working
  /// servers alone.
  Future<void> refreshFromSettings() async {
    final same = (_server != null) == settings.enabled &&
        (_server == null || _server!.port == settings.editorPort) &&
        _webBound == _webKey;
    if (same) return;
    await _bind();
  }

  /// What port 80 was last set up for — its port and relay — so a port the
  /// Pi refused is not tried again on every save.
  String? _webBound;
  String get _webKey => '${settings.webPort}|${settings.hueRelay.trim()}';

  Future<void> _stop() async {
    await _server?.close(force: true);
    _server = null;
    await _webServer?.close(force: true);
    _webServer = null;
    _webBound = null;
  }

  Future<void> _bind() async {
    await _stop();
    if (settings.enabled) {
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
    // Port 80 even with the editor off: Alexa's requests still come to it.
    await _bindWeb();
  }

  /// Port 80 as well, so the address needs no number. Quietly left alone
  /// when the Pi will not give it up — an ordinary user may not open ports
  /// below 1024 until it is told otherwise, and the editor still has its own.
  Future<void> _bindWeb() async {
    _webBound = _webKey;
    final port = settings.webPort;
    if (port <= 0 || port == settings.editorPort) return;
    final target = Uri.tryParse(settings.hueRelay.trim());
    final relay = target != null && target.hasAuthority
        ? HueRelay(target)
        : null;
    try {
      _webServer = await HttpServer.bind(
          InternetAddress.anyIPv4, port, shared: true);
      debugPrint('Dashboard editor also on :$port'
          '${relay == null ? '' : ', passing Hue on to ${relay.target}'}');
      _webServer!.listen((request) {
        // Alexa, for the Hue bridge that used to have this port.
        if (relay != null && HueRelay.handles(request.uri.path)) {
          unawaited(relay.forward(request));
        } else if (settings.enabled) {
          unawaited(_handle(request));
        } else {
          request.response.statusCode = HttpStatus.notFound;
          unawaited(request.response.close());
        }
      }, onError: (Object e) {
        debugPrint('Dashboard: server error on :$port: $e');
      });
    } catch (e) {
      debugPrint('Dashboard: could not bind :$port ($e) — the editor stays '
          'on :${settings.editorPort}. See INSTALL.md, "Workaround: the editor '
          'on port 80 with Alexa\'s Hue bridge".');
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
          ..set('Access-Control-Allow-Methods', 'GET, PUT, POST, DELETE, OPTIONS')
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
          // The palette's groups, in the order to show them.
          'categories': WidgetCategory.order,
          'themes': themes.all
              .map((t) => {'id': t.id, 'name': t.name, ...t.toJson()})
              .toList(),
          'fonts': kDashboardFonts.map((f) => f.toJson()).toList(),
          'fontScales': kFontScales,
          // Choice lists the widgets cannot declare for themselves, keyed by
          // the name an option asks for with `choicesFrom`.
          'lists': {
            'albums': await _albumChoices(),
            'haEntities': await _haChoices(),
            'voices': await _voiceChoices(),
            'timerSounds': await _timerSoundChoices(),
          },
        });
      }
      if (path == '/api/preview' && request.method == 'GET') {
        return await _json(request, _previewLines());
      }
      if (path == '/api/background.jpg' && request.method == 'GET') {
        final bytes = await backgroundImage?.call().catchError((_) => null);
        if (bytes == null || bytes.isEmpty) {
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(bytes);
        await request.response.close();
        return;
      }
      if (path == '/api/render' && request.method == 'POST') {
        return await _render(request);
      }
      if (path == '/api/dashboard' && request.method == 'GET') {
        return await _json(request, settings.toJson());
      }
      if (path == '/api/dashboard' && request.method == 'PUT') {
        return await _save(request);
      }
      // The backlight: live, not part of the layout's Save, since you judge
      // it by looking at the panel as you drag.
      if (path == '/api/brightness') {
        if (request.method == 'PUT' &&
            !sameOrigin(request.headers.value('origin'),
                request.headers.value(HttpHeaders.hostHeader))) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        return await _brightnessApi(request);
      }
      // The volumes the panel makes its own sounds at — live, like the
      // backlight, since you judge them by ear in the room.
      if (path == '/api/volume') {
        if (request.method == 'PUT' &&
            !sameOrigin(request.headers.value('origin'),
                request.headers.value(HttpHeaders.hostHeader))) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        return await _volumeApi(request);
      }

      // The timers' sounds: listed, previewed in the browser, tried on the
      // panel, uploaded and deleted. Changes only from the editor's own page
      // on the local network, like the notes board.
      if (path == '/api/sounds' || path.startsWith('/api/sounds/')) {
        if (request.method != 'GET') {
          if (!_requireLocal(request)) return;
          if (!sameOrigin(request.headers.value('origin'),
              request.headers.value(HttpHeaders.hostHeader))) {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
            return;
          }
        }
        return await _soundsApi(request, path);
      }

      // The notes board: a page for posting from any phone in the house,
      // and its API. Local network only, like the senders page — a note
      // goes straight onto the wall.
      if (path == '/notes' || path == '/notes/') {
        if (!_requireLocal(request)) return;
        return await _serveAsset(
            request, 'assets/dashboard/notes.html', ContentType.html);
      }
      if (path == '/list' || path == '/list/') {
        if (!_requireLocal(request)) return;
        return await _serveAsset(
            request, 'assets/dashboard/list.html', ContentType.html);
      }
      if (path == '/api/list') {
        if (!_requireLocal(request)) return;
        if (!sameOrigin(request.headers.value('origin'),
            request.headers.value(HttpHeaders.hostHeader))) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        return await _listApi(request);
      }
      if (path == '/api/notes') {
        if (!_requireLocal(request)) return;
        // Only from the notes page itself. The server answers every origin
        // for the editor's sake, which would otherwise let any web page open
        // on a phone in the house post onto the wall.
        if (!sameOrigin(request.headers.value('origin'),
            request.headers.value(HttpHeaders.hostHeader))) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        return await _notesApi(request);
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

  /// Whether a request's Origin, if it sent one, is this server. No Origin
  /// means it did not come from a web page at all — curl, or a same-origin
  /// GET — and is let through.
  @visibleForTesting
  static bool sameOrigin(String? origin, String? host) {
    if (origin == null || origin.isEmpty) return true;
    final o = Uri.tryParse(origin);
    if (o == null || host == null) return false;
    return o.hasAuthority &&
        '${o.host}${o.hasPort ? ':${o.port}' : ''}' == host;
  }

  /// GET the list; POST {"text": "Milk"} to add, {"toggle": id} to tick or
  /// untick; DELETE ?id= to take something off.
  Future<void> _listApi(HttpRequest request) async {
    final list = shopping;
    if (list == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    switch (request.method) {
      case 'POST':
        final body = await utf8.decoder.bind(request).join();
        final data = body.isEmpty ? null : jsonDecode(body);
        if (data is Map && data['toggle'] != null) {
          list.toggle('${data['toggle']}');
        } else if (data is! Map || list.add('${data['text'] ?? ''}') == null) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
      case 'DELETE':
        list.remove(request.uri.queryParameters['id'] ?? '');
      case 'GET':
        break;
      default:
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
    }
    await _json(request, {
      'items': [for (final i in list.items) i.toJson()],
    });
  }

  Future<void> _notesApi(HttpRequest request) async {
    final board = notes;
    if (board == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    switch (request.method) {
      case 'POST':
        final body = await utf8.decoder.bind(request).join();
        final data = body.isEmpty ? null : jsonDecode(body);
        final text = data is Map ? '${data['text'] ?? ''}' : '';
        final from = data is Map ? '${data['from'] ?? ''}' : '';
        if (board.add(text, from: from.length > 40 ? from.substring(0, 40) : from) ==
            null) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
      case 'DELETE':
        board.remove(request.uri.queryParameters['id'] ?? '');
      case 'GET':
        break;
      default:
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
    }
    await _json(request, {
      'notes': [for (final n in board.notes) n.toJson()],
    });
  }

  /// A picture of one tile, drawn by the real widget.
  ///
  /// Posted rather than fetched because what is drawn is the editor's copy —
  /// options changed, theme picked, tile resized — not what has been saved.
  ///
  ///     POST /api/render
  ///     {"widget": {...}, "themeId": "glass", "roundedCorners": true,
  ///      "tileShadows": true, "width": 620, "height": 380}
  Future<void> _render(HttpRequest request) async {
    final render = renderTile;
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body);
    if (data is! Map<String, dynamic> || data['widget'] is! Map) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    if (render == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    double dimension(Object? v, double max) =>
        (v is num ? v.toDouble() : 0).clamp(16, max).toDouble();
    final size = Size(
      dimension(data['width'], 1920),
      dimension(data['height'], 1200),
    );
    // Only the look is taken from the request; everything else about the
    // dashboard stays as saved.
    final look = DashboardSettings.fromJson({
      ...settings.toJson(),
      if (data['roundedCorners'] is bool)
        'roundedCorners': data['roundedCorners'],
      if (data['tileShadows'] is bool) 'tileShadows': data['tileShadows'],
    });
    final png = await render(TileRenderRequest(
      config: DashboardWidgetConfig.fromJson(
          (data['widget'] as Map).cast<String, dynamic>()),
      theme: themes.byId('${data['themeId'] ?? settings.themeId}'),
      settings: look,
      size: size,
    ));
    if (png == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.add(png);
    await request.response.close();
  }

  Future<void> _brightnessApi(HttpRequest request) async {
    final light = brightness;
    if (light == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    if (request.method == 'PUT') {
      final data = jsonDecode(await utf8.decoder.bind(request).join());
      final v = data is Map ? data['value'] : null;
      if (v is! num) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      light.set(v);
    } else if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    return await _json(request, {
      'value': light.level,
      'min': BrightnessService.minimum,
      'max': 100,
    });
  }

  /// `notification` is the share chime, `speech` notes and reminders read
  /// aloud, `reader` news articles, `timer` the kitchen timers — each 0–100.
  /// `dnd` is Do Not Disturb, which mutes them all without changing them.
  Future<void> _volumeApi(HttpRequest request) async {
    final inbox = _config.config.shareInbox;
    if (request.method == 'PUT') {
      final data = jsonDecode(await utf8.decoder.bind(request).join());
      if (data is! Map) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      double? level(String key) {
        final v = data[key];
        return v is num ? v.toDouble().clamp(0, 100) : null;
      }

      inbox.notificationVolume =
          level('notification') ?? inbox.notificationVolume;
      inbox.speechVolume = level('speech') ?? inbox.speechVolume;
      inbox.readerVolume = level('reader') ?? inbox.readerVolume;
      inbox.timerVolume = level('timer') ?? inbox.timerVolume;
      if (data['dnd'] is bool) inbox.dndMuted = data['dnd'] as bool;
      await _config.save();
    } else if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    return await _json(request, {
      'notification': inbox.notificationVolume.round(),
      'speech': inbox.speechVolume.round(),
      'reader': inbox.readerVolume.round(),
      'timer': inbox.timerVolume.round(),
      'dnd': inbox.dndMuted,
    });
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
    // belong to the kiosk's own settings screen — nor whether someone has
    // paused the pages on the panel itself.
    current.themeId = incoming.themeId;
    current.roundedCorners = incoming.roundedCorners;
    current.tileShadows = incoming.tileShadows;
    current.pageSeconds = incoming.pageSeconds;
    current.tapToFlip = incoming.tapToFlip;
    current.topBar = incoming.topBar;
    current.pages = incoming.pages;
    current.photoBackground = incoming.photoBackground;
    current.photoAlbum = incoming.photoAlbum;
    current.photoDim = incoming.photoDim;
    current.photoSeconds = incoming.photoSeconds;
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
  /// Home Assistant's entities for the widget's picker. Set once the
  /// service exists; empty when Home Assistant is not set up or not
  /// answering — the editor then offers a text box's worth of nothing, and
  /// says so in the widget itself.
  Future<Map<String, String>> Function()? haEntities;

  Future<Map<String, String>> _haChoices() async {
    final fetch = haEntities;
    if (fetch == null) return const {};
    try {
      return await fetch().timeout(const Duration(seconds: 6));
    } catch (_) {
      return const {};
    }
  }

  /// The piper voices installed, for the news widget's speed settings.
  Future<Map<String, String>> Function()? voices;

  Future<Map<String, String>> _voiceChoices() async {
    final fetch = voices;
    if (fetch == null) return const {};
    try {
      return await fetch();
    } catch (_) {
      return const {};
    }
  }

  Future<Map<String, String>> _timerSoundChoices() async {
    final sounds = timerSounds;
    if (sounds == null) return TimerSounds.defaultChoices;
    try {
      return await sounds.choices();
    } catch (_) {
      return TimerSounds.defaultChoices;
    }
  }

  Future<void> _soundsApi(HttpRequest request, String path) async {
    final sounds = timerSounds;
    if (sounds == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final id = request.uri.queryParameters['id'] ?? '';

    // The sound itself, for the editor's play button.
    if (path == '/api/sounds/file' && request.method == 'GET') {
      final bytes = await sounds.bytes(id);
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final ext = id.toLowerCase();
      request.response.headers.contentType = ext.endsWith('.mp3')
          ? ContentType('audio', 'mpeg')
          : ext.endsWith('.ogg')
          ? ContentType('audio', 'ogg')
          : ContentType('audio', 'wav');
      request.response.add(bytes);
      await request.response.close();
      return;
    }
    // Played on the panel, to hear how loud it is in the room.
    if (path == '/api/sounds/play' && request.method == 'POST') {
      unawaited(sounds.play(
        id,
        volume: _config.config.shareInbox.timerVolume,
      ));
      return await _json(request, {'playing': id});
    }
    if (path != '/api/sounds') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    switch (request.method) {
      case 'GET':
        return await _json(request, {'choices': await sounds.choices()});
      case 'POST':
        // The file as the body, its name in the query: no multipart to
        // unpick, and the browser sends a File exactly like that.
        final name = request.uri.queryParameters['name'] ?? '';
        final body = BytesBuilder(copy: false);
        await for (final chunk in request) {
          body.add(chunk);
          if (body.length > TimerSounds.maxUploadBytes) {
            request.response.statusCode = HttpStatus.requestEntityTooLarge;
            request.response.write('That file is over 5 MB.');
            await request.response.close();
            return;
          }
        }
        try {
          final saved = await sounds.save(name, body.takeBytes());
          return await _json(request, {
            'id': saved,
            'choices': await sounds.choices(),
          });
        } on FormatException catch (e) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write(e.message);
          await request.response.close();
          return;
        }
      case 'DELETE':
        if (!await sounds.delete(id)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        return await _json(request, {'choices': await sounds.choices()});
    }
    request.response.statusCode = HttpStatus.methodNotAllowed;
    await request.response.close();
  }

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
