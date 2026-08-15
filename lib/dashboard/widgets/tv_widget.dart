import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/tv_service.dart';
import '../dashboard_theme.dart';
import '../widget_registry.dart';

/// A remote control for the television.
///
/// Connects only while it is on screen and lets go when it isn't: the set
/// permits one session per device UUID, so holding one open all day would
/// stop anything else — a phone, the standalone remote — from taking over.
class DashboardTvWidget extends StatefulWidget {
  const DashboardTvWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  State<DashboardTvWidget> createState() => _DashboardTvWidgetState();
}

class _DashboardTvWidgetState extends State<DashboardTvWidget> {
  @override
  void initState() {
    super.initState();
    // After the frame: connecting notifies listeners, and doing that during a
    // build is what schedules a build during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tv = context.read<TvService>();
      if (tv.conn == ConnState.disconnected) unawaited(tv.connect());
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.w.theme;
    final tv = context.watch<TvService>();

    switch (tv.conn) {
      case ConnState.connecting:
        return _Message(theme: t, text: 'Reaching the television…');
      case ConnState.needsPairing:
        return _Pairing(theme: t, tv: tv);
      case ConnState.error:
        return _Message(
          theme: t,
          text: tv.lastError ?? 'Could not reach the television.',
          action: ('Try again', () => unawaited(tv.connect())),
        );
      case ConnState.disconnected:
        return _Message(
          theme: t,
          text: 'Not connected.',
          action: ('Connect', () => unawaited(tv.connect())),
        );
      case ConnState.connected:
        break;
    }

    final compact = widget.w.option('compact', false);
    final showInputs = widget.w.option('inputs', false);
    return LayoutBuilder(
      builder: (context, c) {
        // A short tile has no room for a d-pad; a tall one should not waste
        // half its height on one row of volume buttons.
        final showPad = !compact && c.maxHeight > 220;
        return Column(
          children: [
            _Status(theme: t, tv: tv),
            const SizedBox(height: 8),
            if (showPad) ...[
              Expanded(child: _Pad(theme: t, tv: tv)),
              const SizedBox(height: 8),
            ],
            if (showInputs && tv.sources.isNotEmpty) ...[
              _Inputs(theme: t, tv: tv),
              const SizedBox(height: 8),
            ],
            _Transport(theme: t, tv: tv, expanded: !showPad),
          ],
        );
      },
    );
  }
}

/// Whatever the set has told us about itself.
class _Status extends StatelessWidget {
  const _Status({required this.theme, required this.tv});

  final DashboardTheme theme;
  final TvService tv;

  @override
  Widget build(BuildContext context) {
    final state = tv.state;
    // "HDMI1 · Fire TV Stick" beats "HDMI1" when you are glancing at this
    // from the sofa wondering what the television is showing.
    final current =
        state.sources.where((s) => s.id == state.sourceId).firstOrNull;
    final device = current?.deviceName ?? '';
    final bits = <String>[
      if ((state.sourceName ?? '').isNotEmpty) state.sourceName!,
      if (device.isNotEmpty) device,
      if (state.volume != null) state.muted ? 'muted' : 'vol ${state.volume}',
    ];
    return Row(
      children: [
        Icon(state.powerOn ? Icons.tv : Icons.tv_off,
            color: state.powerOn ? theme.accent : theme.textSecondary,
            size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            bits.isEmpty ? 'Television' : bits.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.textSecondary, fontSize: 15),
          ),
        ),
      ],
    );
  }
}

/// Direction pad with OK in the middle, and back/home either side.
class _Pad extends StatelessWidget {
  const _Pad({required this.theme, required this.tv});

  final DashboardTheme theme;
  final TvService tv;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // The pad is square and as large as the tile allows, so it stays
        // usable by thumb rather than shrinking to fit whatever is left.
        final side = c.maxHeight < c.maxWidth ? c.maxHeight : c.maxWidth;
        final unit = side / 3;
        Widget key(IconData icon, String code, {double scale = 1}) => _Key(
              theme: theme,
              icon: icon,
              size: unit * 0.94,
              iconScale: scale,
              onPressed: () => tv.key(code),
            );

        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                key(Icons.keyboard_arrow_up, 'KEY_UP'),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    key(Icons.keyboard_arrow_left, 'KEY_LEFT'),
                    _Key(
                      theme: theme,
                      label: 'OK',
                      size: unit * 0.94,
                      filled: true,
                      onPressed: () => tv.key('KEY_OK'),
                    ),
                    key(Icons.keyboard_arrow_right, 'KEY_RIGHT'),
                  ],
                ),
                key(Icons.keyboard_arrow_down, 'KEY_DOWN'),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Power, volume, mute, channel, back and home.
class _Transport extends StatelessWidget {
  const _Transport(
      {required this.theme, required this.tv, required this.expanded});

  final DashboardTheme theme;
  final TvService tv;

  /// True when there is no d-pad above, so these get the leftover height.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // Six across, sized from the tile with a floor that keeps them
        // thumb-sized. This is a remote control: nothing here should need
        // aiming at.
        final size = ((c.maxWidth / 6) - 6).clamp(48.0, expanded ? 96.0 : 72.0);
        Widget key(IconData icon, VoidCallback onPressed, {Color? colour}) =>
            _Key(
              theme: theme,
              icon: icon,
              size: size,
              colour: colour,
              onPressed: onPressed,
            );

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            key(Icons.power_settings_new, tv.power,
                colour: const Color(0xFFFF6B6B)),
            key(Icons.volume_down, tv.volumeDown),
            key(tv.state.muted ? Icons.volume_off : Icons.volume_mute, tv.mute),
            key(Icons.volume_up, tv.volumeUp),
            key(Icons.arrow_back, () => tv.key('KEY_BACK')),
            key(Icons.home, () => tv.key('KEY_HOME')),
          ],
        );
      },
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.theme,
    required this.size,
    required this.onPressed,
    this.icon,
    this.label,
    this.colour,
    this.filled = false,
    this.iconScale = 1,
  });

  final DashboardTheme theme;
  final double size;
  final VoidCallback onPressed;
  final IconData? icon;
  final String? label;
  final Color? colour;
  final bool filled;
  final double iconScale;

  @override
  Widget build(BuildContext context) {
    final foreground = colour ?? (filled ? theme.background.first : theme.textPrimary);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: filled
            ? theme.accent
            : Color.alphaBlend(
                theme.surface, theme.background.first.withValues(alpha: 1)),
        shape: CircleBorder(
          side: BorderSide(color: theme.textSecondary.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: icon != null
                ? Icon(icon, color: foreground, size: size * 0.5 * iconScale)
                : Center(
                    child: Text(
                      label!,
                      style: TextStyle(
                        color: foreground,
                        fontSize: size * 0.3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The one-time pairing: the set shows a PIN, which goes in here.
class _Pairing extends StatefulWidget {
  const _Pairing({required this.theme, required this.tv});

  final DashboardTheme theme;
  final TvService tv;

  @override
  State<_Pairing> createState() => _PairingState();
}

class _PairingState extends State<_Pairing> {
  final _pin = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final ok = await widget.tv.submitPin(_pin.text.trim());
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (!ok) _error = 'The television did not accept that PIN.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Pair with the television',
              style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? 'Tap "Show PIN", then type the number on the screen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _error == null ? t.textSecondary : Colors.redAccent,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: widget.tv.startPairing,
                  child: const Text('Show PIN'),
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _pin,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.textPrimary, fontSize: 20),
                    decoration: const InputDecoration(
                      hintText: 'PIN',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _sending ? null : _submit,
                  child: Text(_sending ? '…' : 'Pair'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.theme, required this.text, this.action});

  final DashboardTheme theme;
  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.textSecondary, fontSize: 15),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            FilledButton(onPressed: action!.$2, child: Text(action!.$1)),
          ],
        ],
      ),
    );
  }
}

final tvWidgetType = DashboardWidgetType(
  type: 'tv',
  name: 'TV remote',
  description:
      'Controls a Hisense VIDAA television: power, volume, channel and a '
      'direction pad. Set the address in Settings → Television.',
  glyph: '📺',
  defaultWidth: 3,
  defaultHeight: 4,
  minWidth: 2,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'inputs',
      label: 'Show a row of inputs',
      kind: OptionKind.boolean,
      defaultValue: false,
      help: 'Each input the television reports, with a dot showing whether '
          'anything is connected to it. Tap one to switch.',
    ),
    WidgetOption(
      key: 'compact',
      label: 'Buttons only, no direction pad',
      kind: OptionKind.boolean,
      defaultValue: false,
      help: 'For a short, wide tile where a pad would not fit anyway.',
    ),
  ],
  preview: const [
    PreviewLine('▲', scale: 0.16, centre: true),
    PreviewLine('◀  OK  ▶', scale: 0.16, accent: true, centre: true),
    PreviewLine('▼', scale: 0.16, centre: true),
    PreviewLine('⏻  −  🔇  +', scale: 0.12, muted: true, centre: true),
  ],
  build: (context, w) => DashboardTvWidget(w: w),
);

/// A scrolling row of the television's inputs, each with a light showing
/// whether anything is plugged into it.
///
/// Horizontal rather than a grid because this is a tile on a dashboard, not a
/// screen of its own — the standalone remote has room for the full grid.
class _Inputs extends StatelessWidget {
  const _Inputs({required this.theme, required this.tv});

  final DashboardTheme theme;
  final TvService tv;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tv.sources.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = tv.sources[i];
          final Color dot = s.hasSignal
              ? const Color(0xFF4ADE80)
              : (s.knownButAsleep ? const Color(0xFFF59E0B) : theme.textSecondary);
          return Material(
            color: s.isActive ? theme.accent : theme.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => tv.changeSource(s.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration:
                          BoxDecoration(color: dot, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      s.name,
                      style: TextStyle(
                        color: s.isActive ? Colors.white : theme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
