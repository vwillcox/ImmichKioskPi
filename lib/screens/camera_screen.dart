import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../services/camera_service.dart';
import '../widgets/camera_overlay.dart';

/// The camera at full screen.
///
/// A route of its own rather than the corner window grown to fill the panel.
/// Growing one video surface from a small window to the whole screen leaves a
/// translucent white block over the middle of the picture on this display —
/// not the picture, not another window, and not something any amount of
/// simplifying the widget tree shifted. Shown as a page instead, at one size
/// from its first build, it renders cleanly.
class CameraScreen extends StatefulWidget {
  const CameraScreen({
    super.key,
    required this.player,
    required this.controller,
  });

  /// The one player in the app, owned by [CameraOverlay] and merely borrowed
  /// here. libmpv on this build tolerates a single instance: a second player
  /// alive at the same time never opens at all, and disposing one to build
  /// another leaves the replacement hanging before it registers its texture.
  /// So the stream stays open and only the widget showing it changes.
  final Player player;
  final VideoController controller;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  /// Zoom at the moment a pinch began, so the gesture scales from there
  /// rather than compounding every update.
  double _zoomAtGestureStart = 1.0;

  String? _hud;
  Timer? _hudTimer;

  @override
  void dispose() {
    // The player belongs to the overlay; leave it running.
    _hudTimer?.cancel();
    super.dispose();
  }

  void _showHud(String text) {
    setState(() => _hud = text);
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CameraService>();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RotatedBox(
            quarterTurns: service.settings.viewQuarterTurns,
            child: Video(
              controller: widget.controller,
              controls: NoVideoControls,
              fit: BoxFit.contain,
              fill: Colors.black,
            ),
          ),
          // Gestures above the picture: the video widget joins the gesture
          // arena too, and when it wins the tap goes nowhere.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              onDoubleTap: () {
                service.setZoom(service.minZoom);
                _showHud('${service.minZoom.toStringAsFixed(1)}×');
              },
              onScaleStart: (_) => _zoomAtGestureStart = service.zoom,
              onScaleUpdate: (d) {
                // A single finger reports a scale of 1.0 while dragging,
                // which would otherwise fight the tap handler.
                if (d.pointerCount < 2) return;
                service.setZoom(_zoomAtGestureStart * d.scale);
                _showHud('${service.zoom.toStringAsFixed(1)}×');
              },
            ),
          ),
          if (_hud != null)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  _hud!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          Positioned(
            top: 12,
            right: 12,
            child: CameraRoundButton(
              icon: Icons.close_fullscreen,
              size: 64,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: CameraControls(service: service),
          ),
        ],
      ),
    );
  }
}
