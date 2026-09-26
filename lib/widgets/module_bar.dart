import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../look.dart';
import 'package:provider/provider.dart';

import '../screens/dashboard_screen.dart';
import '../screens/locked_folder_screen.dart';
import '../screens/pin_screen.dart';
import '../screens/settings_screen.dart';
import '../services/camera_service.dart';
import '../services/config_service.dart';
import '../services/locked_folder_service.dart';
import 'glass.dart';

/// The kiosk's top-level places.
enum KioskModule { photos, dashboard }

/// The pill of buttons at the top right of the photos and the dashboard: the
/// way between the kiosk's parts, and the handful of switches worth having
/// one tap away.
///
/// One widget on both screens, so moving between them is the same gesture in
/// the same place, with the one you are on lit — rather than a back button on
/// one and a row of icons on the other.
class ModuleBar extends StatefulWidget {
  const ModuleBar({
    super.key,
    required this.current,
    this.onRefresh,
    this.colour,
    this.accent,
  });

  final KioskModule current;

  /// Shown as a Refresh button when given. The photos have something to
  /// reload; the dashboard's widgets refresh themselves.
  final VoidCallback? onRefresh;

  /// Icon colour. White on the kiosk's own screens; the dashboard passes its
  /// theme's, so the bar reads under a light theme too.
  /// The theme's text colour unless given.
  final Color? colour;

  /// The lit button's colour. The app's accent unless given.
  final Color? accent;

  @override
  State<ModuleBar> createState() => _ModuleBarState();
}

class _ModuleBarState extends State<ModuleBar> {
  static const String _remoteAppId = 'com.vwillcox.vidaa_remote';

  /// Whether the TV remote app is running, so its button only appears when
  /// it can actually flip to it.
  bool _remoteRunning = false;
  Timer? _remotePoll;

  @override
  void initState() {
    super.initState();
    _checkRemote();
    _remotePoll = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _checkRemote(),
    );
  }

  @override
  void dispose() {
    _remotePoll?.cancel();
    super.dispose();
  }

  /// Detect the remote's window via wlrctl; hide the button if wlrctl is
  /// missing or the remote isn't running.
  Future<void> _checkRemote() async {
    var running = false;
    try {
      final r = await Process.run('wlrctl', ['toplevel', 'list']);
      running =
          r.exitCode == 0 &&
          (r.stdout as String)
              .split('\n')
              .any((line) => line.startsWith('$_remoteAppId:'));
    } catch (_) {
      running = false;
    }
    if (mounted && running != _remoteRunning) {
      setState(() => _remoteRunning = running);
    }
  }

  void _toPhotos() {
    if (widget.current == KioskModule.photos) return;
    // The photos are the first screen; everything else stacks on top.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _toDashboard() {
    if (widget.current == KioskModule.dashboard) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DashboardScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent ?? Theme.of(context).colorScheme.primary;
    final c = widget.colour ?? context.look.textPrimary;
    final dashboardOn = context.watch<ConfigService>().config.dashboard.enabled;
    final camera = context.watch<CameraService>();

    Widget module(KioskModule m, IconData icon, String label, VoidCallback go) {
      final lit = widget.current == m;
      return PillIconButton(
        icon: icon,
        tooltip: label,
        colour: lit ? accent : c,
        selected: lit,
        selectedColour: accent,
        onPressed: go,
      );
    }

    return Glass(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          module(
            KioskModule.photos,
            Icons.photo_library_outlined,
            'Photos',
            _toPhotos,
          ),
          if (dashboardOn)
            module(
              KioskModule.dashboard,
              Icons.dashboard_outlined,
              'Dashboard',
              _toDashboard,
            ),
          if (_remoteRunning)
            PillIconButton(
              icon: Icons.settings_remote,
              tooltip: 'TV Remote',
              colour: c,
              onPressed: () => Process.run('wlrctl', [
                'toplevel',
                'focus',
                'app_id:$_remoteAppId',
              ]),
            ),
          // A hairline between "where to go" and "what to switch".
          Container(
            width: 1,
            height: 34,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: c.withValues(alpha: 0.18),
          ),
          if (context.watch<LockedFolderService>().canUse)
            PillIconButton(
              icon: Icons.lock_outline,
              tooltip: 'Locked Folder',
              colour: c,
              onPressed: () => openLockedFolder(context),
            ),
          if (camera.isConfigured)
            PillIconButton(
              icon: camera.isOpen
                  ? Icons.videocam_off_outlined
                  : Icons.videocam_outlined,
              tooltip: 'Camera',
              colour: c,
              onPressed: camera.toggleOpen,
            ),
          DndSwitch(colour: c, accent: accent),
          if (widget.onRefresh != null)
            PillIconButton(
              icon: Icons.refresh,
              tooltip: 'Refresh',
              colour: c,
              onPressed: widget.onRefresh,
            ),
          PillIconButton(
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            colour: c,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
    );
  }
}

/// Asks for the PIN, unlocks, and opens the Locked Folder — from wherever the
/// module bar is.
Future<void> openLockedFolder(BuildContext context) async {
  final locked = context.read<LockedFolderService>();
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final pin = await navigator.push<String>(
    MaterialPageRoute(
      builder: (_) => const PinScreen(
        title: 'Locked Folder',
        subtitle: 'Enter your Immich Locked Folder PIN',
      ),
    ),
  );
  if (pin == null || !context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  final result = await locked.unlock(pin);
  navigator.pop(); // dismiss loading

  void say(String m) => messenger.showSnackBar(SnackBar(content: Text(m)));
  switch (result) {
    case UnlockResult.success:
      navigator.push(
        MaterialPageRoute(builder: (_) => const LockedFolderScreen()),
      );
    case UnlockResult.wrongPin:
      say('Incorrect PIN');
    case UnlockResult.notConfigured:
      say('Locked Folder login is not configured');
    case UnlockResult.error:
      say('Could not sign in to Immich for the Locked Folder');
  }
}

/// Do Not Disturb: mutes every sound the panel makes by itself — the chime,
/// speech, the news reader and the timers — without changing their volumes.
/// A "slider" rather than an icon button
/// since that's specifically what was asked for, kept in the top bar so it's
/// reachable in one tap rather than buried in Settings.
class DndSwitch extends StatelessWidget {
  const DndSwitch({super.key, this.colour, this.accent});

  /// The theme's text colour unless given.
  final Color? colour;

  /// The switch's "on" colour — the dashboard theme's accent, so it does not
  /// stay the app's blue beside a theme's own. Null for the app's.
  final Color? accent;

  /// The app's switch, in [accent]: the track in the accent and the knob a
  /// deeper shade of it, as the app's own pairs a pale blue with a deep one.
  /// Left alone where the accent is the app's anyway.
  ThemeData _themed(ThemeData app) {
    final a = accent;
    if (a == null || a == app.colorScheme.primary) return app;
    final deep = HSLColor.fromColor(a).withLightness(0.45).toColor();
    return app.copyWith(
      colorScheme: app.colorScheme.copyWith(primary: a),
      switchTheme: app.switchTheme.copyWith(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? deep : Colors.grey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = colour ?? context.look.textPrimary;
    final config = context.watch<ConfigService>();
    final muted = config.config.shareInbox.dndMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            muted
                ? Icons.notifications_off_outlined
                : Icons.notifications_outlined,
            color: muted ? c.withValues(alpha: 0.54) : c,
            size: 26,
          ),
          Theme(
            data: _themed(Theme.of(context)),
            child: Switch(
              value: !muted,
              onChanged: (on) {
                config.config.shareInbox.dndMuted = !on;
                config.save();
              },
            ),
          ),
        ],
      ),
    );
  }
}
