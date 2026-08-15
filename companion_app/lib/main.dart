import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'sealed_sender.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'compose_screen.dart';

void main() => runApp(const KioskShareApp());

class KioskShareApp extends StatelessWidget {
  const KioskShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kiosk Share',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7FB6FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

/// Where the kiosk's address and this phone's own token are kept — entered
/// once, handed out by whoever owns the kiosk (its Settings screen generates
/// the token), same trust model as sharing a Wi-Fi password.
class KioskSettings {
  static const _addressKey = 'kioskAddress';
  static const _tokenKey = 'kioskToken';

  final String address;
  final String token;
  const KioskSettings({required this.address, required this.token});

  bool get isConfigured => address.isNotEmpty && token.isNotEmpty;

  static Future<KioskSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return KioskSettings(
      address: prefs.getString(_addressKey) ?? '',
      token: prefs.getString(_tokenKey) ?? '',
    );
  }

  static Future<void> save(String address, String token) async {
    final prefs = await SharedPreferences.getInstance();
    // Trailing slashes make for a doubled-up //share further down.
    await prefs.setString(
        _addressKey, address.trim().replaceAll(RegExp(r'/+$'), ''));
    await prefs.setString(_tokenKey, token.trim());
  }
}

class ShareLogEntry {
  final String label;
  final bool ok;
  final String? error;
  /// Null for the one "share received before setup" placeholder entry —
  /// nothing to resend there.
  final SharedMediaFile? file;

  /// The kiosk key this was actually sealed to, or null if it never got far
  /// enough to seal. Recorded per entry rather than shown as a global banner
  /// so the claim is about *this* message and not about the app in general.
  final String? sealedTo;

  ShareLogEntry(
      {required this.label,
      required this.ok,
      this.error,
      this.file,
      this.sealedTo});
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  KioskSettings _settings = const KioskSettings(address: '', token: '');
  bool _loaded = false;
  StreamSubscription<List<SharedMediaFile>>? _sub;
  final List<ShareLogEntry> _log = [];

  /// The kiosk key's fingerprint once confirmed, and why not if it failed.
  String? _kioskKey;
  String? _keyError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final settings = await KioskSettings.load();
    if (mounted) {
      setState(() {
        _settings = settings;
        _loaded = true;
      });
      unawaited(_checkEncryption());
    }

    // Shares that arrive while the app is already running.
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleShares,
      onError: (e) => debugPrint('share stream error: $e'),
    );
    // Whatever share launched the app cold.
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initial.isNotEmpty) await _handleShares(initial);
    ReceiveSharingIntent.instance.reset();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _handleShares(List<SharedMediaFile> files) async {
    if (!_settings.isConfigured) {
      setState(() => _log.insert(
          0,
          ShareLogEntry(
              label: 'Share received',
              ok: false,
              error: 'Set up the kiosk address and token first')));
      return;
    }
    for (final f in files) {
      await _sendOne(f);
    }
  }

  Future<void> _sendOne(SharedMediaFile f) async {
    final label = switch (f.type) {
      SharedMediaType.text => 'Text',
      SharedMediaType.url => 'Link',
      SharedMediaType.image => 'Photo',
      SharedMediaType.video => 'Video',
      SharedMediaType.file => 'File',
    };
    try {
      // Everything goes out sealed: only the kiosk can read it, so the
      // reverse proxy it passes through on the way sees nothing but bytes.
      final sender = SealedSender(
        address: _settings.address,
        token: _settings.token,
      );
      http.Response resp;

      if (f.type == SharedMediaType.text || f.type == SharedMediaType.url) {
        final content = f.path.trim();
        final isLink = f.type == SharedMediaType.url ||
            (Uri.tryParse(content)?.hasScheme ?? false);
        resp = await sender.send(
          utf8.encode(
              jsonEncode({'type': isLink ? 'link' : 'text', 'content': content})),
          'application/json',
        );
      } else {
        final bytes = await File(f.path).readAsBytes();
        resp = await sender.send(bytes, f.mimeType ?? _guessMime(f));
      }

      final ok = resp.statusCode == 200;
      setState(() => _log.insert(
          0,
          ShareLogEntry(
            label: label,
            ok: ok,
            error: ok ? null : 'HTTP ${resp.statusCode}: ${resp.body}',
            file: f,
            sealedTo: sender.lastSealedTo,
          )));
    } catch (e) {
      setState(() => _log.insert(
          0, ShareLogEntry(label: label, ok: false, error: '$e', file: f)));
    }
  }

  Future<void> _resend(SharedMediaFile f) => _sendOne(f);

  /// Asks the kiosk for its public key and remembers the fingerprint.
  ///
  /// Deliberately a real request rather than a hardcoded "Encrypted ✓": a
  /// label that is always green tells you nothing. This one can only go green
  /// if the kiosk answered with a key this app knows how to seal to, so a
  /// panel that is unreachable, unpatched, or speaking a newer version of the
  /// format all show up as problems rather than as reassurance.
  Future<void> _checkEncryption() async {
    if (!_settings.isConfigured) return;
    setState(() {
      _kioskKey = null;
      _keyError = null;
    });
    try {
      final kid = await SealedSender(
        address: _settings.address,
        token: _settings.token,
      ).keyFingerprint();
      if (mounted) setState(() => _kioskKey = kid);
    } catch (e) {
      if (mounted) setState(() => _keyError = '$e');
    }
  }

  Widget _encryptionStatus(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;

    if (_keyError != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_open, size: 18, color: Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not confirm encryption.\n$_keyError',
              style: small?.copyWith(color: Colors.redAccent),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Check again',
            onPressed: _checkEncryption,
          ),
        ],
      );
    }

    if (_kioskKey == null) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text('Checking encryption…', style: small),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.lock, size: 18, color: Colors.green),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('End-to-end encrypted',
                  style: small?.copyWith(
                      color: Colors.green, fontWeight: FontWeight.w600)),
              // The fingerprint is shown so it can be compared against the one
              // on the panel's own senders page. Matching ids mean the key
              // this phone seals to is the key that kiosk holds, which is the
              // part a machine in the middle could otherwise lie about.
              Text('Kiosk key $_kioskKey', style: small),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Check again',
          onPressed: _checkEncryption,
        ),
      ],
    );
  }

  String _guessMime(SharedMediaFile f) {
    final ext = f.path.toLowerCase().split('.').last;
    switch (ext) {
      case 'gif':
        return 'image/gif';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      default:
        return f.type == SharedMediaType.video ? 'video/mp4' : 'image/jpeg';
    }
  }

  Future<void> _editSettings() async {
    final result = await Navigator.of(context).push<KioskSettings>(
      MaterialPageRoute(builder: (_) => SettingsScreen(current: _settings)),
    );
    if (result != null) {
      setState(() => _settings = result);
      // A new address or token means a different kiosk, or none: recheck
      // rather than leaving the old fingerprint sitting there looking valid.
      unawaited(_checkEncryption());
    }
  }

  Future<void> _compose() async {
    final items = await Navigator.of(context).push<List<SharedMediaFile>>(
      MaterialPageRoute(builder: (_) => const ComposeScreen()),
    );
    if (items != null && items.isNotEmpty) await _handleShares(items);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kiosk Share'),
        actions: [
          if (_loaded)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _editSettings,
            ),
        ],
      ),
      floatingActionButton: _loaded
          ? FloatingActionButton.extended(
              onPressed: _compose,
              icon: const Icon(Icons.edit),
              label: const Text('New message'),
            )
          : null,
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _settings.isConfigured ? 'Ready to share' : 'Not set up yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _settings.isConfigured
                          ? _settings.address
                          : "Tap the gear icon to enter your kiosk's address "
                              'and token.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_settings.isConfigured) ...[
                      const Divider(height: 22),
                      _encryptionStatus(context),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Use the share button in any app (Photos, Chrome, '
                  'a video) and pick Kiosk Share to send it here.'),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _log.isEmpty
                ? const Center(child: Text('Nothing shared yet'))
                : ListView.builder(
                    itemCount: _log.length,
                    itemBuilder: (context, i) {
                      final entry = _log[i];
                      return ListTile(
                        leading: Icon(
                          entry.ok ? Icons.check_circle : Icons.error,
                          color: entry.ok ? Colors.green : Colors.redAccent,
                        ),
                        title: Row(
                          children: [
                            Text(entry.label),
                            // Per message, and only when one was really
                            // sealed — an entry without the padlock did not
                            // get encrypted, whatever the card above says.
                            if (entry.sealedTo != null) ...[
                              const SizedBox(width: 6),
                              const Icon(Icons.lock,
                                  size: 14, color: Colors.green),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          entry.error ??
                              (entry.sealedTo != null
                                  ? 'Encrypted to key ${entry.sealedTo}'
                                  : 'Sent unencrypted'),
                        ),
                        trailing: entry.file == null
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.replay),
                                tooltip: 'Resend',
                                onPressed: () => _resend(entry.file!),
                              ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final KioskSettings current;
  const SettingsScreen({super.key, required this.current});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _address =
      TextEditingController(text: widget.current.address);
  late final TextEditingController _token =
      TextEditingController(text: widget.current.token);

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await KioskSettings.save(_address.text, _token.text);
    if (mounted) {
      Navigator.of(context).pop(KioskSettings(
        address: _address.text.trim().replaceAll(RegExp(r'/+$'), ''),
        token: _token.text.trim(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Ask whoever owns the kiosk for its address and the token "
              "they generated for you in its Settings.",
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Kiosk address',
                hintText: 'https://mine.example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                labelText: 'Your token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}
