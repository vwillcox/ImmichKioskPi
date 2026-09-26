import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/timer_service.dart';
import '../../services/timer_sounds.dart';
import '../dashboard_theme.dart';
import '../widget_registry.dart';
import 'fit_canvas.dart';
import 'tile_bits.dart';

/// Kitchen timers: tap a preset to start one, tap its ring to pause it, hold
/// it to cancel. When one is done the panel says so, and a tap on the ring
/// dismisses it.
class TimersWidget extends StatelessWidget {
  const TimersWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final service = context.watch<TimerService>();
    final presets = TimerPreset.parse(
      w.option('presets', 'Eggs=7, Pasta=11, 5, 10, 20'),
    );
    // Read when a timer starts, so each one keeps the sound its tile had.
    final sound = w.option('sound', 'chime');
    final speaks = w.option('speak', true);
    final timers = service.timers;
    final now = service.now;
    final latest = timers.where((x) => !x.finished).lastOrNull;

    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        // The presets take a strip along the bottom sized from the tile, so
        // they stay easy to hit on a small tile and do not balloon on a big one.
        final chipH = (h * (timers.isEmpty ? 0.3 : 0.2)).clamp(30.0, 64.0);
        final chips = <Widget>[
          if (latest != null)
            _Chip(
              label: '+1 min',
              height: chipH,
              theme: t,
              onTap: () =>
                  service.addTime(latest.id, const Duration(minutes: 1)),
            ),
          for (final p in presets)
            _Chip(
              label: p.chip,
              height: chipH,
              theme: t,
              filled: true,
              onTap: () => service.start(
                p.length,
                label: p.label,
                sound: sound,
                speaks: speaks,
              ),
            ),
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: timers.isEmpty
                  ? FitCanvas(
                      designHeight: 60,
                      maxScale: 3,
                      builder: (_, _) => Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.timer_outlined,
                                color: t.textSecondary,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Tap a time to start',
                                style: TextStyle(
                                  color: t.textSecondary,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : _Rings(
                      timers: timers,
                      now: now,
                      service: service,
                      theme: t,
                    ),
            ),
            SizedBox(height: chipH * 0.25),
            SizedBox(
              height: chipH,
              // All of them, always: they shrink together to fit the width
              // rather than some scrolling out of sight off the edge.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    for (var i = 0; i < chips.length; i++) ...[
                      if (i > 0) SizedBox(width: chipH * 0.18),
                      chips[i],
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Rings extends StatelessWidget {
  const _Rings({
    required this.timers,
    required this.now,
    required this.service,
    required this.theme,
  });

  final List<KioskTimer> timers;
  final DateTime now;
  final TimerService service;
  final DashboardTheme theme;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final grid = bestGrid(timers.length, c.biggest, cellAspect: 1);
        // Rounded down, so rounding never pushes the last ring onto a row of
        // its own.
        final cellW = (c.maxWidth / grid.columns).floorToDouble();
        final cellH = (c.maxHeight / grid.rows).floorToDouble();
        final side = math.min(cellW, cellH) * 0.94;
        return Wrap(
          alignment: WrapAlignment.center,
          runAlignment: WrapAlignment.center,
          children: [
            for (final timer in timers)
              SizedBox(
                width: cellW,
                height: cellH,
                child: Center(
                  child: SizedBox.square(
                    dimension: side,
                    child: _Ring(
                      timer: timer,
                      now: now,
                      theme: theme,
                      onTap: () => timer.finished
                          ? service.remove(timer.id)
                          : service.togglePause(timer.id),
                      onLongPress: () => service.remove(timer.id),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.timer,
    required this.now,
    required this.theme,
    required this.onTap,
    required this.onLongPress,
  });

  final KioskTimer timer;
  final DateTime now;
  final DashboardTheme theme;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static String clock(Duration d) {
    final s = (d.inMilliseconds / 1000).ceil();
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final mm = m.toString().padLeft(2, '0'),
        ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final status = StatusColours.of(theme);
    final done = timer.finished;
    final colour = done
        ? status.good
        : (timer.paused ? theme.textSecondary : theme.accent);
    return Semantics(
      button: true,
      label: done
          ? '${timer.label} timer done. Tap to dismiss.'
          : '${timer.label} timer, ${clock(timer.remaining(now))} left.',
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: CustomPaint(
          painter: _RingPainter(
            fraction: done ? 1 : timer.fraction(now),
            colour: colour,
            track: theme.textSecondary.withValues(alpha: 0.16),
          ),
          // The time fills the inside of the ring at any size: a box the
          // shape of the widest text that fits in a circle, scaled into.
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.66,
              heightFactor: 0.46,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      done ? 'Done' : clock(timer.remaining(now)),
                      style: TextStyle(
                        color: done ? colour : theme.textPrimary,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      timer.paused ? 'Paused' : timer.label,
                      maxLines: 1,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.colour,
    required this.track,
  });

  final double fraction;
  final Color colour;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.07;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (fraction <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction.clamp(0, 1),
      false,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.colour != colour || old.track != track;
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.height,
    required this.theme,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final double height;
  final DashboardTheme theme;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled
          ? theme.textPrimary.withValues(alpha: 0.1)
          : theme.accent.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(height),
      child: InkWell(
        borderRadius: BorderRadius.circular(height),
        onTap: onTap,
        child: Container(
          height: height,
          constraints: BoxConstraints(minWidth: height * 1.3),
          padding: EdgeInsets.symmetric(horizontal: height * 0.38),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: filled ? theme.textPrimary : theme.accent,
              fontSize: height * 0.4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

final timersWidgetType = DashboardWidgetType(
  type: 'timers',
  category: WidgetCategory.timeAndDay,
  name: 'Timers',
  description:
      'Kitchen timers. Tap a time to start one, tap its ring to '
      'pause, hold to cancel. When one is done it plays a sound and says '
      'which timer it was; tap the ring to stop it. They keep running when '
      'you leave the dashboard.',
  glyph: '⏲️',
  defaultWidth: 3,
  defaultHeight: 3,
  minWidth: 2,
  minHeight: 2,
  fitsItself: true,
  options: const [
    WidgetOption(
      key: 'presets',
      label: 'Times to offer',
      defaultValue: 'Eggs=7, Pasta=11, 5, 10, 20',
      help:
          'Minutes, separated by commas. Name one with an equals sign — '
          'Eggs=7 — and it is called that when it is done. 90s for seconds, '
          '1h for an hour.',
    ),
    WidgetOption(
      key: 'sound',
      label: 'Sound when done',
      kind: OptionKind.choice,
      defaultValue: 'chime',
      choices: TimerSounds.defaultChoices,
      choicesFrom: 'timerSounds',
      help:
          'Played before the voice, and again each time it repeats. Upload '
          'an MP3 of your own to add it to the list.',
    ),
    WidgetOption(
      key: 'speak',
      label: 'Say which timer is done',
      kind: OptionKind.boolean,
      defaultValue: true,
      help:
          '"The pasta timer is done", read out by piper after the sound. '
          'Needs piper installed — see INSTALL.md.',
    ),
  ],
  preview: const [
    PreviewLine('04:12', scale: 0.26, accent: true, centre: true),
    PreviewLine('Pasta', scale: 0.1, muted: true, centre: true),
    PreviewLine('Eggs · Pasta · 5 · 10 · 20', scale: 0.1, centre: true),
  ],
  build: (context, w) => TimersWidget(w: w),
);
