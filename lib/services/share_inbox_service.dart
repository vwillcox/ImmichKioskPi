import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart' show ShareInboxSettings;
import 'config_service.dart';
import 'sealed_share.dart';
import 'sealed_stream.dart';
import 'media_cache.dart';

enum ShareType { link, text, image, gif, video }

/// One thing someone shared to the kiosk from the companion app.
class SharedItem {
  final ShareType type;
  final String sender;

  /// The link URL or the raw text, for [ShareType.link]/[ShareType.text].
  final String? content;

  /// Local file path, for [ShareType.image]/[ShareType.gif]/[ShareType.video].
  final String? localPath;

  SharedItem({
    required this.type,
    required this.sender,
    this.content,
    this.localPath,
  });
}

/// Listens for content shared from the companion Android app and queues it
/// for [IncomingShareOverlay] to show.
///
/// There's no separate relay: the kiosk runs its own small HTTP server
/// directly (the same `dart:io` `HttpServer` primitive [SpotifyService]
/// already uses for its OAuth loopback listener, just long-lived and bound
/// on every interface rather than one-shot on loopback). Whatever gets it
/// reachable from outside the house — port forwarding, a reverse proxy — is
/// the user's own concern; this only needs to know which local port to bind.
///
/// The kiosk is the sole source of truth for who's allowed to share: each
/// request's bearer token is checked directly against
/// `config.shareInbox.senderTokens`, exactly like every other credential in
/// this app lives in its own config.json rather than anywhere else.
class ShareInboxService extends ChangeNotifier {
  final ConfigService _configService;
  HttpServer? _server;
  Player? _chime;
  String? _chimePath;

  final List<SharedItem> _queue = [];

  ShareInboxService(this._configService);

  /// Called when something lands. A hook rather than a dependency because the
  /// screen service is built after this one, and because the inbox has no
  /// business knowing how the panel is switched on.
  Future<void> Function()? onItemArrived;

  ShareInboxSettings get _settings => _configService.config.shareInbox;

  /// The panel's end-to-end encryption identity. Rotated on a schedule; see
  /// [ShareKeys] for why per-message keys matter more than the schedule does.
  final ShareKeys keys = ShareKeys();
  bool _keysReady = false;

  SharedItem? get current => _queue.isEmpty ? null : _queue.first;
  int get pendingCount => _queue.length;

  Future<void> start() async {
    await keys.load();
    _keysReady = true;
    await _extractChimeAsset();
    await _bind();
  }

  /// Call after Settings saves a change — rebinds if the port changed.
  Future<void> refreshFromSettings() async {
    final server = _server;
    if (server != null && server.port == _settings.listenPort) return;
    await server?.close(force: true);
    await _bind();
  }

  Future<void> _bind() async {
    try {
      final server =
          await HttpServer.bind(InternetAddress.anyIPv4, _settings.listenPort);
      _server = server;
      server.listen(_handleRequest,
          onError: (e) => debugPrint('ShareInbox server error: $e'));
      debugPrint('ShareInbox listening on :${_settings.listenPort}');
    } catch (e) {
      debugPrint('ShareInbox failed to bind :${_settings.listenPort}: $e');
    }
  }

  /// Content type a sealed body arrives as. The real type is inside, where
  /// the network cannot see it.
  static const String sealedMime = 'application/vnd.kiosk.sealed';

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    // Every sender is a known device holding a token, so the public key is
    // handed out to them rather than to the world — it is not secret, but
    // there is no reason to answer strangers either.
    if (request.method == 'GET' && path == '/pubkey') {
      if (_senderFor(request) == null) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      if (_keysReady) await keys.maybeRotate();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'v': SealedShare.version,
          'kid': keys.currentKeyId,
          'key': base64Encode(await keys.currentPublicKey()),
          'rotatedAt': keys.rotatedAt?.toIso8601String(),
          'rotateEveryHours': keys.rotateEvery.inHours,
        }));
      await request.response.close();
      return;
    }

    if (request.method != 'POST' || path != '/share') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final sender = _senderFor(request);
    if (sender == null) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }

    try {
      final contentType = request.headers.contentType;
      final sealed = contentType?.mimeType == sealedMime;

      if (!sealed && _settings.requireEncryption) {
        // Refusing rather than quietly accepting: a setting that says
        // everything must be encrypted is worth nothing if a sender can opt
        // out by omitting a header.
        debugPrint('ShareInbox: refused an unencrypted share from $sender');
        request.response.statusCode = HttpStatus.preconditionFailed;
        request.response.write(
            'This kiosk accepts encrypted shares only. Update the app.');
        await request.response.close();
        return;
      }

      if (!sealed) {
        // Said plainly, and only reachable when enforcement is off. Without
        // it a plaintext share and an encrypted one both look like silence in
        // the log, so there is no way to tell by reading it which you got.
        debugPrint('ShareInbox: accepted a PLAINTEXT share from $sender');
      }

      if (sealed) {
        await _handleSealed(request, sender);
      } else if (contentType?.mimeType == 'application/json') {
        await _handleJson(request, await _drain(request), sender);
      } else if (contentType != null) {
        await _handleFile(request, request, sender, contentType.mimeType);
      } else {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
    } on SealedAuthException catch (e) {
      debugPrint('ShareInbox: rejected a sealed share from $sender: $e');
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write(e.message);
      await request.response.close();
    } on SealedFormatException catch (e) {
      debugPrint('ShareInbox: malformed sealed share from $sender: $e');
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(e.message);
      await request.response.close();
    } catch (e) {
      debugPrint('ShareInbox request error: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  /// The name behind the bearer token, or null when it matches nobody.
  String? _senderFor(HttpRequest request) {
    final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!auth.startsWith('Bearer ')) return null;
    final token = auth.substring(7);
    for (final t in _settings.senderTokens) {
      if (t.token == token) return t.name;
    }
    return null;
  }

  /// Opens a sealed body and hands the plaintext to the ordinary handlers.
  ///
  /// The decryption streams, so a video is written to disk a chunk at a time
  /// rather than being assembled in memory first.
  Future<void> _handleSealed(HttpRequest request, String sender) async {
    if (!_keysReady) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    final header = Completer<SealedHeader>();
    // Plain StreamController, not broadcast: it holds what arrives until a
    // listener attaches, which is what lets the route be chosen from the
    // header — known only once the first bytes have been decrypted — without
    // losing the bytes that followed it.
    final plaintext = StreamController<List<int>>();

    final reader = SealedReader(keyFor: keys.keyPairFor);
    reader.open(request, onHeader: (h) {
      if (!header.isCompleted) header.complete(h);
    }).listen(
      plaintext.add,
      onError: (Object e, StackTrace st) {
        if (!header.isCompleted) header.completeError(e, st);
        if (!plaintext.isClosed) plaintext.addError(e, st);
        unawaited(plaintext.close());
      },
      onDone: () {
        if (!header.isCompleted) {
          header.completeError(
              const SealedFormatException('the message carried no header'));
        }
        if (!plaintext.isClosed) plaintext.close();
      },
      cancelOnError: true,
    );

    final open = await header.future;
    // Naming the key it was sealed to, so rotation can be watched working:
    // the id here changes when the panel rotates, and a share sealed to the
    // previous key still opens for one further period.
    debugPrint('ShareInbox: opened a SEALED share from $sender '
        '(key ${open.kid}, ${open.mime})');

    if (open.mime == 'application/json') {
      final bytes = <int>[];
      await for (final chunk in plaintext.stream) {
        bytes.addAll(chunk);
      }
      await _handleJson(request, bytes, sender);
      return;
    }
    await _handleFile(request, plaintext.stream, sender, open.mime);
  }

  Future<void> _handleJson(
      HttpRequest request, List<int> bytes, String sender) async {
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final kindStr = body['type'] as String?;
    final content = (body['content'] as String? ?? '').trim();
    if ((kindStr != 'link' && kindStr != 'text') || content.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    _enqueue(SharedItem(
      type: kindStr == 'link' ? ShareType.link : ShareType.text,
      sender: sender,
      content: content,
    ));
    await _respondOk(request);
  }

  Future<void> _handleFile(
    HttpRequest request,
    Stream<List<int>> body,
    String sender,
    String mime,
  ) async {
    final type = _typeForMime(mime);
    if (type == null) {
      request.response.statusCode = HttpStatus.unsupportedMediaType;
      await request.response.close();
      return;
    }
    final dir = Directory(p.join(ImmichKioskPiCache.root, 'shared'));
    await dir.create(recursive: true);
    final path = p.join(
        dir.path, '${DateTime.now().microsecondsSinceEpoch}${_extForMime(mime)}');
    final sink = File(path).openWrite();
    try {
      // A sealed stream raises at the end if it was cut short, so reaching
      // the end of this without error is what proves the file whole.
      await sink.addStream(body);
      await sink.close();
    } catch (e) {
      await sink.close();
      // A half-written file from a message that failed its check is rubbish;
      // leaving it would put a truncated video in the queue.
      try {
        await File(path).delete();
      } catch (_) {}
      rethrow;
    }
    _enqueue(SharedItem(type: type, sender: sender, localPath: path));
    await _respondOk(request);
  }

  Future<void> _respondOk(HttpRequest request) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write('{"ok":true}');
    await request.response.close();
  }

  Future<List<int>> _drain(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  ShareType? _typeForMime(String mime) {
    if (mime == 'image/gif') return ShareType.gif;
    if (mime.startsWith('image/')) return ShareType.image;
    if (mime.startsWith('video/')) return ShareType.video;
    return null;
  }

  String _extForMime(String mime) {
    switch (mime) {
      case 'image/gif':
        return '.gif';
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'video/mp4':
        return '.mp4';
      case 'video/quicktime':
        return '.mov';
      case 'video/webm':
        return '.webm';
      default:
        return mime.startsWith('image/') ? '.jpg' : '.bin';
    }
  }

  void _enqueue(SharedItem item) {
    _queue.add(item);
    notifyListeners();
    if (!_settings.dndMuted) unawaited(_playChime());
    // Left to decide for itself whether Do Not Disturb applies.
    unawaited(onItemArrived?.call());
  }

  /// Copied out of the asset bundle once on startup so media_kit can play it
  /// as a plain local file — the same, already-proven path every other
  /// sound/video in this app plays from, rather than relying on any
  /// asset-URI scheme support.
  Future<void> _extractChimeAsset() async {
    try {
      final bytes = await rootBundle.load('assets/sounds/incoming.wav');
      final path = p.join(ImmichKioskPiCache.root, 'incoming.wav');
      await File(path).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      _chimePath = path;
    } catch (e) {
      debugPrint('ShareInbox could not extract chime asset: $e');
    }
  }

  Future<void> _playChime() async {
    final path = _chimePath;
    if (path == null) return;
    try {
      // Its own Player instance, separate from whatever's playing
      // music/video, so this volume is independent of that one.
      final chime = _chime ??= Player();
      await chime.setVolume(_settings.notificationVolume);
      await chime.open(Media(path));
    } catch (e) {
      debugPrint('ShareInbox chime error: $e');
    }
  }

  /// Called once the popup has shown (or the user dismissed) [current].
  void dequeue() {
    if (_queue.isNotEmpty) _queue.removeAt(0);
    notifyListeners();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _chime?.dispose();
    super.dispose();
  }
}
