import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart' show CameraSettings;
import 'config_service.dart';

/// One lens the phone is willing to open, as reported by `/info.json`.
class PhoneLens {
  final String id;
  final String label;
  final String facing;
  final double minZoom;
  final double maxZoom;

  const PhoneLens({
    required this.id,
    required this.label,
    required this.facing,
    required this.minZoom,
    required this.maxZoom,
  });

  factory PhoneLens.fromJson(Map<String, dynamic> j) {
    final zoom = j['zoom'] as Map<String, dynamic>? ?? const {};
    double num0(Object? v, double fallback) =>
        double.tryParse('${v ?? ''}') ?? fallback;
    return PhoneLens(
      id: '${j['id'] ?? ''}',
      label: j['label'] as String? ?? 'Lens ${j['id']}',
      facing: j['facing'] as String? ?? '',
      minZoom: num0(zoom['min'], 1.0),
      maxZoom: num0(zoom['max'], 10.0),
    );
  }
}

/// The phone's own status, shown alongside the picture so it's obvious when
/// it's about to run out of battery or has wandered out of WiFi range.
class PhoneStatus {
  final List<PhoneLens> lenses;
  final int? batteryPercent;
  final int? wifiStrength;

  /// What the phone is currently set to, so we only send the settings that
  /// actually need changing.
  final String? currentCameraId;
  final String? currentStreamRes;

  const PhoneStatus({
    this.lenses = const [],
    this.batteryPercent,
    this.wifiStrength,
    this.currentCameraId,
    this.currentStreamRes,
  });
}

/// Talks to the phone running android-ip-camera.
///
/// Two things go over the wire and this service only handles one of them: the
/// picture itself is an H.264 stream opened directly by media_kit (see
/// [CameraOverlay]), because handing libmpv a URL is far cheaper than pulling
/// frames through Dart. Everything else — zoom, lens changes, the torch,
/// battery — is small JSON/query-string traffic and lives here.
///
/// The control protocol is unusual and worth stating plainly: the app treats
/// *any* request carrying a query string as a control command, whatever the
/// path, and answers `OK`. So zoom is `GET /?zoom=5.0&ts=<millis>` — the `ts`
/// is a monotonic ordering token that makes the phone ignore commands that
/// arrive out of order, which matters when a pinch fires a burst of them.
/// Query strings therefore can *not* be hung off the stream URLs; doing so
/// gets an `OK` instead of a stream.
class CameraService extends ChangeNotifier {
  CameraService(this._config) {
    _config.addListener(_onConfigChanged);
    _zoom = settings.defaultZoom;
    _cameraId = settings.cameraId;
  }

  final ConfigService _config;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 4),
    receiveTimeout: const Duration(seconds: 5),
  ));

  CameraSettings get settings => _config.config.camera;
  bool get isConfigured => settings.isConfigured;

  /// Whether the camera view is on screen. The stream is only opened while
  /// this is true, so the phone isn't encoding (and draining its battery)
  /// around the clock.
  bool _open = false;
  bool get isOpen => _open;

  bool _expanded = false;
  bool get isExpanded => _expanded;

  double _zoom = 1.0;
  double get zoom => _zoom;

  String _cameraId = '0';
  String get cameraId => _cameraId;

  bool _torch = false;
  bool get torch => _torch;

  PhoneStatus? _status;
  PhoneStatus? get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  Timer? _zoomDebounce;
  double? _pendingZoom;
  Timer? _statusTimer;

  void _onConfigChanged() {
    // A change of address/credentials invalidates anything already fetched.
    _status = null;
    if (!isConfigured && _open) close();
    notifyListeners();
  }

  /// Completes once the phone has been put into the state this view expects.
  /// The picture must not be opened before then: selecting the lens restarts
  /// the camera, and a stream opened across that restart keeps the geometry
  /// it saw first.
  Future<void>? _ready;
  Future<void>? get ready => _ready;

  void open() {
    if (!isConfigured || _open) return;
    _open = true;
    _zoom = settings.defaultZoom;
    _cameraId = settings.cameraId;
    _lastError = null;
    notifyListeners();
    _ready = _applyStartupState();
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(refreshStatus()));
  }

  void close() {
    if (!_open) return;
    _open = false;
    _expanded = false;
    _statusTimer?.cancel();
    _statusTimer = null;
    _zoomDebounce?.cancel();
    // Leave the torch on and it stays on with nobody watching.
    if (_torch) unawaited(setTorch(false));
    notifyListeners();
  }

  void toggleOpen() => _open ? close() : open();

  void setExpanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    notifyListeners();
  }

  /// Put the phone into the state this view expects before the stream opens.
  Future<void> _applyStartupState() async {
    await refreshStatus();
    final now = _status;
    if (now?.currentStreamRes != settings.streamResolution) {
      await _get('/settings/video_size?set=${settings.streamResolution}');
      // Changing the size restarts capture; let it come back before the
      // stream is opened.
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    await _get('/settings/orientation?set=landscape');
  }

  Future<void> refreshStatus() async {
    if (!isConfigured) return;
    try {
      final r = await _dio.getUri<Map<String, dynamic>>(
        Uri.parse('${settings.baseUrl}/status.json'),
        options: Options(responseType: ResponseType.json),
      );
      final data = r.data ?? const <String, dynamic>{};
      final cur = data['curvals'] as Map<String, dynamic>? ?? const {};
      final front = '${cur['ffc']}' == 'on';
      _torch = '${cur['torch']}' == 'on';
      _cameraId = front ? 'front' : 'back';
      _status = PhoneStatus(
        // IP Webcam exposes one back and one front camera, switched with the
        // front-facing-camera flag rather than by id.
        lenses: const [
          PhoneLens(
              id: 'back',
              label: 'Back',
              facing: 'back',
              minZoom: 1.0,
              maxZoom: 10.0),
          PhoneLens(
              id: 'front',
              label: 'Front',
              facing: 'front',
              minZoom: 1.0,
              maxZoom: 10.0),
        ],
        currentCameraId: _cameraId,
        currentStreamRes: cur['video_size'] as String?,
      );
      _lastError = null;
    } catch (e) {
      _lastError = 'Camera unreachable';
      debugPrint('CameraService: /info.json failed: $e');
    }
    notifyListeners();
  }

  /// Zoom range of the lens currently selected, falling back to the
  /// configured ceiling until `/info.json` has been read.
  double get minZoom =>
      _status?.lenses
          .cast<PhoneLens?>()
          .firstWhere((l) => l?.id == _cameraId, orElse: () => null)
          ?.minZoom ??
      1.0;

  double get maxZoom {
    final lens = _status?.lenses
        .cast<PhoneLens?>()
        .firstWhere((l) => l?.id == _cameraId, orElse: () => null);
    return lens?.maxZoom ?? settings.maxZoom;
  }

  /// Ask the phone to zoom. Pinches produce a stream of these, so the value
  /// is shown immediately but only the latest is actually sent, ~120ms apart.
  void setZoom(double value) {
    final clamped = value.clamp(minZoom, maxZoom).toDouble();
    if ((clamped - _zoom).abs() < 0.01) return;
    _zoom = clamped;
    notifyListeners();

    _pendingZoom = clamped;
    if (_zoomDebounce?.isActive ?? false) return;
    _zoomDebounce = Timer(const Duration(milliseconds: 120), () {
      final z = _pendingZoom;
      _pendingZoom = null;
      // IP Webcam counts zoom in percent of the sensor's range, 100 being 1x.
      if (z != null) unawaited(_get('/ptz?zoom=${(z * 100).round()}'));
    });
  }

  Future<void> selectCamera(String id) async {
    if (_cameraId == id) return;
    _cameraId = id;
    _zoom = 1.0;
    notifyListeners();
    await _get('/settings/ffc?set=${id == 'front' ? 'on' : 'off'}');
  }

  Future<void> setTorch(bool on) async {
    _torch = on;
    notifyListeners();
    await _get(on ? '/enabletorch' : '/disabletorch');
  }

  /// Every control is a plain GET; IP Webcam answers each with a small XML
  /// result we have no use for.
  Future<void> _get(String path) async {
    if (!isConfigured) return;
    try {
      await _dio.getUri<String>(
        Uri.parse('${settings.baseUrl}$path'),
        options: Options(responseType: ResponseType.plain),
      );
      _lastError = null;
    } catch (e) {
      _lastError = 'Camera unreachable';
      debugPrint('CameraService: $path failed: $e');
      notifyListeners();
    }
  }

  /// URL media_kit opens for the picture: H.264 over RTSP.
  ///
  /// IP Webcam also serves MJPEG, but at 20fps it costs 180 Mbit/s — it sends
  /// near-lossless JPEGs — where this is a fraction of that. It also tags the
  /// stream with the sensor's rotation, so mpv turns the picture the right way
  /// up by itself; nothing here has to know which way the phone is lying.
  String get streamUrl {
    final host = settings.address.split(':').first;
    final port = settings.address.contains(':')
        ? settings.address.split(':').last
        : '8080';
    return 'rtsp://$host:$port/h264_ulaw.sdp';
  }

  @override
  void dispose() {
    _config.removeListener(_onConfigChanged);
    _zoomDebounce?.cancel();
    _statusTimer?.cancel();
    _dio.close(force: true);
    super.dispose();
  }
}
