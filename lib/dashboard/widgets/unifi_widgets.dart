import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/unifi_models.dart';
import '../../services/unifi_service.dart';
import '../dashboard_theme.dart';
import '../widget_registry.dart';

/// Five views onto a UniFi console, sharing one service and one poll.
///
/// Separate widgets rather than one configurable panel because they answer
/// different questions and belong in different places: "is the internet up"
/// wants to be glanceable from the sofa, "which port is that switch using"
/// does not.

/// Shown by every one of them until the console has answered.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.theme, required this.service});

  final DashboardTheme theme;
  final UnifiService service;

  @override
  Widget build(BuildContext context) {
    final s = service.settings;
    final message = !s.enabled
        ? 'UniFi is switched off in Settings'
        : s.apiKey.isEmpty
            ? 'No API key set'
            : service.error != null
                ? 'Waiting for the console…'
                : 'Reading the network…';
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: theme.textSecondary, fontSize: 14),
      ),
    );
  }
}

/// A label above a value, which is most of what these widgets are.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.theme,
    required this.label,
    required this.value,
    this.colour,
    this.scale = 1,
  });

  final DashboardTheme theme;
  final String label;
  final String value;
  final Color? colour;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.textSecondary, fontSize: 12 * scale)),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              color: colour ?? theme.textPrimary,
              fontSize: 26 * scale,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Network health
// ---------------------------------------------------------------------------

/// Is the internet up, and is anything wrong.
class UnifiHealthWidget extends StatelessWidget {
  const UnifiHealthWidget({super.key, required this.w});
  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final unifi = context.watch<UnifiService>();
    if (!unifi.hasContent) return _Waiting(theme: t, service: unifi);

    final stats = unifi.gatewayStats;
    final offline = unifi.offlineDevices;
    final updates = unifi.updatableDevices;

    // "Up" is taken from the uplink reporting at all, not from a rate above
    // zero: a quiet connection is not a broken one.
    final wanUp = stats.txRateBps != null || stats.rxRateBps != null;
    final good = wanUp && offline.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(good ? Icons.check_circle : Icons.error,
                color: good ? const Color(0xFF4ADE80) : Colors.orangeAccent,
                size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                good
                    ? 'Network healthy'
                    : (!wanUp ? 'WAN down' : '${offline.length} device(s) offline'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: _Stat(
                    theme: t,
                    label: 'Down',
                    value: formatBps(stats.rxRateBps),
                    colour: t.accent)),
            Expanded(
                child: _Stat(
                    theme: t, label: 'Up', value: formatBps(stats.txRateBps))),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
                child: _Stat(
                    theme: t,
                    label: 'Clients',
                    value: '${unifi.clients.length}',
                    scale: 0.8)),
            Expanded(
                child: _Stat(
                    theme: t,
                    label: 'CPU',
                    value: stats.cpuPct == null
                        ? '—'
                        : '${stats.cpuPct!.toStringAsFixed(0)}%',
                    scale: 0.8)),
            Expanded(
                child: _Stat(
                    theme: t,
                    label: 'Memory',
                    value: stats.memoryPct == null
                        ? '—'
                        : '${stats.memoryPct!.toStringAsFixed(0)}%',
                    scale: 0.8)),
          ],
        ),
        if (updates.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('${updates.length} firmware update(s) available',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textSecondary, fontSize: 12)),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Who's home
// ---------------------------------------------------------------------------

/// Named devices currently on the network.
///
/// Presence, not location: this says a phone is associated to your own WiFi,
/// which for a household is the question actually being asked.
class UnifiPresenceWidget extends StatelessWidget {
  const UnifiPresenceWidget({super.key, required this.w});
  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final unifi = context.watch<UnifiService>();
    if (!unifi.hasContent) return _Waiting(theme: t, service: unifi);

    final watch = w
        .option('watch', '')
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();

    final wirelessOnly = w.option('wirelessOnly', true);
    var list = unifi.clients.where((c) => !wirelessOnly || c.wireless).toList();

    if (watch.isNotEmpty) {
      // A named list is the useful mode: thirty clients is an inventory, five
      // people's phones is a question you might actually ask.
      list = list
          .where((c) => watch.any((wanted) =>
              c.displayName.toLowerCase().contains(wanted) ||
              c.macAddress.toLowerCase() == wanted))
          .toList();
    }
    list.sort((a, b) => a.displayName
        .toLowerCase()
        .compareTo(b.displayName.toLowerCase()));

    if (list.isEmpty) {
      return Center(
        child: Text(
          watch.isEmpty ? 'Nobody connected' : 'None of those are here',
          style: TextStyle(color: t.textSecondary, fontSize: 14),
        ),
      );
    }

    // Names present are the point; whoever is watched but absent is shown
    // greyed rather than omitted, so the list does not change shape.
    final missing = watch
        .where((wanted) => !list.any((c) =>
            c.displayName.toLowerCase().contains(wanted) ||
            c.macAddress.toLowerCase() == wanted))
        .toList();

    return ListView(
      children: [
        for (final c in list)
          _PresenceRow(
            theme: t,
            name: c.displayName,
            here: true,
            detail: c.connectedFor == null
                ? (c.wireless ? 'wireless' : 'wired')
                : 'for ${formatUptime(c.connectedFor!)}',
          ),
        for (final name in missing)
          _PresenceRow(theme: t, name: name, here: false, detail: 'away'),
      ],
    );
  }
}

class _PresenceRow extends StatelessWidget {
  const _PresenceRow({
    required this.theme,
    required this.name,
    required this.here,
    required this.detail,
  });

  final DashboardTheme theme;
  final String name;
  final bool here;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: here ? const Color(0xFF4ADE80) : theme.textSecondary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: here ? theme.textPrimary : theme.textSecondary,
                fontSize: 16,
                fontWeight: here ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(detail,
              style: TextStyle(color: theme.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Devices and firmware
// ---------------------------------------------------------------------------

class UnifiDevicesWidget extends StatelessWidget {
  const UnifiDevicesWidget({super.key, required this.w});
  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final unifi = context.watch<UnifiService>();
    if (!unifi.hasContent) return _Waiting(theme: t, service: unifi);

    return ListView(
      children: [
        for (final d in unifi.devices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  d.online ? Icons.router : Icons.router_outlined,
                  size: 20,
                  color: d.online ? t.accent : Colors.orangeAccent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: t.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      Text(
                        [
                          d.model,
                          if (d.firmwareVersion.isNotEmpty) d.firmwareVersion,
                          if (unifi.statsFor(d.id).uptimeSec != null)
                            'up ${formatUptime(Duration(seconds: unifi.statsFor(d.id).uptimeSec!))}',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: t.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (d.firmwareUpdatable)
                  Icon(Icons.system_update_alt,
                      size: 18, color: t.accent),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Client detail
// ---------------------------------------------------------------------------

/// Every client, and what it is connected through.
///
/// Note what this deliberately does *not* claim: the official API reports no
/// signal strength or per-client throughput, so there is no "experience"
/// figure here. Showing one would mean inventing it.
class UnifiClientsWidget extends StatelessWidget {
  const UnifiClientsWidget({super.key, required this.w});
  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final unifi = context.watch<UnifiService>();
    if (!unifi.hasContent) return _Waiting(theme: t, service: unifi);

    final byId = {for (final d in unifi.devices) d.id: d};
    final clients = [...unifi.clients]..sort((a, b) {
        // Newest arrivals first: what just joined is the interesting end.
        final x = a.connectedAt, y = b.connectedAt;
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });

    return ListView(
      children: [
        for (final c in clients)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(c.wireless ? Icons.wifi : Icons.settings_ethernet,
                    size: 16, color: t.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Text(c.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.textPrimary, fontSize: 14)),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    byId[c.uplinkDeviceId]?.name ?? c.ipAddress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(color: t.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Throughput
// ---------------------------------------------------------------------------

class UnifiThroughputWidget extends StatelessWidget {
  const UnifiThroughputWidget({super.key, required this.w});
  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    final t = w.theme;
    final unifi = context.watch<UnifiService>();
    if (!unifi.hasContent) return _Waiting(theme: t, service: unifi);

    final stats = unifi.gatewayStats;
    final samples = unifi.throughput;
    final down = _uploadColour(t);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: _Stat(
                    theme: t,
                    label: 'Down',
                    value: formatBps(stats.rxRateBps),
                    colour: t.accent)),
            Expanded(
                child: _Stat(
                    theme: t,
                    label: 'Up',
                    value: formatBps(stats.txRateBps),
                    colour: down)),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: samples.length < 2
              ? Center(
                  child: Text('Collecting…',
                      style:
                          TextStyle(color: t.textSecondary, fontSize: 13)),
                )
              : CustomPaint(
                  size: Size.infinite,
                  painter: _ThroughputPainter(
                    samples: samples,
                    downColour: t.accent,
                    upColour: down,
                    gridColour: t.textSecondary.withValues(alpha: 0.15),
                  ),
                ),
        ),
      ],
    );
  }

  static Color _uploadColour(DashboardTheme t) {
    final hsl = HSLColor.fromColor(t.accent);
    return hsl.withHue((hsl.hue + 140) % 360).toColor();
  }
}

/// Two filled areas on a shared scale, so the asymmetry of a domestic line is
/// the obvious feature rather than something to work out.
class _ThroughputPainter extends CustomPainter {
  _ThroughputPainter({
    required this.samples,
    required this.downColour,
    required this.upColour,
    required this.gridColour,
  });

  final List<ThroughputSample> samples;
  final Color downColour;
  final Color upColour;
  final Color gridColour;

  @override
  void paint(Canvas canvas, Size size) {
    var peak = 0.0;
    for (final s in samples) {
      peak = math.max(peak, math.max(s.txBps, s.rxBps));
    }
    // A floor on the scale, so an idle line is a flat trace along the bottom
    // rather than noise amplified to fill the graph.
    peak = math.max(peak, 1000000);

    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height),
        Paint()..color = gridColour..strokeWidth = 1);

    void trace(double Function(ThroughputSample) pick, Color colour) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i < samples.length; i++) {
        final x = size.width * (i / (samples.length - 1));
        final y = size.height * (1 - (pick(samples[i]) / peak).clamp(0.0, 1.0));
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = colour.withValues(alpha: 0.28));

      final line = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = size.width * (i / (samples.length - 1));
        final y = size.height * (1 - (pick(samples[i]) / peak).clamp(0.0, 1.0));
        i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
      }
      canvas.drawPath(
          line,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = colour);
    }

    trace((s) => s.rxBps, downColour);
    trace((s) => s.txBps, upColour);
  }

  @override
  bool shouldRepaint(_ThroughputPainter old) =>
      old.samples.length != samples.length;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

const _needsKey =
    'Needs a UniFi API key — Network → Settings → Control Plane → Integrations.';

final unifiHealthWidgetType = DashboardWidgetType(
  type: 'unifi_health',
  name: 'Network health',
  description:
      'Whether the internet is up, current WAN speeds, client count, and any '
      'device offline or needing firmware. $_needsKey',
  glyph: '🛜',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 3,
  minHeight: 2,
  preview: const [
    PreviewLine('Network healthy', scale: 0.16, accent: true),
    PreviewLine('↓ 24.1 Mb/s   ↑ 1.2 Mb/s', scale: 0.13),
    PreviewLine('30 clients · CPU 34% · Mem 72%', scale: 0.10, muted: true),
  ],
  build: (context, w) => UnifiHealthWidget(w: w),
);

final unifiPresenceWidgetType = DashboardWidgetType(
  type: 'unifi_presence',
  name: "Who's home",
  description:
      'Which devices are on the network right now. Presence on your own WiFi '
      '— not a location. $_needsKey',
  glyph: '🏠',
  defaultWidth: 3,
  defaultHeight: 4,
  minWidth: 2,
  minHeight: 2,
  options: const [
    WidgetOption(
      key: 'watch',
      label: 'Only these, comma separated',
      kind: OptionKind.text,
      defaultValue: '',
      help: 'Part of a device name, or a MAC address. Leave empty to list '
          'everything. Anything named here but absent is shown greyed out, so '
          'the list keeps its shape.',
    ),
    WidgetOption(
      key: 'wirelessOnly',
      label: 'Wireless clients only',
      kind: OptionKind.boolean,
      defaultValue: true,
      help: 'People carry phones; servers and TVs are wired and always here.',
    ),
  ],
  preview: const [
    PreviewLine('● Vincent’s phone   for 4h', scale: 0.13),
    PreviewLine('● Jo’s watch   for 2h', scale: 0.13),
    PreviewLine('○ Guest phone   away', scale: 0.13, muted: true),
  ],
  build: (context, w) => UnifiPresenceWidget(w: w),
);

final unifiDevicesWidgetType = DashboardWidgetType(
  type: 'unifi_devices',
  name: 'UniFi devices',
  description:
      'Your router, switches and access points with model, firmware and '
      'uptime, and a marker against anything with an update. $_needsKey',
  glyph: '📡',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 3,
  minHeight: 2,
  preview: const [
    PreviewLine('Dream Router 7', scale: 0.14),
    PreviewLine('UDR7 · 5.1.19 · up 57d', scale: 0.10, muted: true),
    PreviewLine('USW Flex 2.5G 5', scale: 0.14),
  ],
  build: (context, w) => UnifiDevicesWidget(w: w),
);

final unifiClientsWidgetType = DashboardWidgetType(
  type: 'unifi_clients',
  name: 'Network clients',
  description:
      'Everything connected, newest first, and which device each is connected '
      'through. The API reports no signal strength, so none is shown. '
      '$_needsKey',
  glyph: '🔌',
  defaultWidth: 4,
  defaultHeight: 4,
  minWidth: 3,
  minHeight: 2,
  preview: const [
    PreviewLine('Vincents-Mini        Dream Router 7', scale: 0.11),
    PreviewLine('Hisense Vision       USW Flex 2.5G', scale: 0.11),
    PreviewLine('KP303                Dream Router 7', scale: 0.11, muted: true),
  ],
  build: (context, w) => UnifiClientsWidget(w: w),
);

final unifiThroughputWidgetType = DashboardWidgetType(
  type: 'unifi_throughput',
  name: 'WAN throughput',
  description:
      'Live up and down rates on the internet connection, graphed over about '
      'an hour. $_needsKey',
  glyph: '📈',
  defaultWidth: 4,
  defaultHeight: 3,
  minWidth: 3,
  minHeight: 2,
  preview: const [
    PreviewLine('↓ 24.1 Mb/s      ↑ 1.2 Mb/s', scale: 0.14, accent: true),
    PreviewLine('▁▂▅▇▆▃▂▁▂▄▆▇▅▂▁', scale: 0.20, centre: true),
  ],
  build: (context, w) => UnifiThroughputWidget(w: w),
);
