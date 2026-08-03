import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/indoor_sensor_service.dart';
import 'package:immich_kiosk_pi/widgets/indoor_chart.dart';

/// A CustomPainter doesn't clip to its box unless it's told to, so a fill path
/// closed below the plot paints straight over whatever sits underneath — which
/// is how the temperature fill once ran the whole height of the expanded
/// weather panel. These check the painter keeps to its own bounds.
///
/// Painting is inspected through a recording canvas rather than by rasterising,
/// so the test stays synchronous and doesn't need a real engine.
class _RecordingCanvas implements Canvas {
  final List<Rect> paths = [];
  final List<Rect> clips = [];

  @override
  void drawPath(Path path, Paint paint) => paths.add(path.getBounds());

  @override
  void clipRect(Rect rect,
          {ClipOp clipOp = ClipOp.intersect, bool doAntiAlias = true}) =>
      clips.add(rect);

  // Everything else the painter calls (lines, text, save/restore) is irrelevant
  // here and can be swallowed.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  const size = Size(400, 150);
  // Mirrors the padding in _ChartPainter.
  final plot = Rect.fromLTRB(52, 14, size.width - 46, size.height - 26);

  List<IndoorReading> readings() {
    final now = DateTime.now();
    return List.generate(
      30,
      (i) => IndoorReading(
        time: now.subtract(Duration(minutes: 30 - i)),
        temperatureC: 20 + i * 0.2,
        humidity: 40 + i * 0.5,
      ),
    );
  }

  _RecordingCanvas paint({bool showHumidity = true}) {
    final canvas = _RecordingCanvas();
    final widget = IndoorChart(readings: readings(), showHumidity: showHumidity);
    // ignore: invalid_use_of_protected_member
    final painter = (widget.build(_FakeContext()) as CustomPaint).painter!;
    painter.paint(canvas, size);
    return canvas;
  }

  test('nothing is drawn below the bottom of the plot', () {
    final canvas = paint();
    expect(canvas.paths, isNotEmpty);
    for (final b in canvas.paths) {
      expect(b.bottom, lessThanOrEqualTo(plot.bottom + 0.5),
          reason: 'a path reached $b, past the plot bottom ${plot.bottom}');
      expect(b.top, greaterThanOrEqualTo(plot.top - 0.5));
    }
  });

  test('painting is clipped to the plot as a backstop', () {
    expect(paint().clips, contains(plot));
  });

  test('the humidity line can be turned off', () {
    expect(paint(showHumidity: false).paths.length,
        lessThan(paint().paths.length));
  });
}

/// The chart's build() only reads its own fields, so a stub context is enough.
class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
