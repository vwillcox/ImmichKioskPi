import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/config_service.dart';
import '../services/immich_service.dart';

/// First-run / edit connection screen for Immich URL + API key.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  bool _obscure = true;
  bool _busy = false;
  String? _status;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    final c = context.read<ConfigService>();
    _url = TextEditingController(text: c.immichUrl);
    _key = TextEditingController(text: c.apiKey);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    final immich = context.read<ImmichService>();
    final config = context.read<ConfigService>();
    setState(() {
      _busy = true;
      _status = 'Testing connection…';
      _ok = false;
    });
    final ok = await immich.testConnectionWith(_url.text, _key.text);
    if (!mounted) return;
    if (ok) {
      await config.setConnection(_url.text, _key.text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Connected!';
        _ok = true;
      });
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _status = 'Could not connect. Check the URL and API key.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _url.text.trim().isNotEmpty && _key.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to Immich')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Immich server URL',
                    style: TextStyle(fontSize: 16, color: Colors.white70)),
                const SizedBox(height: 8),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontSize: 20),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'https://immich.example.com',
                    prefixIcon: Icon(Icons.link),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 20),
                const Text('API key',
                    style: TextStyle(fontSize: 16, color: Colors.white70)),
                const SizedBox(height: 8),
                TextField(
                  controller: _key,
                  obscureText: _obscure,
                  style: const TextStyle(fontSize: 20),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: 'Immich → Account → API Keys',
                    prefixIcon: const Icon(Icons.key),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: (_busy || !canSave) ? null : _testAndSave,
                  icon: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: const Text('Test & Save'),
                ),
                const SizedBox(height: 16),
                if (_status != null)
                  Text(
                    _status!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: _ok
                          ? const Color(0xFF6BE39A)
                          : (_busy ? Colors.white70 : const Color(0xFFFF6B6B)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
