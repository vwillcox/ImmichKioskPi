import 'dart:async';

import 'package:flutter/material.dart';

import '../widget_registry.dart';

/// Time and date.
class ClockWidget extends StatefulWidget {
  const ClockWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  State<ClockWidget> createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<ClockWidget> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// Ticks on the second boundary rather than every second from whenever the
  /// widget happened to be built, so the display changes when the clock does.
  void _schedule() {
    final now = DateTime.now();
    final showSeconds = widget.w.option('seconds', false);
    final next = showSeconds
        ? DateTime(now.year, now.month, now.day, now.hour, now.minute,
            now.second + 1)
        : DateTime(now.year, now.month, now.day, now.hour, now.minute + 1);
    _timer = Timer(next.difference(now), () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.w.theme;
    final twentyFour = widget.w.option('twentyFourHour', true);
    final seconds = widget.w.option('seconds', false);
    final showDate = widget.w.option('showDate', true);

    var hour = _now.hour;
    String suffix = '';
    if (!twentyFour) {
      suffix = hour < 12 ? ' am' : ' pm';
      hour = hour % 12;
      if (hour == 0) hour = 12;
    }
    final hh = twentyFour ? _two(hour) : '$hour';
    final time = seconds
        ? '$hh:${_two(_now.minute)}:${_two(_now.second)}$suffix'
        : '$hh:${_two(_now.minute)}$suffix';

    return LayoutBuilder(
      builder: (context, c) {
        // Sized from the tile rather than fixed, so the same widget reads well
        // whether it is two cells wide or the whole screen.
        final size = (c.maxWidth / (time.length * 0.62))
            .clamp(24.0, c.maxHeight * (showDate ? 0.62 : 0.9));
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                time,
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: size,
                  height: 1.0,
                  fontWeight: FontWeight.w300,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (showDate) ...[
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _dateLine(_now),
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: (size * 0.2).clamp(13.0, 40.0),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static const _days = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday'
  ];
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
    'September', 'October', 'November', 'December'
  ];

  static String _dateLine(DateTime d) =>
      '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

final clockWidgetType = DashboardWidgetType(
  type: 'clock',
  name: 'Clock',
  description: 'The time, with the date underneath.',
  glyph: '🕰',
  defaultWidth: 4,
  defaultHeight: 2,
  minWidth: 2,
  options: const [
    WidgetOption(
      key: 'twentyFourHour',
      label: '24-hour clock',
      kind: OptionKind.boolean,
      defaultValue: true,
    ),
    WidgetOption(
      key: 'seconds',
      label: 'Show seconds',
      kind: OptionKind.boolean,
      defaultValue: false,
      help: 'Updates every second rather than every minute.',
    ),
    WidgetOption(
      key: 'showDate',
      label: 'Show the date',
      kind: OptionKind.boolean,
      defaultValue: true,
    ),
  ],
  build: (context, w) => ClockWidget(w: w),
);
