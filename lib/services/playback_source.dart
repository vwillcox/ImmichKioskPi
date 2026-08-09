import 'package:flutter/material.dart';

import 'now_playing_service.dart';

/// Common shape for anything the now-playing overlay can display: the phone
/// over Bluetooth AVRCP, or a Spotify Connect session over the Web API.
///
/// The overlay itself (position, expand/collapse animation, idle-hide,
/// burn-in drift) doesn't care which one is behind it — only the content does
/// — so the widget layer is written once against this interface and each
/// source just needs to fill it in faithfully.
abstract class PlaybackSource extends ChangeNotifier {
  NowPlaying get now;
  String? get artUrl;

  /// True once this source has real data to show (not just "configured").
  bool get available;

  /// True once nothing has played for a while and the panel should hide.
  bool get idleHidden;

  bool get hasVolume;
  double get volume;
  bool get muted;

  /// Whether [seek] does anything real. AVRCP (BlueZ) has no absolute-seek
  /// method, so the progress bar there is display-only; Spotify's Web API
  /// does support it.
  bool get canSeek;

  /// Shown next to the device name in the expanded view.
  IconData get sourceIcon;

  Future<void> playPause();
  Future<void> next();
  Future<void> previous();
  Future<void> cycleRepeat();
  Future<void> toggleShuffle();
  Future<void> setVolume(double fraction);
  Future<void> toggleMute();
  Future<void> seek(Duration position);
}
