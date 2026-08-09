import 'dart:io';

import 'package:flutter/material.dart';

import '../widgets/big_back_button.dart';
import 'gallery_screen.dart' show ZoomablePhoto;

/// Full-screen viewer for a shared image or GIF, reusing the same pinch/zoom
/// widget the photo gallery already uses — it only needs an [ImageProvider],
/// so a [FileImage] for a locally-saved share slots straight in.
class SharedImageScreen extends StatelessWidget {
  final String path;
  final String sender;

  const SharedImageScreen({super.key, required this.path, required this.sender});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: ZoomablePhoto(
              imageProvider: FileImage(File(path)),
              onZoomChanged: (_) {},
            ),
          ),
          Positioned(
            top: 24,
            left: 16,
            child: const BigBackButton(),
          ),
          Positioned(
            top: 36,
            left: 96,
            child: Text(
              'From $sender',
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
          ),
        ],
      ),
    );
  }
}
