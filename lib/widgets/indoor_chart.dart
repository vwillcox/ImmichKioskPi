import 'package:flutter/material.dart';

import '../services/indoor_sensor_service.dart';

/// Line chart of recent indoor readings. Drawn with a CustomPainter so the
/// project doesn't take on a charting dependency for one graph.
class IndoorChart extends StatelessWidget {
  final List<IndoorReading> readings;
  final bool metric;

  /// Show humidity as a second line alongside temperature.
  final bool showHumidity;

  const IndoorChart({
    super.key,
    required this.readings,
    this.metric = true,
    this.showHumidity = true,
  });

  @override
  Widget build(BuildContext context) {
    if (readings.length < 2) {
      return const Center(
        child: Text(
          'Collecting readings…',
          style: TextStyle(color: Colors.white54, fontSize: 18),
        ),
      );
    }
    return CustomPaint(
      painter: _ChartPainter(
        readings: readings,
        metric: metric,
        showHumidity: showHumidity,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<IndoorReading> readings;
  final bool metric;
  final bool showHumidity;

  static const Color tempColour = Color(0xFFFF8A65);
  static const Color humColour = Color(0xFF4FC3F7);

  _ChartPainter({
    required this.readings,
    required this.metric,
    required this.showHumidity,
  });

  double _temp(IndoorReading r) =>
      metric ? r.temperatureC : r.temperatureC * 9 / 5 + 32;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 52.0;
    const rightPad = 46.0;
    const topPad = 14.0;
    const bottomPad = 26.0;
    final plot = Rect.fromLTRB(
        leftPad, topPad, size.width - rightPad, size.height - bottomPad);
    if (plot.width <= 0 || plot.height <= 0) return;

    final temps = readings.map(_temp).toList();
    var minT = temps.reduce((a, b) => a < b ? a : b);
    var maxT = temps.reduce((a, b) => a > b ? a : b);
    // Always show a sensible band so a flat line doesn't fill the chart.
    if (maxT - minT < 2) {
      final mid = (maxT + minT) / 2;
      minT = mid - 1;
      maxT = mid + 1;
    } else {
      final pad = (maxT - minT) * 0.15;
      minT -= pad;
      maxT += pad;
    }

    final t0 = readings.first.time.millisecondsSinceEpoch.toDouble();
    final t1 = readings.last.time.millisecondsSinceEpoch.toDouble();
    final span = (t1 - t0) == 0 ? 1.0 : (t1 - t0);

    double xFor(IndoorReading r) =>
        plot.left + (r.time.millisecondsSinceEpoch - t0) / span * plot.width;
    double yForTemp(double v) =>
        plot.bottom - (v - minT) / (maxT - minT) * plot.height;
    double yForHum(double v) => plot.bottom - (v / 100) * plot.height;

    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    final labelStyle = const TextStyle(color: Colors.white54, fontSize: 13);

    // Horizontal gridlines + temperature axis labels.
    for (var i = 0; i <= 3; i++) {
      final v = minT + (maxT - minT) * i / 3;
      final y = yForTemp(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, '${v.round()}°', Offset(4, y - 9), labelStyle);
      if (showHumidity) {
        final hv = (i / 3 * 100).round();
        _text(canvas, '$hv%', Offset(plot.right + 6, y - 9),
            labelStyle.copyWith(color: humColour.withValues(alpha: 0.7)));
      }
    }

    // Clip to the plot so neither the line nor its fill can spill out over the
    // rest of the panel.
    canvas.save();
    canvas.clipRect(plot);
    if (showHumidity) {
      _drawLine(canvas, readings, xFor, (r) => yForHum(r.humidity), humColour,
          2.0, 0.10, plot.bottom);
    }
    _drawLine(canvas, readings, xFor, (r) => yForTemp(_temp(r)), tempColour,
        3.0, 0.16, plot.bottom);
    canvas.restore();

    // Time labels at each end.
    _text(canvas, _clock(readings.first.time),
        Offset(plot.left, plot.bottom + 6), labelStyle);
    final endLabel = _clock(readings.last.time);
    _text(canvas, endLabel,
        Offset(plot.right - endLabel.length * 8.0, plot.bottom + 6), labelStyle);
  }

  void _drawLine(
    Canvas canvas,
    List<IndoorReading> data,
    double Function(IndoorReading) xFor,
    double Function(IndoorReading) yFor,
    Color colour,
    double width,
    double fillAlpha,
    double baseline,
  ) {
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = xFor(data[i]);
      final y = yFor(data[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    // Soft fill under the line, closed along the bottom of the plot.
    final fill = Path.from(path)
      ..lineTo(xFor(data.last), baseline)
      ..lineTo(xFor(data.first), baseline)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..color = colour.withValues(alpha: fillAlpha),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _text(Canvas canvas, String s, Offset at, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.readings.length != readings.length ||
      old.metric != metric ||
      old.showHumidity != showHumidity ||
      (readings.isNotEmpty &&
          old.readings.isNotEmpty &&
          old.readings.last.time != readings.last.time);
}
