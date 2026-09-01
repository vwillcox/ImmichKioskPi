import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/services/audio_analyser.dart';
import 'package:immich_kiosk_pi/services/audio_levels_service.dart';

/// One frame of a sine at [hz], full scale unless told otherwise.
Int16List tone(double hz, {int samples = 512, int rate = 16000, double amp = 1}) {
  final out = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = (32767 * amp * math.sin(2 * math.pi * hz * i / rate)).round();
  }
  return out;
}

/// The frame as the capture would deliver it: little-endian bytes.
List<int> bytesOf(Int16List frame) {
  final out = Uint8List(frame.length * 2);
  final data = ByteData.sublistView(out);
  for (var i = 0; i < frame.length; i++) {
    data.setInt16(i * 2, frame[i], Endian.little);
  }
  return out;
}

int loudest(List<double> levels) {
  var best = 0;
  for (var i = 1; i < levels.length; i++) {
    if (levels[i] > levels[best]) best = i;
  }
  return best;
}

void main() {
  group('analyser', () {
    test('a tone lands in one band and a higher tone lands in a later one', () {
      final low = AudioAnalyser()..analyse(tone(150));
      final high = AudioAnalyser()..analyse(tone(3000));
      expect(loudest(low.levels), lessThan(loudest(high.levels)));
    });

    test('a full-scale tone drives its band near the top', () {
      final a = AudioAnalyser()..analyse(tone(1000));
      expect(a.levels[loudest(a.levels)], greaterThan(0.8));
    });

    test('a tone leaves the bands either side of it alone', () {
      final a = AudioAnalyser()..analyse(tone(1000));
      final band = loudest(a.levels);
      expect(a.levels[band - 2], lessThan(0.5));
      expect(a.levels[band + 2], lessThan(0.5));
    });

    test('turning the volume down does not empty the bars', () {
      // The window follows the music, so a quiet source still reads — that is
      // the whole point of the adaptive reference.
      final a = AudioAnalyser();
      for (var i = 0; i < 60; i++) {
        a.analyse(tone(1000, amp: 0.02));
      }
      expect(a.levels[loudest(a.levels)], greaterThan(0.7));
      expect(a.referenceDb, greaterThanOrEqualTo(AudioAnalyser.minReferenceDb));
    });

    test('a silence does not wind the window up', () {
      final a = AudioAnalyser()..analyse(tone(1000));
      final settled = a.referenceDb;
      for (var i = 0; i < 300; i++) {
        a.analyse(Int16List(512));
      }
      expect(a.referenceDb, settled,
          reason: 'a gap between tracks must not become gain');
      expect(a.silent, isTrue);
    });

    test('the window stays inside its bounds', () {
      final loud = AudioAnalyser();
      for (var i = 0; i < 200; i++) {
        loud.analyse(tone(1000));
      }
      expect(loud.referenceDb,
          lessThanOrEqualTo(AudioAnalyser.maxReferenceDb + 0.001));
      final faint = AudioAnalyser();
      for (var i = 0; i < 600; i++) {
        faint.analyse(tone(1000, amp: 0.004));
      }
      expect(faint.referenceDb,
          greaterThanOrEqualTo(AudioAnalyser.minReferenceDb - 0.001));
    });

    test('silence reads as silent', () {
      final a = AudioAnalyser()..analyse(Int16List(512));
      expect(a.silent, isTrue);
      expect(a.levels.every((l) => l == 0), isTrue);
    });

    test('bars fall on their own rather than sticking', () {
      final a = AudioAnalyser()..analyse(tone(1000));
      expect(a.silent, isFalse);
      // A third of a second at ~31 frames a second.
      for (var i = 0; i < 40; i++) {
        a.decay();
      }
      expect(a.silent, isTrue);
    });

    test('a rise is instant and a fall is gradual', () {
      final a = AudioAnalyser()..analyse(tone(1000));
      final band = loudest(a.levels);
      final peak = a.levels[band];
      a.analyse(Int16List(512));
      // One silent frame must not wipe it out.
      expect(a.levels[band], closeTo(peak * AudioAnalyser.release, 0.01));
      a.analyse(tone(1000));
      expect(a.levels[band], closeTo(peak, 0.01));
    });

    test('the waveform fills the band, however loud the source', () {
      // Raw sample values off a speaker at a normal volume rarely pass a
      // third of full scale, so the waveform is scaled the way the bars are.
      double loudestOf(List<double> w) =>
          w.map((v) => v.abs()).reduce(math.max);
      for (final amp in [1.0, 0.3, 0.06]) {
        final a = AudioAnalyser();
        // Long enough for the slow release to reach a very quiet source; the
        // rise is quick, so the louder ones settle almost immediately.
        for (var i = 0; i < 250; i++) {
          a.analyse(tone(400, amp: amp));
        }
        expect(loudestOf(a.wave),
            closeTo(AudioAnalyser.waveHeadroom, 0.08),
            reason: 'amplitude $amp should still reach the top');
      }
    });

    test('a silence flattens the waveform rather than magnifying it', () {
      final a = AudioAnalyser();
      for (var i = 0; i < 40; i++) {
        a.analyse(tone(400));
      }
      for (var i = 0; i < 200; i++) {
        a.analyse(Int16List(512));
      }
      expect(a.wave.every((v) => v == 0), isTrue);
    });

    test('the loud half of a frame outreaches the quiet half', () {
      // Scaling must not flatten the shape within a frame.
      final frame = tone(400);
      for (var i = frame.length ~/ 2; i < frame.length; i++) {
        frame[i] = (frame[i] * 0.2).round();
      }
      final a = AudioAnalyser()..analyse(frame);
      double loudestIn(List<double> w, int from, int to) =>
          w.sublist(from, to).map((v) => v.abs()).reduce(math.max);
      final n = a.wave.length;
      expect(loudestIn(a.wave, 0, n ~/ 2),
          greaterThan(loudestIn(a.wave, n ~/ 2, n) * 2));
    });

    test('reset drops everything at once', () {
      final a = AudioAnalyser()..analyse(tone(1000));
      a.reset();
      expect(a.silent, isTrue);
      expect(a.wave.every((v) => v == 0), isTrue);
    });
  });

  group('capture lifecycle', () {
    late StreamController<List<int>> pcm;
    late int opened;
    late int stopped;
    late AudioLevelsService service;

    setUp(() {
      opened = 0;
      stopped = 0;
      pcm = StreamController<List<int>>.broadcast();
      service = AudioLevelsService(open: () async {
        opened++;
        return PcmStream(
          bytes: pcm.stream,
          stop: () async => stopped++,
        );
      });
    });

    tearDown(() async {
      await pcm.close();
    });

    test('nothing runs until something asks', () async {
      await Future<void>.delayed(Duration.zero);
      expect(opened, 0);
      expect(service.running, isFalse);
    });

    test('the first viewer starts it and the last one stops it', () async {
      service.attach();
      await Future<void>.delayed(Duration.zero);
      expect(opened, 1);
      expect(service.running, isTrue);

      // A second viewer must not open a second capture.
      service.attach();
      await Future<void>.delayed(Duration.zero);
      expect(opened, 1);

      service.detach();
      await Future<void>.delayed(Duration.zero);
      expect(service.running, isTrue, reason: 'one viewer is still watching');

      service.detach();
      await Future<void>.delayed(Duration.zero);
      expect(service.running, isFalse);
      expect(stopped, 1);
    });

    test('detaching before the capture opens still closes it', () async {
      service.attach();
      service.detach();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(service.running, isFalse);
      expect(stopped, 1);
    });

    test('levels follow the bytes, and go flat again when it stops', () async {
      service.attach();
      await Future<void>.delayed(Duration.zero);
      pcm.add(bytesOf(tone(1000)));
      await Future<void>.delayed(Duration.zero);
      expect(service.levels.any((l) => l > 0.5), isTrue);

      service.detach();
      await Future<void>.delayed(Duration.zero);
      expect(service.levels.every((l) => l == 0), isTrue);
    });

    test('a partial frame is held until the rest of it arrives', () async {
      service.attach();
      await Future<void>.delayed(Duration.zero);
      final all = bytesOf(tone(1000));
      pcm.add(all.sublist(0, 600));
      await Future<void>.delayed(Duration.zero);
      expect(service.levels.every((l) => l == 0), isTrue,
          reason: 'half a frame is not a frame');
      pcm.add(all.sublist(600));
      await Future<void>.delayed(Duration.zero);
      expect(service.levels.any((l) => l > 0.5), isTrue);
    });

    test('a missing capture command is reported once, not retried', () async {
      var attempts = 0;
      final missing = AudioLevelsService(open: () async {
        attempts++;
        throw ProcessException('pw-record', const [], 'No such file', 2);
      });
      missing.attach();
      await Future<void>.delayed(Duration.zero);
      expect(missing.supported, isFalse);
      expect(missing.error, contains('No such file'));

      missing.detach();
      missing.attach();
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1, reason: 'a machine without PipeWire will not grow one');
    });
  });
}
