import 'package:flutter/material.dart';

/// Text that scrolls right to left when it is too wide to fit, and sits still
/// when it isn't.
///
/// The stillness matters as much as the movement: this is a panel that is on
/// all day, and something sliding about in the corner of a room when it has
/// nothing to say is a nuisance. So the animation only exists while the text
/// actually overflows — no controller is even created otherwise — and it
/// pauses at both ends so the beginning and the end can each be read without
/// waiting for a loop.
class ScrollingText extends StatefulWidget {
  const ScrollingText(
    this.text, {
    super.key,
    this.style,
    this.speed = 38,
    this.pause = const Duration(seconds: 2),
    this.align = TextAlign.start,
  });

  final String text;
  final TextStyle? style;

  /// Logical pixels per second. Slow enough to read at a glance from across
  /// a room.
  final double speed;

  /// Held at each end before moving on.
  final Duration pause;

  /// Used when the text does fit, where there is nothing to scroll.
  final TextAlign align;

  @override
  State<ScrollingText> createState() => _ScrollingTextState();
}

class _ScrollingTextState extends State<ScrollingText>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _offset;
  double _overflow = 0;

  @override
  void didUpdateWidget(ScrollingText old) {
    super.didUpdateWidget(old);
    // A new track is a new measurement — and one that fits should stop the
    // previous one's animation rather than inherit it.
    if (old.text != widget.text || old.style != widget.style) {
      _teardown();
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _teardown() {
    _controller?.dispose();
    _controller = null;
    _offset = null;
    _overflow = 0;
  }

  void _ensureAnimation(double overflow) {
    if (_controller != null && (overflow - _overflow).abs() < 0.5) return;
    _teardown();
    _overflow = overflow;

    final travel = Duration(
        milliseconds: (overflow / widget.speed * 1000).round().clamp(600, 30000));
    final total = widget.pause + travel + widget.pause;
    final pauseWeight = widget.pause.inMilliseconds / total.inMilliseconds;
    final travelWeight = travel.inMilliseconds / total.inMilliseconds;

    final controller = AnimationController(vsync: this, duration: total);
    _offset = TweenSequence<double>([
      TweenSequenceItem(
          tween: ConstantTween<double>(0), weight: pauseWeight),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: -overflow),
        weight: travelWeight,
      ),
      TweenSequenceItem(
          tween: ConstantTween<double>(-overflow), weight: pauseWeight),
    ]).animate(controller);

    _controller = controller;
    // Started after this frame: creating and running a controller during
    // layout is what schedules a build during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.repeat();
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);

    return LayoutBuilder(
      builder: (context, c) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();

        final overflow = painter.width - c.maxWidth;
        if (overflow <= 1 || !c.maxWidth.isFinite) {
          if (_controller != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(_teardown);
            });
          }
          return Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            textAlign: widget.align,
            style: widget.style,
          );
        }

        _ensureAnimation(overflow);
        final offset = _offset;
        if (offset == null) {
          return Text(widget.text,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style);
        }

        return ClipRect(
          child: AnimatedBuilder(
            animation: offset,
            builder: (context, child) => Transform.translate(
              offset: Offset(offset.value, 0),
              child: child,
            ),
            // Built once and slid around, rather than laid out every frame.
            child: SizedBox(
              width: painter.width,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                style: widget.style,
              ),
            ),
          ),
        );
      },
    );
  }
}
