import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// Reverse-engineered constants (from libmqttcrypt.so / pyvidaa).
const String kPattern = '38D65DC30F45109A369A86FCE866A85B';
const String kValueSuffixLegacy = 'h*i&s%e!r^v0i1c9';
const String kValueSuffixModern = 'h!i@s#\$v%i^d&a*a';
const int kTimeXorConstant = 0x56981477 * 0x100000000 + 0x2b03a968;

enum AuthMethod { legacy, middle, modern }

String _md5Upper(String s) =>
    md5.convert(utf8.encode(s)).toString().toUpperCase();

int _sumDigits(int n) =>
    n.abs().toString().split('').fold(0, (a, c) => a + int.parse(c));

class VidaaCredentials {
  final String clientId;
  final String username;
  final String password;
  VidaaCredentials(this.clientId, this.username, this.password);
}

/// Ports hisense_tv/credentials.py generate_credentials().
VidaaCredentials generateCredentials(
  String uuid, {
  String brand = 'his',
  String operation = 'vidaacommon',
  int? timestamp,
  AuthMethod authMethod = AuthMethod.legacy,
}) {
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final race = '$kPattern\$$uuid';
  final raceMd5 = _md5Upper(race).substring(0, 6);
  final clientId = '$uuid\$$brand\$${raceMd5}_${operation}_001';

  final String username;
  if (authMethod == AuthMethod.legacy) {
    username = '$brand\$$ts';
  } else {
    username = '$brand\$${ts ^ kTimeXorConstant}';
  }

  final valueSuffix =
      authMethod == AuthMethod.modern ? kValueSuffixModern : kValueSuffixLegacy;
  final remainder = _sumDigits(ts) % 10;
  final value = '$brand$remainder$valueSuffix';
  final valueMd5 = _md5Upper(value).substring(0, 6);
  final password = _md5Upper('$ts\$$valueMd5');

  return VidaaCredentials(clientId, username, password);
}

/// One selectable input, as the television itself describes it.
///
/// The ids are not numbers: this set reports `TV`, `HDMI1`…`HDMI4`, `AVS`, and
/// a numeric id for the built-in VIDAA launcher. Guessing them does not work,
/// which is why the list is asked for rather than assumed.
class TvSource {
  TvSource({
    required this.id,
    required this.name,
    required this.deviceName,
    required this.hasSignal,
    required this.isActive,
  });

  final String id;

  /// What to call it — the TV's own display name, e.g. "HDMI1" or "AV".
  final String name;

  /// The connected device's name where the TV knows it, e.g. "Fire TV Stick".
  /// Empty when nothing has announced itself over CEC.
  final String deviceName;

  /// Something is plugged in and powered.
  ///
  /// From `has_signal` rather than `is_signal`: the latter is only true for
  /// the input currently on screen, so using it would show every other socket
  /// as empty regardless of what is attached.
  final bool hasSignal;

  /// This is the input currently showing.
  final bool isActive;

  /// True when the TV remembers a device here but sees nothing now — a name
  /// with no signal, typically something switched off at the wall.
  bool get knownButAsleep => !hasSignal && deviceName.isNotEmpty;

  static bool _flag(Object? v) => v == 1 || v == '1' || v == true;

  static TvSource? parse(Object? entry, {String? currentId}) {
    if (entry is! Map) return null;
    final id = '${entry['sourceid'] ?? ''}';
    if (id.isEmpty) return null;
    final display = '${entry['displayname'] ?? ''}';
    final source = '${entry['sourcename'] ?? ''}';
    return TvSource(
      id: id,
      name: display.isNotEmpty ? display : (source.isNotEmpty ? source : id),
      deviceName: '${entry['displayname2'] ?? ''}',
      hasSignal: _flag(entry['has_signal']) || _flag(entry['is_signal']),
      isActive: currentId != null && currentId == id,
    );
  }
}

/// Live TV state pushed from broadcast topics.
class TvState {
  String? sourceId;
  String? sourceName;
  int? volume;
  bool muted = false;
  bool powerOn = true;
  Map<String, dynamic> raw = {};

  /// The inputs the TV reports, in its own order. Empty until the first
  /// sourcelist reply arrives.
  List<TvSource> sources = const [];
}

typedef StateCallback = void Function(TvState state);
typedef PinCallback = void Function();
typedef LogCallback = void Function(String line);

/// Dart port of the Hisense VIDAA MQTT control client.
class VidaaClient {
  final String host;
  final int port;
  final String uuid;
  final String? certPath;
  final String? keyPath;
  final List<int>? certBytes;
  final List<int>? keyBytes;
  final AuthMethod authMethod;

  final StateCallback? onState;
  final PinCallback? onPinRequired;
  final LogCallback? onLog;

  MqttServerClient? _client;
  late String _clientId;
  final TvState state;

  String? accessToken;
  String? refreshToken;

  final _authAccepted = Completer<bool>();
  bool _authCompleterDone = false;
  Completer<Map<String, dynamic>>? _tokenWaiter;

  VidaaClient({
    required this.host,
    required this.uuid,
    this.port = 36669,
    this.certPath,
    this.keyPath,
    this.certBytes,
    this.keyBytes,
    this.authMethod = AuthMethod.legacy,
    this.accessToken,
    this.onState,
    this.onPinRequired,
    this.onLog,
    TvState? state,
  }) : state = state ?? TvState();

  void _log(String s) => onLog?.call(s);

  String get clientId => _clientId;

  // Command topics
  String _tvTopic(String svc, String action) =>
      '/remoteapp/tv/$svc/$_clientId/actions/$action';

  /// Connect with mutual TLS. Uses [accessToken] as password when available,
  /// otherwise the freshly generated dynamic password (needed for pairing).
  Future<bool> connect({Duration timeout = const Duration(seconds: 10)}) async {
    final creds = generateCredentials(uuid, authMethod: authMethod);
    _clientId = creds.clientId;

    final ctx = SecurityContext(withTrustedRoots: false);
    if (certBytes != null && keyBytes != null) {
      ctx.useCertificateChainBytes(certBytes!);
      ctx.usePrivateKeyBytes(keyBytes!);
    } else {
      ctx.useCertificateChain(certPath!);
      ctx.usePrivateKey(keyPath!);
    }

    final c = MqttServerClient.withPort(host, _clientId, port)
      ..secure = true
      ..securityContext = ctx
      ..onBadCertificate = ((Object cert) => true) // TV cert is self-signed
      ..keepAlivePeriod = 30
      ..autoReconnect = true
      ..logging(on: false);

    c.onConnected = () => _log('MQTT connected');
    c.onDisconnected = () => _log('MQTT disconnected');
    c.onSubscribeFail = (t) => _log('SUB FAIL $t');

    final password = accessToken ?? creds.password;
    final connMsg = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .authenticateAs(creds.username, password)
        .startClean();
    c.connectionMessage = connMsg;

    try {
      await c.connect().timeout(timeout);
    } catch (e) {
      _log('connect error: $e');
      c.disconnect();
      return false;
    }

    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      _log('not connected: ${c.connectionStatus?.returnCode}');
      return false;
    }

    _client = c;
    c.updates?.listen(_onMessages);
    _subscribeCore();
    return true;
  }

  void _subscribe(String topic) => _client?.subscribe(topic, MqttQos.atMostOnce);

  /// Exact client-specific topics the broker ACL allows (no wildcards).
  void _subscribeCore() {
    final base = '/remoteapp/mobile/$_clientId';
    for (final t in [
      '$base/ui_service/data/authentication',
      '$base/ui_service/data/authenticationcode',
      '$base/platform_service/data/tokenissuance',
      '$base/ui_service/data/gettvstate',
      '$base/platform_service/data/getvolume',
      '$base/platform_service/data/gettvinfo',
      '$base/ui_service/data/sourcelist',
      '$base/ui_service/data/applist',
      '/remoteapp/mobile/broadcast/ui_service/state',
      '/remoteapp/mobile/broadcast/platform_service/actions/volumechange',
    ]) {
      _subscribe(t);
    }
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final e in events) {
      final msg = e.payload as MqttPublishMessage;
      final payload =
          MqttPublishPayload.bytesToStringAsString(msg.payload.message);
      _log('[MSG] ${e.topic} -> ${payload.length > 200 ? payload.substring(0, 200) : payload}');
      _handle(e.topic, payload);
    }
  }

  void _handle(String topic, String payload) {
    Map<String, dynamic>? d;
    try {
      d = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {}

    if (topic.endsWith('/authenticationcode')) {
      if (d != null && d['result'] == 1 && !_authCompleterDone) {
        _authCompleterDone = true;
        _authAccepted.complete(true);
      }
    } else if (topic.endsWith('/tokenissuance')) {
      if (d != null && d['accesstoken'] != null) {
        accessToken = d['accesstoken'] as String;
        refreshToken = d['refreshtoken'] as String?;
        final w = _tokenWaiter;
        if (w != null && !w.isCompleted) w.complete(d);
      }
    } else if (topic.endsWith('/data/sourcelist')) {
      // A JSON array, not an object, so the decode above leaves d null —
      // which is why this reply was previously received and thrown away.
      _parseSourceList(payload);
    } else if (topic == '/remoteapp/mobile/broadcast/ui_service/state') {
      if (d != null) {
        state.raw = d;
        state.sourceId = d['sourceid']?.toString();
        state.sourceName = d['sourcename']?.toString();
        _remarkActive();
        onState?.call(state);
      }
    } else if (topic.endsWith('/actions/volumechange') ||
        topic.endsWith('/getvolume')) {
      if (d != null) {
        final vt = d['volume_type'];
        final vv = d['volume_value'];
        if (vt == 1 && vv is int) state.volume = vv;
        if (vt == 2) state.muted = (vv == 1);
        onState?.call(state);
      }
    }
  }

  void _parseSourceList(String payload) {
    try {
      final list = jsonDecode(payload);
      if (list is! List) return;
      final parsed = <TvSource>[];
      for (final e in list) {
        final s = TvSource.parse(e, currentId: state.sourceId);
        if (s != null) parsed.add(s);
      }
      // An empty reply is not an answer — keeping the previous list beats
      // blanking the inputs because one poll came back short.
      if (parsed.isEmpty) return;
      state.sources = parsed;
      onState?.call(state);
    } catch (e) {
      _log('could not read the source list: $e');
    }
  }

  /// Recomputes which cached source is the active one, without refetching.
  void _remarkActive() {
    if (state.sources.isEmpty) return;
    state.sources = [
      for (final s in state.sources)
        TvSource(
          id: s.id,
          name: s.name,
          deviceName: s.deviceName,
          hasSignal: s.hasSignal,
          isActive: s.id == state.sourceId,
        )
    ];
  }

  void _publish(String topic, String payload) {
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _client?.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
  }

  // ---- High-level commands ----
  void sendKey(String key) =>
      _publish(_tvTopic('remote_service', 'sendkey'), key);

  void getState() => _publish(_tvTopic('ui_service', 'gettvstate'), '');

  /// Asks the TV for its input list; the reply arrives on the sourcelist
  /// topic already subscribed to in [_subscribeCore].
  ///
  /// Costly in a way the name does not suggest: the set runs its
  /// authentication check when asked, which puts the pairing code up on the
  /// television. Call it on connect, where an auth exchange is happening
  /// anyway, and otherwise only when the user asks.
  void getSourceList() => _publish(_tvTopic('ui_service', 'sourcelist'), '');
  void getVolume() => _publish(_tvTopic('platform_service', 'getvolume'), '');
  void changeSource(String sourceId) => _publish(
      _tvTopic('ui_service', 'changesource'),
      jsonEncode({'sourceid': sourceId}));
  void launchApp(Map<String, dynamic> app) =>
      _publish(_tvTopic('ui_service', 'launchapp'), jsonEncode(app));

  // ---- Pairing ----
  /// Triggers the on-TV PIN dialog.
  void startPairing() {
    onPinRequired?.call();
    _publish(
        _tvTopic('ui_service', 'vidaa_app_connect'),
        jsonEncode(
            {'app_version': 2, 'connect_result': 0, 'device_type': 'Mobile App'}));
  }

  /// Sends the PIN, waits for acceptance + token. Returns the token map.
  Future<Map<String, dynamic>?> submitPin(String pin,
      {Duration timeout = const Duration(seconds: 12)}) async {
    _publish(_tvTopic('ui_service', 'authenticationcode'),
        jsonEncode({'authNum': int.parse(pin)}));
    try {
      await _authAccepted.future.timeout(timeout);
    } catch (_) {
      _log('PIN not accepted');
      return null;
    }
    return requestToken('', timeout: timeout);
  }

  /// Request a (new) access token. Empty [refresh] is used right after PIN
  /// acceptance; pass the stored refresh token to renew an expired session.
  Future<Map<String, dynamic>?> requestToken(String refresh,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final w = Completer<Map<String, dynamic>>();
    _tokenWaiter = w;
    // NB: gettoken lives under /data/ (not /actions/ like the other commands).
    _publish('/remoteapp/tv/platform_service/$_clientId/data/gettoken',
        jsonEncode({'refreshtoken': refresh}));
    try {
      return await w.future.timeout(timeout);
    } catch (_) {
      _log('no token');
      return null;
    }
  }

  void disconnect() => _client?.disconnect();
}
