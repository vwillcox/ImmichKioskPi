import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Which part of the test is running.
enum SpeedtestPhase { idle, starting, ping, download, upload, done, failed }

/// A snapshot of a test in progress, or of the last completed one.
///
/// Immutable and replaced wholesale on each update, so a widget rebuilding
/// mid-test can never read a half-updated set of numbers.
@immutable
class SpeedtestState {
  const SpeedtestState({
    this.phase = SpeedtestPhase.idle,
    this.downloadMbps = 0,
    this.uploadMbps = 0,
    this.latencyMs,
    this.jitterMs,
    this.packetLoss,
    this.progress = 0,
    this.isp = '',
    this.serverName = '',
    this.serverLocation = '',
    this.resultUrl = '',
    this.error,
    this.finishedAt,
  });

  final SpeedtestPhase phase;

  /// Live during the download phase, then the final figure.
  final double downloadMbps;
  final double uploadMbps;

  final double? latencyMs;
  final double? jitterMs;
  final double? packetLoss;

  /// 0–1 through the *current* phase, not the test as a whole — the CLI
  /// reports it per phase and pretending otherwise would make the bar jump.
  final double progress;

  final String isp;
  final String serverName;
  final String serverLocation;
  final String resultUrl;

  final String? error;
  final DateTime? finishedAt;

  bool get running =>
      phase != SpeedtestPhase.idle &&
      phase != SpeedtestPhase.done &&
      phase != SpeedtestPhase.failed;

  bool get hasResult => downloadMbps > 0 || uploadMbps > 0;

  SpeedtestState copyWith({
    SpeedtestPhase? phase,
    double? downloadMbps,
    double? uploadMbps,
    double? latencyMs,
    double? jitterMs,
    double? packetLoss,
    double? progress,
    String? isp,
    String? serverName,
    String? serverLocation,
    String? resultUrl,
    String? error,
    DateTime? finishedAt,
  }) {
    return SpeedtestState(
      phase: phase ?? this.phase,
      downloadMbps: downloadMbps ?? this.downloadMbps,
      uploadMbps: uploadMbps ?? this.uploadMbps,
      latencyMs: latencyMs ?? this.latencyMs,
      jitterMs: jitterMs ?? this.jitterMs,
      packetLoss: packetLoss ?? this.packetLoss,
      progress: progress ?? this.progress,
      isp: isp ?? this.isp,
      serverName: serverName ?? this.serverName,
      serverLocation: serverLocation ?? this.serverLocation,
      resultUrl: resultUrl ?? this.resultUrl,
      error: error,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }
}

/// Runs Ookla's `speedtest` CLI and reports its progress as it goes.
///
/// The CLI's `--format=jsonl` mode emits one JSON object per line while the
/// test runs — ping samples, then download, then upload, then a final result
/// — which is what makes a live display possible at all. The alternative,
/// `--format=json`, prints nothing until the test is over.
///
/// Bandwidth arrives as **bytes per second**, so everything here converts to
/// megabits with `× 8 ÷ 1e6`. Getting that wrong is the classic way to report
/// a connection as one eighth of its real speed.
class SpeedtestService extends ChangeNotifier {
  SpeedtestService();

  /// Where the CLI is looked for, in order. `~/.local/bin` first because it
  /// installs there without root, which is how it got onto this Pi.
  static const List<String> _candidates = [
    '.local/bin/speedtest',
    '/usr/bin/speedtest',
    '/usr/local/bin/speedtest',
  ];

  SpeedtestState _state = const SpeedtestState();
  SpeedtestState get state => _state;

  Process? _process;
  StreamSubscription<String>? _lines;
  String? _binary;

  /// The CLI's path, or null if it isn't installed.
  Future<String?> findBinary() async {
    if (_binary != null) return _binary;
    final home = Platform.environment['HOME'] ?? '';
    for (final c in _candidates) {
      final path = c.startsWith('/') ? c : '$home/$c';
      if (await File(path).exists()) return _binary = path;
    }
    // Last resort: whatever is on PATH, which may be the Debian-packaged
    // `speedtest-cli` rather than Ookla's — different output entirely, so it
    // is deliberately not treated as equivalent above.
    try {
      final which = await Process.run('which', ['speedtest']);
      if (which.exitCode == 0) {
        final path = (which.stdout as String).trim();
        if (path.isNotEmpty) return _binary = path;
      }
    } catch (_) {}
    return null;
  }

  void _emit(SpeedtestState s) {
    _state = s;
    notifyListeners();
  }

  /// Starts a test. Does nothing if one is already running.
  Future<void> run() async {
    if (_state.running) return;

    final binary = await findBinary();
    if (binary == null) {
      _emit(const SpeedtestState(
        phase: SpeedtestPhase.failed,
        error: 'speedtest is not installed — see moreinfo.md',
      ));
      return;
    }

    // Deliberately keeps the previous figures on screen until the new ones
    // arrive: blanking the dial the instant you tap it looks like a fault.
    _emit(_state.copyWith(
      phase: SpeedtestPhase.starting,
      progress: 0,
      error: null,
    ));

    try {
      _process = await Process.start(binary, [
        '--format=jsonl',
        // Both are recorded permanently on first acceptance; passing them
        // every time keeps a fresh install from hanging on a prompt nobody
        // can answer on a wall panel.
        '--accept-license',
        '--accept-gdpr',
      ]);
    } catch (e) {
      _emit(_state.copyWith(
          phase: SpeedtestPhase.failed, error: 'could not start speedtest: $e'));
      return;
    }

    // stderr is drained but ignored: the CLI writes progress bars and licence
    // text there, and an unread pipe eventually blocks the child.
    unawaited(_process!.stderr.drain<void>().catchError((_) {}));

    _lines = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: (Object e) {
      _emit(_state.copyWith(
          phase: SpeedtestPhase.failed, error: 'speedtest failed: $e'));
    });

    final code = await _process!.exitCode;
    await _lines?.cancel();
    _lines = null;
    _process = null;

    if (code != 0 && _state.phase != SpeedtestPhase.done) {
      _emit(_state.copyWith(
        phase: SpeedtestPhase.failed,
        error: 'speedtest exited with code $code',
      ));
    }
  }

  /// Stops a running test and leaves the last figures on screen.
  void cancel() {
    _process?.kill();
    if (_state.running) {
      _emit(_state.copyWith(phase: SpeedtestPhase.idle, progress: 0));
    }
  }

  static double _mbps(Object? bandwidth) {
    final b = (bandwidth as num?)?.toDouble() ?? 0;
    return b * 8 / 1000000;
  }

  static double? _num(Object? v) => (v as num?)?.toDouble();

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> j;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;
      j = decoded;
    } catch (_) {
      // The CLI prints its licence banner on first run as plain text. Not an
      // error, just not a measurement.
      return;
    }

    switch (j['type']) {
      case 'testStart':
        final server = j['server'] as Map<String, dynamic>? ?? const {};
        _emit(_state.copyWith(
          phase: SpeedtestPhase.ping,
          isp: '${j['isp'] ?? ''}',
          serverName: '${server['name'] ?? ''}',
          serverLocation: '${server['location'] ?? ''}',
          downloadMbps: 0,
          uploadMbps: 0,
          progress: 0,
        ));

      case 'ping':
        final p = j['ping'] as Map<String, dynamic>? ?? const {};
        _emit(_state.copyWith(
          phase: SpeedtestPhase.ping,
          latencyMs: _num(p['latency']),
          jitterMs: _num(p['jitter']),
          progress: _num(p['progress']) ?? 0,
        ));

      case 'download':
        final d = j['download'] as Map<String, dynamic>? ?? const {};
        _emit(_state.copyWith(
          phase: SpeedtestPhase.download,
          downloadMbps: _mbps(d['bandwidth']),
          progress: _num(d['progress']) ?? 0,
        ));

      case 'upload':
        final u = j['upload'] as Map<String, dynamic>? ?? const {};
        _emit(_state.copyWith(
          phase: SpeedtestPhase.upload,
          uploadMbps: _mbps(u['bandwidth']),
          progress: _num(u['progress']) ?? 0,
        ));

      case 'result':
        final d = j['download'] as Map<String, dynamic>? ?? const {};
        final u = j['upload'] as Map<String, dynamic>? ?? const {};
        final p = j['ping'] as Map<String, dynamic>? ?? const {};
        final r = j['result'] as Map<String, dynamic>? ?? const {};
        _emit(_state.copyWith(
          phase: SpeedtestPhase.done,
          // The final figures, which differ slightly from the last progress
          // sample — that one is an instantaneous rate, these are the run.
          downloadMbps: _mbps(d['bandwidth']),
          uploadMbps: _mbps(u['bandwidth']),
          latencyMs: _num(p['latency']),
          jitterMs: _num(p['jitter']),
          packetLoss: _num(j['packetLoss']),
          resultUrl: '${r['url'] ?? ''}',
          progress: 1,
          finishedAt: DateTime.now(),
        ));

      case 'error':
        _emit(_state.copyWith(
          phase: SpeedtestPhase.failed,
          error: '${j['message'] ?? 'speedtest reported an error'}',
        ));
    }
  }

  @override
  void dispose() {
    _process?.kill();
    _lines?.cancel();
    super.dispose();
  }
}
