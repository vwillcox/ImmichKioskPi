import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../services/audio_levels_service.dart';

/// The music, drawn.
///
/// Reads [AudioLevelsService] and paints either a spectrum or a waveform. The
/// important part is the bookkeeping rather than the picture: this widget owns
/// one viewer's claim on the capture, taken when it appears and given back when
/// it goes away, so the subprocess and the arithmetic behind it only exist
/// while there is something on screen that would show them.
///
/// [active] is the second half of that. The player stays laid out while a
/// track is paused, but paused audio produces a flat line, so the claim is
/// dropped and the capture stops until playing resumes.
class AudioVisualiser extends StatefulWidget {
  const AudioVisualiser({
    super.key,
    required this.style,
    required this.colour,
    this.height = 56,
    this.active = true,
  });

  final VisualiserStyle style;
  final Color colour;
  final double height;

  /// Whether audio is actually playing. False stops the capture but keeps the
  /// space, so the transport controls do not jump when the music pauses.
  final bool active;

  @override
  State<AudioVisualiser> createState() => _AudioVisualiserState();
}

class _AudioVisualiserState extends State<AudioVisualiser> {
  AudioLevelsService? _service;
  bool _holding = false;

  bool get _wanted => widget.active && widget.style != VisualiserStyle.off;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<AudioLevelsService>();
    if (!identical(service, _service)) {
      _release();
      _service = service;
    }
    _sync();
  }

  @override
  void didUpdateWidget(AudioVisualiser old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_wanted) {
      if (!_holding) {
        _service?.attach();
        _holding = true;
      }
    } else {
      _release();
    }
  }

  void _release() {
    if (!_holding) return;
    _holding = false;
    _service?.detach();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.style == VisualiserStyle.off) return const SizedBox.shrink();
    final service = context.watch<AudioLevelsService>();
    // Nothing to capture with — a machine that isn't the panel. Take the space
    // back rather than reserving it for a picture that will never come.
    if (!service.supported) return const SizedBox.shrink();

    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: widget.style == VisualiserStyle.wave
              ? _WavePainter(wave: service.wave, colour: widget.colour)
              : _BarsPainter(levels: service.levels, colour: widget.colour),
        ),
      ),
    );
  }
}

/// A spectrum: one bar per band, bass on the left.
class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.levels, required this.colour});

  final List<double> levels;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0) return;
    // A quarter of each slot goes to the gap. Narrow bars on a wall panel read
    // as noise from across the room; these stay chunky.
    final slot = size.width / levels.length;
    final width = slot * 0.72;
    final radius = Radius.circular(math.min(width / 2, 4));
    // A floor, so a silence is a row of dots rather than an empty rectangle
    // that looks like the widget has failed.
    final floor = math.min(3.0, size.height);

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i].clamp(0.0, 1.0);
      final height = math.max(floor, level * size.height);
      final left = i * slot + (slot - width) / 2;
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, size.height - height, width, height),
        topLeft: radius,
        topRight: radius,
      );
      // Brighter as it rises: the loud bars carry the eye, the quiet ones sit
      // back instead of drawing a hard bright line along the bottom.
      canvas.drawRRect(
        rect,
        Paint()..color = colour.withValues(alpha: 0.35 + 0.65 * level),
      );
    }
  }

  // The service hands back the same list every frame, so there is nothing
  // here to compare. It only notifies when the numbers actually moved, and it
  // stops notifying entirely during a silence — the throttling that matters
  // happens there, not here.
  @override
  bool shouldRepaint(_BarsPainter old) => true;
}

/// A waveform, mirrored about the centre line.
class _WavePainter extends CustomPainter {
  _WavePainter({required this.wave, required this.colour});

  final List<double> wave;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (wave.length < 2 || size.width <= 0) return;
    final middle = size.height / 2;
    final scale = size.height / 2;
    final step = size.width / (wave.length - 1);

    // Drawn as a closed shape rather than a line: filled, the quiet passages
    // stay visible as a thin ribbon instead of vanishing into the background.
    final path = Path()..moveTo(0, middle);
    for (var i = 0; i < wave.length; i++) {
      path.lineTo(i * step, middle - wave[i].clamp(-1.0, 1.0).abs() * scale);
    }
    for (var i = wave.length - 1; i >= 0; i--) {
      path.lineTo(i * step, middle + wave[i].clamp(-1.0, 1.0).abs() * scale);
    }
    path.close();

    canvas.drawPath(path, Paint()..color = colour.withValues(alpha: 0.55));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colour,
    );
    // The centre line keeps the band anchored when everything falls silent.
    canvas.drawLine(
      Offset(0, middle),
      Offset(size.width, middle),
      Paint()
        ..strokeWidth = 1
        ..color = colour.withValues(alpha: 0.25),
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}
