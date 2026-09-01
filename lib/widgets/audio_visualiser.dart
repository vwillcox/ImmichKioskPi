import 'dart:math' as math;
import 'dart:ui' as ui;

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
/// The colours the spectrum runs through, bass first.
///
/// Pitch is the thing being mapped, so the sweep runs cool to warm across the
/// bars rather than colouring them all alike: the bass end stays close to the
/// player's own blue and the treble end lifts away from it, which makes the
/// shape of the music readable at a glance from across the room.
const List<Color> kVisualiserPalette = [
  Color(0xFF7C4DFF),
  Color(0xFF448AFF),
  Color(0xFF18E0E8),
  Color(0xFF4CE07A),
  Color(0xFFFFC24B),
  Color(0xFFFF5E8A),
];

class AudioVisualiser extends StatefulWidget {
  const AudioVisualiser({
    super.key,
    required this.style,
    this.palette = kVisualiserPalette,
    this.height = 96,
    this.active = true,
    this.onTap,
  });

  final VisualiserStyle style;

  /// Colour stops, spread evenly across the bars.
  final List<Color> palette;

  final double height;

  /// Called when the picture is touched, for cycling the style.
  ///
  /// Providing it also changes what [VisualiserStyle.off] looks like. Without
  /// a handler, off collapses to nothing — there is no reason to hold space
  /// for a picture nobody can bring back. With one, off leaves a slim dormant
  /// strip instead, because a control that disappears when you switch it off
  /// is a control you cannot switch on again.
  final VoidCallback? onTap;

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
    final service = context.watch<AudioLevelsService>();
    // Nothing to capture with — a machine that isn't the panel. Take the space
    // back rather than reserving it for a picture that will never come.
    if (!service.supported) return const SizedBox.shrink();

    if (widget.style == VisualiserStyle.off) {
      if (widget.onTap == null) return const SizedBox.shrink();
      return _tappable(
        label: 'Visualiser off. Tap to turn it on.',
        // Enough to hit with a thumb without pretending there is a picture.
        child: SizedBox(
          height: math.max(36, widget.height * 0.36),
          width: double.infinity,
          child: Center(
            child: Icon(
              Icons.graphic_eq,
              size: 22,
              color: widget.palette.first.withValues(alpha: 0.45),
            ),
          ),
        ),
      );
    }

    return _tappable(
      label: widget.style == VisualiserStyle.wave
          ? 'Visualiser: waveform. Tap to change.'
          : 'Visualiser: bars. Tap to change.',
      child: RepaintBoundary(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: widget.style == VisualiserStyle.wave
                ? _WavePainter(wave: service.wave, palette: widget.palette)
                : _BarsPainter(levels: service.levels, palette: widget.palette),
          ),
        ),
      ),
    );
  }

  /// Wrap the picture so a touch anywhere on it counts.
  ///
  /// Opaque hit testing: most of this band is empty space above short bars,
  /// and a tap target you have to land on a bar to hit would be useless.
  Widget _tappable({required String label, required Widget child}) {
    if (widget.onTap == null) return child;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: child,
      ),
    );
  }
}

/// Pick a colour from the stops, [t] running 0–1 across them.
Color _sample(List<Color> palette, double t) {
  if (palette.isEmpty) return Colors.white;
  if (palette.length == 1) return palette.first;
  final scaled = t.clamp(0.0, 1.0) * (palette.length - 1);
  final i = scaled.floor().clamp(0, palette.length - 2);
  return Color.lerp(palette[i], palette[i + 1], scaled - i)!;
}

/// A spectrum: one bar per band, bass on the left.
class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.levels, required this.palette});

  final List<double> levels;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0) return;
    // A quarter of each slot goes to the gap. Narrow bars on a wall panel read
    // as noise from across the room; these stay chunky.
    final slot = size.width / levels.length;
    final width = slot * 0.72;
    final radius = Radius.circular(math.min(width / 2, 6));
    // A floor, so a silence is a row of dots rather than an empty rectangle
    // that looks like the widget has failed.
    final floor = math.min(4.0, size.height);
    final span = levels.length == 1 ? 1 : levels.length - 1;

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i].clamp(0.0, 1.0);
      final height = math.max(floor, level * size.height);
      final left = i * slot + (slot - width) / 2;
      final top = size.height - height;
      final rect = Rect.fromLTWH(left, top, width, height);

      final base = _sample(palette, i / span);
      // Hotter at the tip and dimmer at the foot, so a tall bar reads as a
      // peak rather than a longer block of the same flat colour — and so the
      // quiet ones recede instead of drawing a hard bright line along the
      // bottom of the panel.
      final tip = Color.lerp(base, Colors.white, 0.10 + 0.30 * level)!;
      final foot = base.withValues(alpha: 0.30 + 0.35 * level);

      canvas.drawRRect(
        RRect.fromRectAndCorners(rect, topLeft: radius, topRight: radius),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(left, top),
            Offset(left, size.height),
            [tip, foot],
          ),
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
  _WavePainter({required this.wave, required this.palette});

  final List<double> wave;
  final List<Color> palette;

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

    // The same sweep the bars use, laid across the width, so switching style
    // changes the shape rather than the whole look of the player. Built three
    // times at different strengths: a Paint's own colour is ignored once it
    // has a shader, so the transparency has to live in the stops.
    ui.Shader sweep(double alpha) => ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, 0),
          [for (final c in palette) c.withValues(alpha: alpha)],
          [for (var i = 0; i < palette.length; i++) i / (palette.length - 1)],
        );

    canvas.drawPath(path, Paint()..shader = sweep(0.5));
    canvas.drawPath(
      path,
      Paint()
        ..shader = sweep(1.0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    // The centre line keeps the band anchored when everything falls silent.
    canvas.drawLine(
      Offset(0, middle),
      Offset(size.width, middle),
      Paint()
        ..shader = sweep(0.30)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}
