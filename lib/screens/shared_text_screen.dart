import 'package:flutter/material.dart';

import '../widgets/big_back_button.dart';

/// Full-screen display for a shared plain-text note (not a link — those
/// open in Chromium instead, see [IncomingShareOverlay]).
///
/// Sized to be read from across the room rather than from arm's length: this
/// panel is usually on a wall or a worktop, and a note is worth nothing if
/// you have to walk over to find out what it says.
class SharedTextScreen extends StatelessWidget {
  final String text;
  final String sender;

  const SharedTextScreen({super.key, required this.text, required this.sender});

  /// Type size chosen from how much there is to read.
  ///
  /// A fixed size can only suit one length: large enough for "back in 10
  /// minutes" would push a paragraph off the screen, and small enough for the
  /// paragraph makes the short note pointlessly timid. Buckets rather than a
  /// continuous scale, so two notes of similar length look alike instead of
  /// each being subtly its own size.
  ///
  /// Deliberately not a [FittedBox]: that would shrink a long note until it
  /// fitted, which is exactly the wrong answer — past a certain length the
  /// right behaviour is to stay readable and scroll.
  static double fontSizeFor(String text) {
    final length = text.trim().length;
    if (length <= 40) return 88;
    if (length <= 120) return 64;
    if (length <= 320) return 48;
    return 38;
  }

  @override
  Widget build(BuildContext context) {
    final size = fontSizeFor(text);

    return Scaffold(
      backgroundColor: const Color(0xFF101828),
      body: SafeArea(
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: BigBackButton(),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 64),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: size,
                        // Long notes need the extra leading to stay legible
                        // at a distance; short ones look loose with it.
                        height: size > 60 ? 1.18 : 1.34,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'From $sender',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 24,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Its own row at the bottom rather than floating over the note:
            // a wide message can run underneath a floating button, and the
            // one control that makes the screen go away should never be the
            // thing obscured by what it is dismissing.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
              child: _DismissButton(
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A large, obvious "I have read this" button.
///
/// Sized well past the usual 48px touch target because this screen is used
/// at arm's length or further, often in passing, and dismissing a note
/// should not need aiming.
class _DismissButton extends StatelessWidget {
  final VoidCallback onTap;
  const _DismissButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: const Color(0xFF2E6BE6),
        borderRadius: BorderRadius.circular(36),
        elevation: 6,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 56, vertical: 22),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check, color: Colors.white, size: 34),
                SizedBox(width: 14),
                Text(
                  'OK',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
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
