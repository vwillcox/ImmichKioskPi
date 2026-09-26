import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// WORKAROUND, for a limited setup: passes Alexa's Hue requests on to Home
/// Assistant, so the editor can have port 80 without the Alexa screen switch
/// losing it. Nothing uses it unless `webPort` and `hueRelay` are set.
///
/// Home Assistant's emulated_hue is what Alexa sees as a Hue bridge, and
/// Alexa only ever talks to a bridge on port 80. With emulated_hue moved to
/// another port — `listen_port: 8300`, `advertise_port: 80` — this kiosk
/// answers on 80 and forwards anything shaped like the Hue API to it. See
/// INSTALL.md, "Workaround: the editor on port 80 with Alexa's Hue bridge".
class HueRelay {
  HueRelay(this.target);

  /// Where emulated_hue listens now: `http://192.168.1.57:8300`.
  final Uri target;

  /// The editor's own paths under /api. Everything else there is the Hue
  /// API — `/api` to pair, `/api/<username>/lights/...` after — whose
  /// usernames are long random strings that will never be one of these.
  static const _ownApi = {
    'schema',
    'preview',
    'background.jpg',
    'render',
    'dashboard',
    'brightness',
    'volume',
    'sounds',
    'list',
    'notes',
    'senders',
  };

  /// Whether [path] is for the Hue bridge rather than the editor.
  static bool handles(String path) {
    if (path == '/description.xml') return true;
    if (path == '/api' || path == '/api/') return true;
    if (!path.startsWith('/api/')) return false;
    final first = path.substring('/api/'.length).split('/').first;
    return !_ownApi.contains(first);
  }

  static final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  /// Hop-by-hop headers, and the ones the client works out for itself.
  static const _skip = {
    'host',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'content-length',
    'upgrade',
  };

  /// Sends [request] on to emulated_hue and its answer back. A 502 when
  /// Home Assistant is not there, rather than the editor's 404.
  Future<void> forward(HttpRequest request) async {
    final out = request.response;
    try {
      final url = target.replace(
        path: request.uri.path,
        query: request.uri.hasQuery ? request.uri.query : null,
      );
      final upstream = await _client.openUrl(request.method, url);
      request.headers.forEach((name, values) {
        if (_skip.contains(name.toLowerCase())) return;
        for (final v in values) {
          upstream.headers.add(name, v);
        }
      });
      await upstream.addStream(request);
      final reply = await upstream.close().timeout(const Duration(seconds: 10));
      out.statusCode = reply.statusCode;
      reply.headers.forEach((name, values) {
        if (_skip.contains(name.toLowerCase())) return;
        for (final v in values) {
          out.headers.add(name, v);
        }
      });
      await out.addStream(reply);
      await out.close();
    } catch (e) {
      debugPrint('HueRelay: ${request.method} ${request.uri.path} failed: $e');
      try {
        out.statusCode = HttpStatus.badGateway;
        await out.close();
      } catch (_) {}
    }
  }
}
