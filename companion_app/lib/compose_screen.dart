import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Compose a message to send straight to the kiosk, rather than sharing from
/// another app. The text field takes emoji exactly like any other text field
/// — the keyboard's own emoji key already handles that — the one thing that
/// needed real support here is attaching a GIF, so this also offers a
/// gallery picker for one.
///
/// Returns the composed pieces as [SharedMediaFile]s on pop, so the caller
/// can send them through the exact same path (and same history log) as a
/// share from another app.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key});

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final _text = TextEditingController();
  XFile? _gif;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickGif() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file != null) setState(() => _gif = file);
  }

  bool get _canSend => !_sending && (_text.text.trim().isNotEmpty || _gif != null);

  Future<void> _send() async {
    setState(() => _sending = true);
    final items = <SharedMediaFile>[];
    final text = _text.text.trim();
    if (text.isNotEmpty) {
      items.add(SharedMediaFile(path: text, type: SharedMediaType.text));
    }
    if (_gif != null) {
      items.add(SharedMediaFile(
        path: _gif!.path,
        type: SharedMediaType.image,
        mimeType: _gif!.mimeType ?? 'image/gif',
      ));
    }
    if (mounted) Navigator.of(context).pop(items);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New message')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _text,
              maxLines: 5,
              minLines: 3,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Message',
                hintText: 'Say something — your keyboard\'s emoji key '
                    'works here like anywhere else',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            if (_gif == null)
              OutlinedButton.icon(
                onPressed: _pickGif,
                icon: const Icon(Icons.gif_box_outlined),
                label: const Text('Add a GIF'),
              )
            else
              Card(
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  alignment: Alignment.topRight,
                  children: [
                    Image.file(
                      File(_gif!.path),
                      height: 160,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => const SizedBox(
                        height: 160,
                        child: Center(child: Icon(Icons.broken_image)),
                      ),
                    ),
                    IconButton(
                      style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                          foregroundColor: Colors.white),
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _gif = null),
                    ),
                  ],
                ),
              ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _canSend ? _send : null,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Text('Send to kiosk'),
            ),
          ],
        ),
      ),
    );
  }
}
