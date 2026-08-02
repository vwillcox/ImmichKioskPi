import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

/// Slowly drifts persistent overlays around by a few pixels so no panel sits on
/// the same pixels indefinitely. On an always-on display a static element can
/// leave image retention ("burn-in"); nudging it continuously avoids that
/// without the movement being noticeable.
///
/// The horizontal and vertical periods differ, so the panel traces a slow
/// Lissajous path rather than retracing one line.
class BurnInDrift {
  BurnInDrift._();

  /// Maximum offset from the resting position, in logical pixels. Keep this
  /// below the overlays' margin (28) so a panel never clamps against a screen
  /// edge — a clamped panel stops moving, which is what we're avoiding.
  static const double amplitude = 24;

  /// How often the position is recomputed. With the periods below this works
  /// out at roughly two pixels per step — well under the threshold of notice,
  /// and far cheaper than repainting every frame.
  static const Duration tick = Duration(seconds: 20);

  static const Duration _periodX = Duration(minutes: 17);
  static const Duration _periodY = Duration(minutes: 23);

  /// Offset for a given moment. Driven by the wall clock so every overlay
  /// agrees without needing to share state.
  static Offset offsetAt(DateTime t) {
    final ms = t.millisecondsSinceEpoch;
    final x = sin(2 * pi * ms / _periodX.inMilliseconds);
    final y = cos(2 * pi * ms / _periodY.inMilliseconds);
    return Offset(x * amplitude, y * amplitude);
  }
}

/// Adds a slowly-changing [drift] offset to a [State], refreshed on a timer.
mixin BurnInDriftMixin<T extends StatefulWidget> on State<T> {
  Timer? _driftTimer;
  Offset drift = Offset.zero;

  void startDrift() {
    drift = BurnInDrift.offsetAt(DateTime.now());
    _driftTimer = Timer.periodic(BurnInDrift.tick, (_) {
      if (!mounted) return;
      setState(() => drift = BurnInDrift.offsetAt(DateTime.now()));
    });
  }

  void stopDrift() {
    _driftTimer?.cancel();
    _driftTimer = null;
  }

  /// Apply the drift to [rect], keeping it fully on screen.
  Rect applyDrift(Rect rect, Size screen) {
    final moved = rect.translate(drift.dx, drift.dy);
    final dx = moved.left.clamp(0.0, max(0.0, screen.width - moved.width)) -
        moved.left;
    final dy = moved.top.clamp(0.0, max(0.0, screen.height - moved.height)) -
        moved.top;
    return moved.translate(dx, dy);
  }
}
