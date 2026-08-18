import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

enum LanPhase { idle, download, upload, done, failed }

/// A LAN speed test against a self-hosted OpenSpeedTest server.
///
/// Separate from the Ookla widget on purpose: that one measures the path to
/// the internet, this measures the path to a machine in the house. On a
/// gigabit-plus LAN they answer completely different questions, and the second
/// is the one that tells you whether a cable, a switch port or the Pi's own
/// adapter is the bottleneck.
///
/// Measured here rather than by opening OpenSpeedTest's own page in a browser.
/// The page would work, but it would measure the *browser's* throughput on a
/// Pi with no hardware acceleration, and report Chromium's limits as the
/// network's. Reading the same endpoints directly measures the link.
@immutable
class LanSpeedtestState {
  const LanSpeedtestState({
    this.phase = LanPhase.idle,
    this.downloadMbps = 0,
    this.uploadMbps = 0,
    this.progress = 0,
    this.error,
    this.finishedAt,
  });

  final LanPhase phase;
  final double downloadMbps;
  final double uploadMbps;

  /// 0–1 through the current phase.
  final double progress;

  final String? error;
  final DateTime? finishedAt;

  bool get running => phase == LanPhase.download || phase == LanPhase.upload;
  bool get hasResult => downloadMbps > 0 || uploadMbps > 0;

  LanSpeedtestState copyWith({
    LanPhase? phase,
    double? downloadMbps,
    double? uploadMbps,
    double? progress,
    String? error,
    DateTime? finishedAt,
  }) =>
      LanSpeedtestState(
        phase: phase ?? this.phase,
        downloadMbps: downloadMbps ?? this.downloadMbps,
        uploadMbps: uploadMbps ?? this.uploadMbps,
        progress: progress ?? this.progress,
        error: error,
        finishedAt: finishedAt ?? this.finishedAt,
      );
}

class LanSpeedtestService extends ChangeNotifier {
  LanSpeedtestService();

  LanSpeedtestState _state = const LanSpeedtestState();
  LanSpeedtestState get state => _state;

  bool _cancelled = false;

  /// Several at once, because one TCP stream will not fill a 2.5 Gb link:
  /// a single connection is limited by window size and round-trip time long
  /// before the wire is busy.
  static const int _streams = 4;

  /// Long enough to get past TCP slow start, short enough that nobody walks
  /// away. A single 30 MiB fetch finishes in a third of a second on this
  /// network, which measures the ramp rather than the rate.
  static const Duration _phase = Duration(seconds: 6);

  void _emit(LanSpeedtestState s) {
    _state = s;
    notifyListeners();
  }

  void cancel() {
    _cancelled = true;
    if (_state.running) {
      _emit(_state.copyWith(phase: LanPhase.idle, progress: 0));
    }
  }

  /// Runs both phases against [baseUrl], e.g. `http://10.0.0.218:3000`.
  Future<void> run(String baseUrl) async {
    if (_state.running) return;
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      _emit(const LanSpeedtestState(
          phase: LanPhase.failed, error: 'No server address set'));
      return;
    }

    _cancelled = false;
    // Previous figures stay up until new ones arrive: blanking the dial the
    // moment you tap it looks like a fault.
    _emit(_state.copyWith(phase: LanPhase.download, progress: 0, error: null));

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 5);

    try {
      final down = await _measure(
        client: client,
        phase: LanPhase.download,
        run: (c, stop) => _downloadStream(c, base, stop),
      );
      if (_cancelled) return;
      _emit(_state.copyWith(
          phase: LanPhase.upload, downloadMbps: down, progress: 0));

      final up = await _measure(
        client: client,
        phase: LanPhase.upload,
        run: (c, stop) => _uploadStream(c, base, stop),
      );
      if (_cancelled) return;

      _emit(_state.copyWith(
        phase: LanPhase.done,
        downloadMbps: down,
        uploadMbps: up,
        progress: 1,
        finishedAt: DateTime.now(),
      ));
    } catch (e) {
      if (!_cancelled) {
        _emit(_state.copyWith(
            phase: LanPhase.failed, error: _readable(e), progress: 0));
      }
    } finally {
      client.close(force: true);
    }
  }

  static String _readable(Object e) {
    final s = '$e';
    if (s.contains('Connection refused')) {
      return 'Nothing answering — is the server running?';
    }
    if (s.contains('No route to host') || s.contains('Network is unreachable')) {
      return 'Cannot reach that address from here';
    }
    if (e is TimeoutException) return 'The server stopped responding';
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  /// Runs [_streams] copies of [run] for [_phase], reporting the rate as it
  /// goes, and returns the overall megabits per second.
  Future<double> _measure({
    required HttpClient client,
    required LanPhase phase,
    required Future<void> Function(HttpClient, Completer<void>) run,
  }) async {
    var bytes = 0;
    final started = DateTime.now();
    final stop = Completer<void>();

    // The counter is shared; each stream adds to it as data moves.
    _bytes = 0;

    final ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_cancelled) return;
      final elapsed = DateTime.now().difference(started);
      if (elapsed.inMilliseconds < 300) return;
      final mbps = _bytes * 8 / elapsed.inMicroseconds;
      _emit(_state.copyWith(
        phase: phase,
        progress: (elapsed.inMilliseconds / _phase.inMilliseconds).clamp(0, 1),
        downloadMbps: phase == LanPhase.download ? mbps : _state.downloadMbps,
        uploadMbps: phase == LanPhase.upload ? mbps : _state.uploadMbps,
      ));
    });

    final timer = Timer(_phase, () {
      if (!stop.isCompleted) stop.complete();
    });

    try {
      await Future.wait([
        for (var i = 0; i < _streams; i++) run(client, stop),
      ]);
    } finally {
      ticker.cancel();
      timer.cancel();
      if (!stop.isCompleted) stop.complete();
      bytes = _bytes;
    }

    final elapsed = DateTime.now().difference(started);
    if (elapsed.inMicroseconds == 0) return 0;
    return bytes * 8 / elapsed.inMicroseconds;
  }

  int _bytes = 0;

  Future<void> _downloadStream(
      HttpClient client, String base, Completer<void> stop) async {
    final rng = Random();
    while (!stop.isCompleted && !_cancelled) {
      final req = await client
          .getUrl(Uri.parse('$base/downloading?r=${rng.nextDouble()}'));
      final resp = await req.close();
      await for (final chunk in resp) {
        _bytes += chunk.length;
        if (stop.isCompleted || _cancelled) {
          // Draining would keep pulling the rest of a 30 MiB body after the
          // clock has stopped, which both wastes the link and skews nothing
          // useful. Dropping the connection is the honest end.
          break;
        }
      }
    }
  }

  Future<void> _uploadStream(
      HttpClient client, String base, Completer<void> stop) async {
    // One buffer, sent repeatedly. Generating fresh random data per chunk
    // would measure the Pi's random number generator as much as its network.
    final block = Uint8List(256 * 1024);
    final rng = Random();
    for (var i = 0; i < block.length; i += 4096) {
      block[i] = rng.nextInt(256);
    }

    while (!stop.isCompleted && !_cancelled) {
      final req = await client
          .postUrl(Uri.parse('$base/upload?r=${rng.nextDouble()}'));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      req.headers.chunkedTransferEncoding = true;

      // Roughly 16 MiB per request, or until the clock stops.
      for (var sent = 0; sent < 64; sent++) {
        if (stop.isCompleted || _cancelled) break;
        req.add(block);
        _bytes += block.length;
        // Lets the socket actually drain rather than queueing the whole lot
        // in memory and calling it throughput.
        await req.flush();
      }
      await req.close();
    }
  }
}
