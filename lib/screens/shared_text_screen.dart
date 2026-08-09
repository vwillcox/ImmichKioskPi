import 'package:flutter/material.dart';

import '../widgets/big_back_button.dart';

/// Full-screen display for a shared plain-text note (not a link — those
/// open in Chromium instead, see [IncomingShareOverlay]).
class SharedTextScreen extends StatelessWidget {
  final String text;
  final String sender;

  const SharedTextScreen({super.key, required this.text, required this.sender});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101828),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: BigBackButton(),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: const TextStyle(color: Colors.white, fontSize: 32),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'From $sender',
                        style: const TextStyle(color: Colors.white54, fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
