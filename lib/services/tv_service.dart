import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../config/app_config.dart' show TvSettings;
import 'config_service.dart';
import 'vidaa_client.dart';

/// Talks to a Hisense VIDAA television.
///
/// A port of the standalone vidaa_remote app's controller, moved in here so
/// the dashboard's TV widget can drive the set directly. The protocol work —
/// the credential derivation, the MQTT topics, pairing — is that app's, and
/// is reused rather than rewritten.
///
/// Only one client may hold a session: the MQTT client id is derived from the
/// device UUID, so a second connection using the same UUID displaces the
/// first and the two then fight over it. That is why the standalone remote is
/// no longer started at boot — see deploy/labwc-autostart.

enum ConnState { disconnected, connecting, connected, needsPairing, error }

/// Owns the VidaaClient, connection lifecycle, token persistence and pairing.
class TvService extends ChangeNotifier {
  TvService(this._config);

  final ConfigService _config;

  TvSettings get settings => _config.config.tv;
  String get host => settings.host;
  String get uuid => settings.uuid;

  VidaaClient? _client;
  ConnState conn = ConnState.disconnected;
  String? lastError;

  final TvState state = TvState();
  bool get isConnected => conn == ConnState.connected;

  List<int>? _certBytes;
  List<int>? _keyBytes;
  String? _accessToken;
  String? _refreshToken;

  /// Predictable, easy-to-seed location: $HOME/.config/vidaa/vidaa_token.json
  /// (override with $VIDAA_TOKEN_FILE).
  File get _tokenFileSync {
    final override = Platform.environment['VIDAA_TOKEN_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final home = Platform.environment['HOME'] ?? '.';
    final dir = Directory('$home/.config/vidaa');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/vidaa_token.json');
  }

  Future<File> get _tokenFile async => _tokenFileSync;

  /// Loads the client certificate and key the television's MQTT interface
  /// requires.
  ///
  /// These are the manufacturer's own credentials — the set accepts no other —
  /// so they cannot be generated or rotated. They are still kept out of the
  /// repository (`assets/certs/*.key` is git-ignored); supply a copy at that
  /// path, as the TV Remote section of moreinfo.md describes.
  ///
  /// Without it this throws [TvCredentialsMissing], which the caller turns
  /// into a clear message rather than the mbedTLS handshake error an empty key
  /// produces four steps later.
  Future<void> _loadAssets() async {
    _certBytes ??= await _loadCert('assets/certs/vidaa_client.pem');
    _keyBytes ??= await _loadCert('assets/certs/vidaa_client.key');
  }

  static Future<List<int>> _loadCert(String asset) async {
    List<int> bytes;
    try {
      bytes = (await rootBundle.load(asset)).buffer.asUint8List();
    } catch (e) {
      throw TvCredentialsMissing('$asset is not bundled with this build');
    }
    // A blank or placeholder file is the more likely failure than a missing
    // one, since removing a leaked key tends to leave the path behind.
    if (bytes.length < 64) {
      throw TvCredentialsMissing('$asset is empty or a placeholder');
    }
    return bytes;
  }

  int _accessExpiry = 0; // unix seconds
  int _refreshExpiry = 0;

  int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // 5-minute safety margin so we refresh slightly before actual expiry.
  bool get _accessValid =>
      _accessToken != null && _nowSec() < _accessExpiry - 300;

  Future<void> _loadToken() async {
    try {
      final f = await _tokenFile;
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if (j['host'] == host) {
          _accessToken = j['accesstoken'] as String?;
          _refreshToken = j['refreshtoken'] as String?;
          _accessExpiry = (j['access_expiry'] as num?)?.toInt() ?? 0;
          _refreshExpiry = (j['refresh_expiry'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveToken(Map<String, dynamic> tok) async {
    _accessToken = tok['accesstoken'] as String?;
    _refreshToken = tok['refreshtoken'] as String? ?? _refreshToken;
    final now = _nowSec();
    final aDays = (tok['accesstoken_duration_day'] as num?)?.toInt() ?? 2;
    final rDays = (tok['refreshtoken_duration_day'] as num?)?.toInt() ?? 30;
    // Prefer the TV-provided issue time; fall back to now.
    final aTime = int.tryParse('${tok['accesstoken_time'] ?? now}') ?? now;
    final rTime = int.tryParse('${tok['refreshtoken_time'] ?? now}') ?? now;
    _accessExpiry = aTime + aDays * 86400;
    _refreshExpiry = rTime + rDays * 86400;
    final f = await _tokenFile;
    await f.writeAsString(jsonEncode({
      'host': host,
      'accesstoken': _accessToken,
      'refreshtoken': _refreshToken,
      'access_expiry': _accessExpiry,
      'refresh_expiry': _refreshExpiry,
      'saved_at': DateTime.now().toIso8601String(),
    }));
  }

  void _setConn(ConnState s, {String? err}) {
    conn = s;
    lastError = err;
    notifyListeners();
  }

  /// Build a fresh client (optionally token-authenticated) and connect it.
  Future<bool> _openAndConnect(String? token) async {
    _client?.disconnect();
    _client = VidaaClient(
      host: host,
      uuid: uuid,
      certBytes: _certBytes,
      keyBytes: _keyBytes,
      accessToken: token,
      state: state,
      onState: (_) => notifyListeners(),
      onLog: (s) => debugPrint('[vidaa] $s'),
    );
    try {
      return await _client!.connect();
    } catch (e) {
      _setConn(ConnState.error, err: '$e');
      return false;
    }
  }

  void _finishConnected() {
    _client!.getState();
    _client!.getVolume();
    _setConn(ConnState.connected);
  }

  /// Connect with a saved/refreshed token if possible, else fall to pairing.
  Future<void> connect() async {
    _setConn(ConnState.connecting);
    try {
      await _loadAssets();
    } on TvCredentialsMissing catch (e) {
      // Stops here rather than connecting without them: the handshake would
      // fail anyway, several layers down, with an error naming TLS instead of
      // the thing actually missing.
      _setConn(ConnState.error,
          err: 'TV client certificate not set up — ${e.message}');
      return;
    }
    await _loadToken();

    // A) Access token still valid -> use it directly.
    if (_accessValid && await _openAndConnect(_accessToken)) {
      _finishConnected();
      return;
    }
    // B) Refresh an expired/unknown session using the refresh token.
    if (_refreshToken != null && await _refreshAndConnect()) {
      return;
    }
    // C) We have some access token of unknown validity -> try it anyway.
    if (_accessToken != null && await _openAndConnect(_accessToken)) {
      _finishConnected();
      return;
    }
    // D) No usable credentials -> connect unauthenticated for pairing.
    if (await _openAndConnect(null)) {
      _setConn(ConnState.needsPairing);
      return;
    }
    _setConn(ConnState.error, err: 'Could not connect to $host');
  }

  /// Renew the access token: connect with dynamic creds (restricted ACL still
  /// allows the token-issuance topic), request a new token, reconnect with it.
  Future<bool> _refreshAndConnect() async {
    // The TV expects the refresh token to be used as the MQTT password for the
    // renewal connection (mirrors the official app).
    if (!await _openAndConnect(_refreshToken)) return false;
    // Let the token-issuance subscription settle before asking for the token,
    // otherwise the response can be missed.
    await Future.delayed(const Duration(milliseconds: 800));
    final tok = await _client!.requestToken(_refreshToken!);
    if (tok == null || tok['accesstoken'] == null) return false;
    await _saveToken(tok);
    if (await _openAndConnect(_accessToken)) {
      _finishConnected();
      return true;
    }
    return false;
  }

  /// Begin pairing: shows the PIN on the TV. Caller then collects the PIN.
  void startPairing() {
    _client?.startPairing();
    _setConn(ConnState.needsPairing);
  }

  /// Submit the PIN shown on the TV. Returns true on success (token saved).
  Future<bool> submitPin(String pin) async {
    final tok = await _client?.submitPin(pin);
    if (tok != null && tok['accesstoken'] != null) {
      await _saveToken(tok);
      // Reconnect with the token for full ACL access.
      _client?.disconnect();
      await Future.delayed(const Duration(milliseconds: 400));
      await connect();
      return isConnected;
    }
    return false;
  }

  // --- command surface used by the UI ---
  void key(String k) => _client?.sendKey(k);
  void volumeUp() => _client?.sendKey('KEY_VOLUMEUP');
  void volumeDown() => _client?.sendKey('KEY_VOLUMEDOWN');
  void mute() => _client?.sendKey('KEY_MUTE');
  void power() => _client?.sendKey('KEY_POWER');
  void changeSource(String id) => _client?.changeSource(id);
  void launchApp(Map<String, dynamic> app) => _client?.launchApp(app);
  void refresh() {
    _client?.getState();
    _client?.getVolume();
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }
}

/// The TV client certificate or key is absent, empty, or a placeholder.
///
/// Its own type so the UI can say "the TV credentials are not set up" rather
/// than surfacing a TLS handshake failure from several layers down.
class TvCredentialsMissing implements Exception {
  TvCredentialsMissing(this.message);
  final String message;
  @override
  String toString() => 'TV credentials missing: $message';
}
