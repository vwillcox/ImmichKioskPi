import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../services/config_service.dart';
import '../services/locked_folder_service.dart';
import '../services/media_cache.dart';
import '../services/now_playing_service.dart';
import '../services/weather_service.dart';
import '../widgets/weather_overlay.dart';
import 'about_screen.dart';
import 'setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _editConnection() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SetupScreen()));
    if (mounted) setState(() {});
  }

  Future<void> _confirmPower({
    required String title,
    required String action, // 'poweroff' | 'reboot'
    required String verb,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text('$verb the device now?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(verb),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await Process.run('systemctl', [action]);
      if (r.exitCode != 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Could not $verb (${r.stderr.toString().trim()}). '
            'Run deploy/enable-poweroff.sh on the Pi.',
          ),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not $verb: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<ConfigService>();
    final locked = context.watch<LockedFolderService>();
    final maskedKey = config.apiKey.isEmpty
        ? '—'
        : '${config.apiKey.substring(0, config.apiKey.length.clamp(0, 4))}••••••••';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _section('Connection'),
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('Immich server'),
            subtitle:
                Text(config.immichUrl.isEmpty ? 'Not set' : config.immichUrl),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editConnection,
          ),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('API key'),
            subtitle: Text(maskedKey),
            onTap: _editConnection,
          ),

          const Divider(height: 32),
          _section('Locked Folder'),
          ListTile(
            leading: Icon(locked.canUse ? Icons.lock : Icons.lock_open,
                color: locked.canUse ? null : const Color(0xFFFFC46B)),
            title: const Text('Immich account login'),
            subtitle: Text(
              locked.canUse
                  ? 'Signed in as ${config.immichEmail} — open the Locked Folder '
                      'tile on the home screen and enter your PIN.'
                  : 'Not configured. Run set-immich-login.sh on the Pi to store '
                      'your Immich email + password (required to open the '
                      'server-side Locked Folder).',
            ),
            isThreeLine: true,
          ),

          const Divider(height: 32),
          _section('Weather'),
          const _WeatherSettingsTile(),

          const Divider(height: 32),
          _section('Now playing'),
          const _NowPlayingSettingsTile(),

          const Divider(height: 32),
          _section('Slideshow'),
          const _SlideshowSettingsTile(),

          const Divider(height: 32),
          _section('Storage'),
          const _CacheTile(),

          const Divider(height: 32),
          _section('Device'),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Restart'),
            onTap: () => _confirmPower(
                title: 'Restart', action: 'reboot', verb: 'Restart'),
          ),
          ListTile(
            leading: const Icon(Icons.power_settings_new,
                color: Color(0xFFFF6B6B)),
            title: const Text('Power off',
                style: TextStyle(color: Color(0xFFFF8A8A))),
            onTap: () => _confirmPower(
                title: 'Power off', action: 'poweroff', verb: 'Power off'),
          ),
          const Divider(height: 32),
          _section('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About ImmichKioskPi'),
            subtitle: const Text(
                'Version, open-source libraries, licences and credits'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AboutScreen()),
            ),
          ),

          const SizedBox(height: 24),
          Center(
            child: Text('Immich Kiosk - Pi • Immich viewer',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.3))),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            fontSize: 13,
          ),
        ),
      );
}

class _WeatherSettingsTile extends StatelessWidget {
  const _WeatherSettingsTile();

  Future<void> _editLocation(BuildContext context) async {
    final service = context.read<WeatherService>();
    final s = context.read<ConfigService>().config.weather;
    final controller = TextEditingController(text: s.location);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Weather location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'UK postcode (e.g. CO1 1ZY) or a place name (e.g. Colchester).',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 20),
              decoration: const InputDecoration(border: OutlineInputBorder()),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      s.location = result.trim();
      await service.updateSettings(s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<ConfigService>();
    final service = context.watch<WeatherService>();
    final s = config.config.weather;
    final w = service.weather;

    return Column(
      children: [
        SwitchListTile(
          secondary: Icon(
            w != null ? weatherIcon(w.weatherCode, w.isDay) : Icons.cloud,
          ),
          title: const Text('Show weather in slideshow'),
          subtitle: Text(
            service.error ??
                (w != null
                    ? '${w.temperature.round()}${w.unit} · ${w.description} · ${w.label}'
                    : 'Loading…'),
          ),
          value: s.enabled,
          onChanged: (v) {
            s.enabled = v;
            service.updateSettings(s);
          },
        ),
        ListTile(
          enabled: s.enabled,
          leading: const Icon(Icons.place_outlined),
          title: const Text('Location'),
          subtitle: Text(s.location),
          trailing: const Icon(Icons.edit),
          onTap: s.enabled ? () => _editLocation(context) : null,
        ),
        ListTile(
          enabled: s.enabled,
          leading: const Icon(Icons.picture_in_picture_alt_outlined),
          title: const Text('Position'),
          subtitle: Text(cornerLabel(s.corner)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _CornerPicker(
            value: s.corner,
            enabled: s.enabled,
            onChanged: (c) {
              s.corner = c;
              service.updateSettings(s);
            },
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.thermostat),
          title: const Text('Use Celsius'),
          subtitle: Text(s.metric ? '°C' : '°F'),
          value: s.metric,
          onChanged: s.enabled
              ? (v) {
                  s.metric = v;
                  service.updateSettings(s);
                }
              : null,
        ),
        ListTile(
          enabled: s.enabled,
          leading: const Icon(Icons.refresh),
          title: const Text('Refresh now'),
          onTap: s.enabled ? () => service.refresh(force: true) : null,
        ),
      ],
    );
  }
}

/// 2x2 grid of corner buttons mirroring the screen layout.
class _CornerPicker extends StatelessWidget {
  final OverlayCorner value;
  final bool enabled;
  final ValueChanged<OverlayCorner> onChanged;
  const _CornerPicker({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget cell(OverlayCorner c, Alignment align) {
      final selected = value == c;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Material(
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.30)
                : const Color(0xFF20232E),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: enabled ? () => onChanged(c) : null,
              child: Container(
                height: 54,
                alignment: align,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white12,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Container(
                  width: 34,
                  height: 16,
                  decoration: BoxDecoration(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Column(
        children: [
          Row(children: [
            cell(OverlayCorner.topLeft, Alignment.topLeft),
            cell(OverlayCorner.topRight, Alignment.topRight),
          ]),
          Row(children: [
            cell(OverlayCorner.bottomLeft, Alignment.bottomLeft),
            cell(OverlayCorner.bottomRight, Alignment.bottomRight),
          ]),
        ],
      ),
    );
  }
}

class _SlideshowSettingsTile extends StatelessWidget {
  const _SlideshowSettingsTile();

  @override
  Widget build(BuildContext context) {
    final config = context.watch<ConfigService>();
    final s = config.slideshow;

    void save() => config.updateSlideshow(s);

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Time per photo'),
          trailing:
              Text('${s.intervalSeconds}s', style: const TextStyle(fontSize: 18)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            min: 3,
            max: 30,
            divisions: 27,
            label: '${s.intervalSeconds}s',
            value: s.intervalSeconds.toDouble(),
            onChanged: (v) {
              s.intervalSeconds = v.round();
              save();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.animation),
          title: const Text('Transition'),
          trailing: DropdownButton<SlideshowTransition>(
            value: s.transition,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(
                  value: SlideshowTransition.fade, child: Text('Fade')),
              DropdownMenuItem(
                  value: SlideshowTransition.slide, child: Text('Slide')),
              DropdownMenuItem(
                  value: SlideshowTransition.kenBurns, child: Text('Ken Burns')),
            ],
            onChanged: (v) {
              if (v != null) {
                s.transition = v;
                save();
              }
            },
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.shuffle),
          title: const Text('Shuffle'),
          value: s.shuffle,
          onChanged: (v) {
            s.shuffle = v;
            save();
          },
        ),
      ],
    );
  }
}

/// Shows how much the on-disk media cache is using, with a way to clear it.
class _CacheTile extends StatefulWidget {
  const _CacheTile();

  @override
  State<_CacheTile> createState() => _CacheTileState();
}

class _CacheTileState extends State<_CacheTile> {
  int? _bytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final b = await ImmichKioskPiCache.diskUsageBytes();
    if (mounted) setState(() => _bytes = b);
  }

  String _human(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    await ImmichKioskPiCache.clear();
    await _measure();
    if (mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.sd_storage_outlined),
      title: const Text('Photo cache'),
      subtitle: Text(
        _bytes == null
            ? 'Measuring…'
            : '${_human(_bytes!)} on disk  •  ~/.cache/immich_kiosk_pi',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
          : TextButton(onPressed: _clear, child: const Text('Clear')),
    );
  }
}

/// Toggle the now-playing overlay and choose which corner it sits in.
class _NowPlayingSettingsTile extends StatelessWidget {
  const _NowPlayingSettingsTile();

  @override
  Widget build(BuildContext context) {
    final config = context.watch<ConfigService>();
    final service = context.watch<NowPlayingService>();
    final s = config.config.nowPlaying;
    final n = service.now;

    return Column(
      children: [
        SwitchListTile(
          secondary: Icon(
            s.enabled ? Icons.music_note : Icons.music_off,
            color: s.enabled ? null : Colors.white38,
          ),
          title: const Text('Show what my phone is playing'),
          subtitle: Text(
            service.available
                ? (n.hasTrack
                    ? 'Connected to ${n.deviceName.isEmpty ? "phone" : n.deviceName} — ${n.title}'
                    : 'Connected to ${n.deviceName.isEmpty ? "phone" : n.deviceName} — nothing playing')
                : 'No phone connected. Pair one over Bluetooth and play '
                    'something with media audio routed to this device.',
          ),
          isThreeLine: !service.available,
          value: s.enabled,
          onChanged: (v) {
            s.enabled = v;
            config.save();
          },
        ),
        if (s.enabled)
          SwitchListTile(
            secondary: Icon(
              s.playAudioHere ? Icons.speaker : Icons.headphones,
              color: s.playAudioHere ? null : const Color(0xFF7FE3A1),
            ),
            title: const Text('Play the audio on this device'),
            subtitle: Text(
              s.playAudioHere
                  ? 'Music plays through the Pi\'s speaker.'
                  : 'Music stays on the phone (e.g. your headphones) and this '
                      'screen is just a remote control.',
            ),
            isThreeLine: !s.playAudioHere,
            value: s.playAudioHere,
            onChanged: (v) {
              s.playAudioHere = v;
              config.save();
              service.preferAudioRouted = v;
            },
          ),
        if (s.enabled)
          ListTile(
            leading: const Icon(Icons.picture_in_picture_alt),
            title: const Text('Position'),
            subtitle: const Text('Which corner the player sits in'),
            trailing: DropdownButton<OverlayCorner>(
              value: s.corner,
              underline: const SizedBox.shrink(),
              items: OverlayCorner.values
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text(cornerLabel(c)),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  s.corner = v;
                  config.save();
                }
              },
            ),
          ),
      ],
    );
  }
}
