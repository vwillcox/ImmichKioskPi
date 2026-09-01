import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'audio_analyser.dart';
import 'retry_schedule.dart';

/// A stream of raw PCM, and the way to shut it off again.
class PcmStream {
  PcmStream({required this.bytes, required this.stop});

  /// Signed 16-bit little-endian mono samples, in whatever sized chunks the
  /// source cares to deliver them.
  final Stream<List<int>> bytes;

  /// Stops the source and releases the device.
  final Future<void> Function() stop;
}

/// Opens a PCM source. Injectable so the service can be tested without audio.
typedef PcmSourceOpener = Future<PcmStream> Function();

/// Live levels for whatever is coming out of this device's speaker.
///
/// Captures the default sink's *monitor* — the mix on its way out — rather
/// than a microphone, so it hears the phone over Bluetooth, librespot, the
/// share-inbox chime and the announcements, all at the level they are actually
/// being played at. It hears nothing at all when the audio is not on this
/// device: with "play the audio on this device" off, or with Spotify handed to
/// some other speaker, the music never passes through this sink and the bars
/// stay down. That is honest rather than broken — there is genuinely no signal
/// here to show.
///
/// Nothing runs until something asks to see it. [attach] and [detach] count
/// viewers, and the capture process only exists while that count is above
/// zero: no subprocess, no PipeWire link, no FFT and no repainting while the
/// visualiser is off-screen, collapsed, or switched off in settings.
class AudioLevelsService extends ChangeNotifier {
  AudioLevelsService({AudioAnalyser? analyser, PcmSourceOpener? open})
      : _analyser = analyser ?? AudioAnalyser(),
        _open = open ?? _capturePipeWireSink;

  final AudioAnalyser _analyser;
  final PcmSourceOpener _open;

  /// How often listeners are told, at most. The capture delivers frames faster
  /// than this; a wall panel does not need more than thirty a second.
  static const Duration frameInterval = Duration(milliseconds: 33);

  /// Sample format asked of the capture. Mono is enough — a stereo image adds
  /// nothing to a bar chart and doubles the arithmetic.
  static const int sampleRate = 16000;

  int _viewers = 0;
  int _generation = 0;
  PcmStream? _source;
  StreamSubscription<List<int>>? _sub;
  Timer? _retry;
  Timer? _idle;
  DateTime _lastNotified = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasSilent = true;
  bool _supported = true;
  String? _error;

  final _pending = BytesBuilder(copy: false);
  final RetrySchedule _schedule =
      RetrySchedule(settled: const Duration(seconds: 5));

  /// Band levels, 0–1. All zero when nothing is playing or nothing is running.
  List<double> get levels => _analyser.levels;

  /// The current frame's shape, −1–1.
  List<double> get wave => _analyser.wave;

  /// Whether capture is running right now.
  bool get running => _sub != null;

  /// Whether this machine can capture at all.
  ///
  /// False once the capture command turns out not to exist — a development
  /// machine that is not the Pi — after which nothing is retried and callers
  /// can hide the visualiser rather than showing a permanently flat one.
  bool get supported => _supported;

  /// Why capture failed, if it did.
  String? get error => _error;

  /// Ask for levels. Balanced by [detach].
  void attach() {
    _viewers++;
    if (_viewers == 1) unawaited(_start());
  }

  /// Stop asking. The capture ends when the last viewer leaves.
  void detach() {
    if (_viewers == 0) return;
    _viewers--;
    if (_viewers == 0) unawaited(_stop());
  }

  Future<void> _start() async {
    if (!_supported || _sub != null) return;
    _retry?.cancel();
    final generation = ++_generation;
    try {
      final source = await _open();
      // Detached again while the process was starting.
      if (generation != _generation || _viewers == 0) {
        await source.stop();
        return;
      }
      _source = source;
      _error = null;
      _sub = source.bytes.listen(
        _onBytes,
        onError: (Object e) => _lost('$e'),
        onDone: () => _lost('capture ended'),
        cancelOnError: false,
      );
      // Nothing arriving means silence, not a stall: without this the bars
      // would freeze at whatever height the last frame left them.
      _idle = Timer.periodic(frameInterval * 6, (_) => _fade());
      notifyListeners();
    } on ProcessException catch (e) {
      // The command is missing — this is not a Pi. Say so once and stop.
      _supported = false;
      _error = e.message;
      notifyListeners();
    } catch (e) {
      _lost('$e');
    }
  }

  Future<void> _stop() async {
    _generation++;
    _retry?.cancel();
    _retry = null;
    _idle?.cancel();
    _idle = null;
    final sub = _sub;
    _sub = null;
    final source = _source;
    _source = null;
    _pending.clear();
    _analyser.reset();
    _wasSilent = true;
    await sub?.cancel();
    await source?.stop();
    notifyListeners();
  }

  /// The capture died — PipeWire restarted, the sink changed underneath it.
  /// Try again on the shared backoff, but only while somebody is watching.
  void _lost(String reason) {
    if (_retry != null) return;
    _error = reason;
    unawaited(_stop().then((_) {
      if (_viewers == 0 || !_supported) return;
      _retry = Timer(_schedule.next(hasContent: false), () {
        _retry = null;
        if (_viewers > 0) unawaited(_start());
      });
    }));
  }

  void _onBytes(List<int> chunk) {
    _schedule.reset();
    _pending.add(chunk);
    final frameBytes = _analyser.frameSamples * 2;
    if (_pending.length < frameBytes) return;

    // Take everything waiting and analyse only the newest whole frame. If the
    // UI thread was busy and several frames piled up, drawing the oldest would
    // put the bars behind the music; the backlog is dropped on purpose.
    final all = _pending.takeBytes();
    final whole = all.length ~/ frameBytes;
    final start = (whole - 1) * frameBytes;
    _analyser.analyse(_samples(all, start));
    final leftover = all.length - whole * frameBytes;
    if (leftover > 0) {
      _pending.add(Uint8List.sublistView(all, whole * frameBytes));
    }
    _maybeNotify();
  }

  /// Unpack one frame of little-endian 16-bit samples.
  ///
  /// Read a pair of bytes at a time rather than casting the buffer to an
  /// [Int16List] view: the view would need the chunk to arrive two-byte
  /// aligned and the host to be little-endian, and neither is this code's to
  /// promise. Five hundred reads thirty times a second is not worth the risk.
  Int16List _samples(Uint8List all, int start) {
    final data = ByteData.sublistView(all, start);
    final out = Int16List(_analyser.frameSamples);
    for (var i = 0; i < out.length; i++) {
      out[i] = data.getInt16(i * 2, Endian.little);
    }
    return out;
  }

  /// No audio arrived recently — let the bars fall rather than hang.
  void _fade() {
    if (_analyser.silent) return;
    _analyser.decay();
    _maybeNotify();
  }

  void _maybeNotify() {
    final silent = _analyser.silent;
    // A silence needs one frame to settle the bars at zero, then nothing more.
    // Repainting a flat chart thirty times a second is exactly the waste this
    // whole design is trying to avoid.
    if (silent && _wasSilent) return;
    final now = DateTime.now();
    if (!silent && now.difference(_lastNotified) < frameInterval) return;
    _lastNotified = now;
    _wasSilent = silent;
    notifyListeners();
  }

  @override
  void dispose() {
    _viewers = 0;
    unawaited(_stop());
    super.dispose();
  }

  /// Capture the default sink's monitor through PipeWire.
  ///
  /// `stream.capture.sink` is the whole trick: without it `pw-record` opens the
  /// default *source*, which on this Pi is the USB speaker's microphone, and
  /// the bars would dance to the room instead of the music. With no `--target`
  /// it follows whatever the default sink is at the time, so switching output
  /// does not need the capture restarting.
  static Future<PcmStream> _capturePipeWireSink() async {
    final process = await Process.start(
      'pw-record',
      [
        '--channels=1',
        '--rate=$sampleRate',
        '--format=s16',
        '--latency=20ms',
        '-',
      ],
      environment: {'PIPEWIRE_PROPS': '{ stream.capture.sink=true }'},
    );
    // Drained so a chatty build of pw-record cannot fill its pipe and wedge.
    unawaited(process.stderr.drain<void>().catchError((_) {}));
    return PcmStream(
      bytes: process.stdout,
      stop: () async {
        process.kill();
        await process.exitCode;
      },
    );
  }
}
