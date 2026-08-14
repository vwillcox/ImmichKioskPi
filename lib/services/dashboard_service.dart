import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../dashboard/dashboard_fonts.dart';
import '../dashboard/dashboard_model.dart';
import '../dashboard/dashboard_theme.dart';
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
  DashboardService(this._config)
      : themes = ThemeRepository(ThemeRepository.defaultDirectory());

  final ConfigService _config;
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
      final home = real.firstWhere(
        (a) => a.address.startsWith('192.168.') || a.address.startsWith('10.'),
        orElse: () => real.isEmpty ? InternetAddress.anyIPv4 : real.first,
      );
      if (home != InternetAddress.anyIPv4) return home.address;
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
        });
      }
      if (path == '/api/dashboard' && request.method == 'GET') {
        return await _json(request, settings.toJson());
      }
      if (path == '/api/dashboard' && request.method == 'PUT') {
        return await _save(request);
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

  Future<void> _serveEditor(HttpRequest request) async {
    _editorHtml ??= await rootBundle.loadString('assets/dashboard/editor.html');
    request.response
      ..headers.contentType = ContentType.html
      ..write(_editorHtml);
    await request.response.close();
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
    current.widgets = incoming.widgets;
    await _config.save();
    notifyListeners();

    await _json(request, {'ok': true, 'widgets': current.widgets.length});
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }
}
