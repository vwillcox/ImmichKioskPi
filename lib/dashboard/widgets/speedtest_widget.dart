import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/speedtest_service.dart';
import '../dashboard_theme.dart';
import '../widget_registry.dart';
import 'speed_gauge.dart';

/// Runs Ookla's speedtest and shows it happening.
///
/// Tap to start. The dial fills as the test runs — ping first, then download
/// on the outer ring, then upload on the inner one — so it is worth watching
/// rather than a spinner followed by a number.
class DashboardSpeedtestWidget extends StatefulWidget {
  const DashboardSpeedtestWidget({super.key, required this.w});

  final DashboardWidgetContext w;

  @override
  State<DashboardSpeedtestWidget> createState() =>
      _DashboardSpeedtestWidgetState();
}

class _DashboardSpeedtestWidgetState extends State<DashboardSpeedtestWidget> {
  Timer? _auto;

  @override
  void initState() {
    super.initState();
    final everyHours = widget.w.option('everyHours', 0);
    if (everyHours > 0) {
      // Not on a Timer.periodic from zero: that would fire a test the moment
      // the dashboard opens, and again every time it is reopened.
      _auto = Timer.periodic(Duration(hours: everyHours), (_) => _run());
    }
  }

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  void _run() {
    if (!mounted) return;
    unawaited(context.read<SpeedtestService>().run());
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.w.theme;
    final service = context.watch<SpeedtestService>();
    final s = service.state;
    final maxMbps = (widget.w.option('maxMbps', 1000)).toDouble();

    final centre = switch (s.phase) {
      SpeedtestPhase.upload => s.uploadMbps,
      _ => s.downloadMbps,
    };

    final label = switch (s.phase) {
      SpeedtestPhase.idle => s.hasResult ? 'tap to retest' : 'tap to start',
      SpeedtestPhase.starting => 'connecting',
      SpeedtestPhase.ping => 'ping',
      SpeedtestPhase.download => 'download',
      SpeedtestPhase.upload => 'upload',
      SpeedtestPhase.done => 'tap to retest',
      SpeedtestPhase.failed => 'failed',
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: s.running ? service.cancel : _run,
      child: LayoutBuilder(
        builder: (context, c) {
          // Side by side when there is width to spare, stacked when the tile
          // is tall and narrow — the dial is the thing that must stay big.
          final wide = c.maxWidth > c.maxHeight * 1.5;
          final gauge = SpeedGauge(
            downloadMbps: s.downloadMbps,
            uploadMbps: s.uploadMbps,
            maxMbps: maxMbps,
            colour: t.accent,
            uploadColour: _uploadColour(t),
            trackColour: t.textSecondary.withValues(alpha: 0.15),
            textColour: t.textPrimary,
            mutedColour: t.textSecondary,
            label: label,
            centreValue: centre,
          );
          final readout = _Readout(theme: t, state: s);

          if (wide) {
            return Row(
              children: [
                Expanded(flex: 3, child: gauge),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: readout),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: gauge),
              const SizedBox(height: 8),
              readout,
            ],
          );
        },
      ),
    );
  }

  /// A second colour for upload, derived from the theme rather than fixed, so
  /// the two rings stay distinguishable under every theme.
  static Color _uploadColour(DashboardTheme t) {
    final hsl = HSLColor.fromColor(t.accent);
    return hsl
        .withHue((hsl.hue + 140) % 360)
        .withLightness((hsl.lightness + 0.08).clamp(0.0, 1.0))
        .toColor();
  }
}

/// The numbers beside the dial: both speeds, then ping, jitter and loss.
class _Readout extends StatelessWidget {
  const _Readout({required this.theme, required this.state});

  final DashboardTheme theme;
  final SpeedtestState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s.phase == SpeedtestPhase.failed) {
      return Center(
        child: Text(
          s.error ?? 'Speedtest failed',
          textAlign: TextAlign.center,
          maxLines: 3,
          style: TextStyle(color: theme.textSecondary, fontSize: 14),
        ),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(Icons.download, 'Down', _mbps(s.downloadMbps),
            active: s.phase == SpeedtestPhase.download, colour: theme.accent),
        const SizedBox(height: 6),
        _line(Icons.upload, 'Up', _mbps(s.uploadMbps),
            active: s.phase == SpeedtestPhase.upload,
            colour: _DashboardSpeedtestWidgetState._uploadColour(theme)),
        const Divider(height: 16),
        _small('Ping', s.latencyMs == null
            ? '—'
            : '${s.latencyMs!.toStringAsFixed(0)} ms'),
        _small('Jitter', s.jitterMs == null
            ? '—'
            : '${s.jitterMs!.toStringAsFixed(1)} ms'),
        if (s.packetLoss != null)
          _small('Loss', '${s.packetLoss!.toStringAsFixed(0)}%'),
        if (s.isp.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            s.isp,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.textSecondary, fontSize: 12),
          ),
        ],
        if (s.serverLocation.isNotEmpty)
          Text(
            'via ${s.serverLocation}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.textSecondary, fontSize: 11),
          ),
      ],
    );
  }

  static String _mbps(double v) =>
      v <= 0 ? '—' : (v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1));

  Widget _line(IconData icon, String name, String value,
      {required bool active, required Color colour}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: active ? colour : theme.textSecondary),
        const SizedBox(width: 6),
        Text(name,
            style: TextStyle(color: theme.textSecondary, fontSize: 13)),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: active ? colour : theme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _small(String name, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Text(name,
              style: TextStyle(color: theme.textSecondary, fontSize: 12)),
          const Spacer(),
          Text(value,
              style: TextStyle(color: theme.textPrimary, fontSize: 13)),
        ],
      ),
    );
  }
}

final speedtestWidgetType = DashboardWidgetType(
  type: 'speedtest',
  name: 'Speed test',
  description:
      'Runs Ookla speedtest and shows download and upload on one dial as it '
      'goes, with ping, jitter and packet loss. Tap to start. Needs the '
      'speedtest CLI installed — see moreinfo.md.',
  glyph: '📶',
  defaultWidth: 4,
  defaultHeight: 4,
  minWidth: 2,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'maxMbps',
      label: 'Top of the dial (Mbps)',
      kind: OptionKind.number,
      defaultValue: 1000,
      help: 'The scale is logarithmic, so this only needs to be the right '
          'order of magnitude for your line.',
    ),
    WidgetOption(
      key: 'everyHours',
      label: 'Run automatically every (hours)',
      kind: OptionKind.number,
      defaultValue: 0,
      help: '0 to only run when tapped. Each test uses a few hundred MB, so '
          'keep this well apart on a metered connection.',
    ),
  ],
  preview: const [
    PreviewLine('192', scale: 0.30, accent: true, centre: true),
    PreviewLine('Mbps', scale: 0.10, muted: true, centre: true),
    PreviewLine('↓ 192.6   ↑ 78.0', scale: 0.11, centre: true),
    PreviewLine('16 ms · 1.0 jitter', scale: 0.09, muted: true, centre: true),
  ],
  build: (context, w) => DashboardSpeedtestWidget(w: w),
);
