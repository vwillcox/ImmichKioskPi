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
    if (length <= 40) return 132;
    if (length <= 120) return 96;
    if (length <= 320) return 68;
    return 50;
  }

  @override
  Widget build(BuildContext context) {
    final size = fontSizeFor(text);

    return Scaffold(
      backgroundColor: const Color(0xFF101828),
      body: SafeArea(
        // A Stack rather than a Column so the note is centred on the *screen*
        // rather than in whatever is left after the two rows of controls.
        // In a Column the back button above and the OK button below are
        // different heights, so the leftover space has a different centre
        // from the screen and a short note sits visibly high.
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                // Vertical padding is symmetric and clears the taller of the
                // two controls, which is what keeps the true centre of the
                // screen the centre of the text: pad only where a control
                // happens to be and the offset comes straight back.
                padding: const EdgeInsets.symmetric(
                    horizontal: 56, vertical: _controlGutter),
                child: ConstrainedBox(
                  // Without a floor the scroll view's child is free to be as
                  // short as it likes and pins itself to the top; giving it
                  // the full viewport height is what lets Center have room
                  // to work in. Anything taller still scrolls as before.
                  constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - _controlGutter * 2),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          text,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: size,
                            // Long notes need the extra leading to stay
                            // legible at a distance; short ones look loose
                            // with it.
                            height: size > 80 ? 1.14 : 1.3,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          'From $sender',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 26,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const Positioned(
              left: 16,
              top: 16,
              child: BigBackButton(),
            ),
            // Pinned rather than scrolling with the note: the control that
            // makes the screen go away should be in the same place whatever
            // the message is, and reachable without scrolling to the end of
            // a long one.
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: _DismissButton(
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Space kept clear at the top and bottom for the back and OK buttons.
  /// Applied to both ends equally — see the note in [build].
  static const double _controlGutter = 116;
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
