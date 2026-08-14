import 'package:flutter/material.dart';

/// Text that scrolls continuously right to left when it is too wide to fit,
/// and sits still when it isn't.
///
/// The stillness matters as much as the movement: this is a panel that is on
/// all day, and something sliding about in the corner of a room when it has
/// nothing to say is a nuisance. So the animation only exists while the text
/// actually overflows — no controller is even created otherwise.
///
/// While it does overflow, it goes round and round: the text runs off to the
/// left and comes back in from the right, with a second copy drawn a lap
/// behind so the wrap has no seam. It pauses briefly at the start of each lap
/// so the beginning can be read without waiting for the loop.
class ScrollingText extends StatefulWidget {
  const ScrollingText(
    this.text, {
    super.key,
    this.style,
    this.speed = 38,
    this.pause = const Duration(seconds: 2),
    this.gap = 56,
    this.align = TextAlign.start,
  });

  final String text;
  final TextStyle? style;

  /// Logical pixels per second. Slow enough to read at a glance from across
  /// a room.
  final double speed;

  /// Held at the start of each lap before setting off again.
  final Duration pause;

  /// Blank space between the end of the text and where it comes round again,
  /// so the two do not read as one run-on sentence.
  final double gap;

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

  /// One lap: the text's own width plus the gap before it comes round again.
  double _lap(double textWidth) => textWidth + widget.gap;

  void _ensureAnimation(double textWidth) {
    if (_controller != null && (textWidth - _overflow).abs() < 0.5) return;
    _teardown();
    _overflow = textWidth;

    // The text travels a whole lap rather than only the hidden part, so it
    // carries on off the left and comes back round from the right instead of
    // stopping at the end and jumping.
    final lap = _lap(textWidth);
    final travel = Duration(
        milliseconds: (lap / widget.speed * 1000).round().clamp(600, 60000));
    final total = widget.pause + travel;
    final pauseWeight = widget.pause.inMilliseconds / total.inMilliseconds;
    final travelWeight = travel.inMilliseconds / total.inMilliseconds;

    final controller = AnimationController(vsync: this, duration: total);
    _offset = TweenSequence<double>([
      // Held at the start of each lap, so the beginning of a long title can
      // be read without waiting for it to come round.
      TweenSequenceItem(
          tween: ConstantTween<double>(0), weight: pauseWeight),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: -lap),
        weight: travelWeight,
      ),
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

        final fits = painter.width - c.maxWidth <= 1;
        if (fits || !c.maxWidth.isFinite) {
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

        _ensureAnimation(painter.width);
        final offset = _offset;
        if (offset == null) {
          return Text(widget.text,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style);
        }

        // A Positioned inside a Stack, rather than a translated SizedBox.
        //
        // The obvious version — an oversized box slid left — does not work:
        // the box is still bound by the width coming down from the tile, so
        // the text is laid out already clipped, and sliding it along reveals
        // nothing but the blank it was truncated to. Positioned gives the
        // child a tight width of its own choosing, which is the only way it
        // gets to lay out at its full length.
        final lap = _lap(painter.width);
        return SizedBox(
          height: painter.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: offset,
              // The text is built once and passed through, so each frame
              // moves it rather than laying it out again.
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                style: widget.style,
              ),
              builder: (context, child) => Stack(
                children: [
                  Positioned(
                    left: offset.value,
                    top: 0,
                    width: painter.width,
                    child: child!,
                  ),
                  // The same text a lap behind. As the first copy leaves to
                  // the left this one arrives from the right, so the wrap is
                  // continuous rather than a jump back to the start.
                  Positioned(
                    left: offset.value + lap,
                    top: 0,
                    width: painter.width,
                    child: child,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
