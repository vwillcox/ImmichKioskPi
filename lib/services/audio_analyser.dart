import 'dart:math' as math;
import 'dart:typed_data';

/// Turns raw PCM into the numbers a visualiser draws.
///
/// Pure arithmetic — no audio device, no subprocess, no isolate. It takes a
/// frame of signed 16-bit mono samples and leaves behind band levels and a
/// waveform, so [AudioLevelsService] can own the plumbing and this can be
/// tested with a synthesised sine wave.
///
/// Deliberately small: a 512-point frame at 16 kHz is 32 ms of audio and about
/// 2,300 butterflies, thirty times a second. That is nothing next to painting
/// the bars, which is the real reason the whole thing is switched off when
/// nobody is looking at it.
class AudioAnalyser {
  AudioAnalyser({
    this.bands = 28,
    this.sampleRate = 16000,
    this.fftSize = 512,
    this.wavePoints = 96,
  })  : assert(fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
            'fftSize must be a power of two'),
        _levels = Float64List(bands),
        _wave = Float64List(wavePoints),
        _re = Float64List(fftSize),
        _im = Float64List(fftSize),
        _window = Float64List(fftSize),
        _edges = Int32List(bands + 1),
        _tilt = Float64List(bands) {
    // Hann. Without it every frame boundary is a step change, and the whole
    // spectrum smears into a wall of bars that never moves.
    for (var i = 0; i < fftSize; i++) {
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (fftSize - 1));
    }
    _fillEdges();
  }

  /// How many bars the spectrum is divided into.
  final int bands;
  final int sampleRate;

  /// Frame length; must be a power of two. 512 at 16 kHz gives ~31 Hz bins.
  final int fftSize;

  /// How many points the waveform is reduced to.
  final int wavePoints;

  /// How much of the previous level survives a quiet frame.
  ///
  /// Rises are instant and falls are gradual, which is what makes bars read as
  /// music rather than noise: a drum hit should snap up and slide down, not
  /// flicker. 0.86 at ~31 frames a second is roughly a third of a second from
  /// full height to nothing.
  static const double release = 0.86;

  /// How many decibels separate a bar at the floor from one at the top.
  ///
  /// Measured off this panel rather than guessed: five seconds of ordinary
  /// music through its speaker put the median band around 17 dB below the
  /// loudest peaks and the quietest tenth around 28 dB below. Thirty-four
  /// decibels puts the median at about half height, which is what makes the
  /// bars look like music rather than a row of full ones or a flat line.
  static const double rangeDb = 34;

  /// Where the top of that range starts out, in tilted dBFS.
  static const double defaultReferenceDb = -34;

  /// How far the reference is allowed to move.
  ///
  /// The window follows the music so the bars still read at a low volume, but
  /// only this far: without a floor, a long quiet passage would wind the gain
  /// up until the room noise on the next track filled the screen.
  static const double minReferenceDb = -46;
  static const double maxReferenceDb = -20;

  /// How quickly the window rises to meet a loud passage, per frame.
  static const double referenceAttack = 0.25;

  /// How quickly it settles back, in decibels per frame — about 0.6 a second.
  static const double referenceRelease = 0.02;

  /// How much each octave of pitch is lifted, in decibels.
  ///
  /// Music loses roughly this much an octave as it climbs, so without the lift
  /// the treble bars would barely leave the floor while the bass ones pegged.
  static const double tiltPerOctave = 3.0;

  final Float64List _levels;
  final Float64List _wave;
  final Float64List _re;
  final Float64List _im;
  final Float64List _window;
  final Int32List _edges;
  final Float64List _tilt;

  double _reference = defaultReferenceDb;

  /// The level the top of the bars currently corresponds to, in tilted dBFS.
  double get referenceDb => _reference;

  /// Band levels, 0–1, quietest frequency first.
  List<double> get levels => _levels;

  /// The frame's shape, −1–1.
  List<double> get wave => _wave;

  /// Whether every band has decayed to nothing.
  ///
  /// The service uses this to stop repainting during a silence rather than
  /// pushing thirty identical flat frames a second at the screen.
  bool get silent {
    for (final l in _levels) {
      if (l > 0.005) return false;
    }
    return true;
  }

  /// How many samples [analyse] expects.
  int get frameSamples => fftSize;

  /// Where each band starts and ends, in FFT bins.
  ///
  /// Logarithmic, because pitch is: an even split would give twenty of the
  /// bars to frequencies above 4 kHz, where music has almost nothing, and
  /// cram every bass note into the first one.
  void _fillEdges() {
    const minHz = 45.0;
    final maxHz = sampleRate * 0.45;
    final binHz = sampleRate / fftSize;
    // The bands are log-spaced, so each one is the same fraction of an octave
    // wide and the lift is simply linear across them.
    final octaves = math.log(maxHz / minHz) / math.ln2;
    for (var b = 0; b < bands; b++) {
      _tilt[b] = tiltPerOctave * octaves * (b / bands);
    }
    var last = 0;
    for (var i = 0; i <= bands; i++) {
      final hz = minHz * math.pow(maxHz / minHz, i / bands);
      var bin = (hz / binHz).round();
      // Strictly increasing, so no band ends up empty and stuck at zero.
      if (bin <= last) bin = last + 1;
      if (bin > fftSize ~/ 2) bin = fftSize ~/ 2;
      _edges[i] = bin;
      last = bin;
    }
  }

  /// Read one frame of mono samples and update [levels] and [wave].
  ///
  /// [frame] must hold at least [frameSamples]; anything beyond that is
  /// ignored, so a caller can hand over its buffer without trimming it.
  void analyse(Int16List frame) {
    for (var i = 0; i < fftSize; i++) {
      _re[i] = (i < frame.length ? frame[i] : 0) * _window[i];
      _im[i] = 0;
    }
    _fft(_re, _im);

    // A full-scale sine lands at half its amplitude in each of two bins, and
    // the Hann window halves it again — hence the /4. Referencing the result
    // to full scale is what makes the dB range below mean the same thing on
    // any frame size.
    final full = 32768.0 * fftSize / 4;
    final band = Float64List(bands);
    var loudest = double.negativeInfinity;
    for (var b = 0; b < bands; b++) {
      var peak = 0.0;
      for (var k = _edges[b]; k < _edges[b + 1]; k++) {
        final mag = math.sqrt(_re[k] * _re[k] + _im[k] * _im[k]);
        if (mag > peak) peak = mag;
      }
      band[b] = 20 * _log10(peak / full + 1e-12) + _tilt[b];
      if (band[b] > loudest) loudest = band[b];
    }

    _track(loudest);
    final floor = _reference - rangeDb;
    for (var b = 0; b < bands; b++) {
      final value = ((band[b] - floor) / rangeDb).clamp(0.0, 1.0);
      final decayed = _levels[b] * release;
      _levels[b] = value > decayed ? value : decayed;
    }

    _fillWave(frame);
  }

  /// Move the top of the range towards the music.
  ///
  /// Turning the speaker down should make the bars smaller, but not make them
  /// disappear, so the window follows the level — quickly upwards so a loud
  /// entry is not clipped, slowly downwards so a quiet bar does not pump.
  /// A silent frame moves it nowhere at all: letting it drift down through a
  /// gap between tracks is exactly how a visualiser ends up screaming at the
  /// first note of the next one.
  void _track(double loudest) {
    if (loudest <= _reference - rangeDb) return;
    if (loudest > _reference) {
      _reference += (loudest - _reference) * referenceAttack;
    } else {
      _reference -= referenceRelease;
    }
    _reference = _reference.clamp(minReferenceDb, maxReferenceDb);
  }

  /// Reduce the frame to [wavePoints], keeping the extreme of each chunk.
  ///
  /// The peak rather than the mean, for the same reason the throughput chart
  /// keeps peaks: averaging a waveform mostly averages it away, and a quiet
  /// line through the middle of a loud passage is a lie.
  void _fillWave(Int16List frame) {
    final n = math.min(frame.length, fftSize);
    for (var p = 0; p < wavePoints; p++) {
      final from = (p * n) ~/ wavePoints;
      final to = math.max(from + 1, ((p + 1) * n) ~/ wavePoints);
      var extreme = 0;
      for (var i = from; i < to && i < n; i++) {
        if (frame[i].abs() > extreme.abs()) extreme = frame[i];
      }
      _wave[p] = (extreme / 32768.0).clamp(-1.0, 1.0);
    }
  }

  /// Let everything fall to nothing, for when the audio stops rather than
  /// goes quiet — the bars should settle, not freeze mid-height.
  void decay() {
    for (var b = 0; b < bands; b++) {
      _levels[b] *= release;
      if (_levels[b] < 0.005) _levels[b] = 0;
    }
    for (var p = 0; p < wavePoints; p++) {
      _wave[p] *= release;
    }
  }

  /// Drop everything to zero at once, for when capture stops altogether.
  void reset() {
    _levels.fillRange(0, _levels.length, 0);
    _wave.fillRange(0, _wave.length, 0);
    _reference = defaultReferenceDb;
  }

  /// In-place iterative radix-2 Cooley–Tukey.
  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final angle = -2 * math.pi / len;
      final wRe = math.cos(angle);
      final wIm = math.sin(angle);
      final half = len >> 1;
      for (var i = 0; i < n; i += len) {
        var curRe = 1.0;
        var curIm = 0.0;
        for (var k = 0; k < half; k++) {
          final a = i + k;
          final b = a + half;
          final vRe = re[b] * curRe - im[b] * curIm;
          final vIm = re[b] * curIm + im[b] * curRe;
          re[b] = re[a] - vRe;
          im[b] = im[a] - vIm;
          re[a] += vRe;
          im[a] += vIm;
          final nextRe = curRe * wRe - curIm * wIm;
          curIm = curRe * wIm + curIm * wRe;
          curRe = nextRe;
        }
      }
    }
  }

  static double _log10(double x) => math.log(x) / math.ln10;
}
