import 'package:flutter/material.dart';

/// A telephone-style number pad.
///
/// This panel has no on-screen keyboard — it is a bare Wayland session with no
/// desktop and nothing to raise one — so anywhere a number has to be typed
/// needs its own. Shared between the Locked Folder's PIN and the television's
/// pairing code rather than written twice, because two keypads drift.
///
/// Sized from [keySize] rather than fixed, so the same pad works full-screen
/// and inside a dashboard tile.
class NumericKeypad extends StatelessWidget {
  const NumericKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    required this.onEnter,
    this.keySize = 88,
    this.background,
    this.foreground,
    this.enterColour,
    this.enterEnabled = true,
  });

  final void Function(String) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;

  /// Diameter of one key. The pad is three of these across and four down,
  /// plus padding.
  final double keySize;

  final Color? background;
  final Color? foreground;
  final Color? enterColour;

  /// A greyed-out enter key still occupies its place, so the pad does not
  /// change shape when there is nothing to submit yet.
  final bool enterEnabled;

  /// What a pad of [keySize] needs, so a caller can decide whether it fits.
  static Size sizeFor(double keySize) {
    final step = keySize + 12;
    return Size(step * 3, step * 4);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = background ?? const Color(0xFF1B1E27);
    final fg = foreground ?? Colors.white;

    Widget key(Widget child, VoidCallback? onTap, {Color? colour}) {
      return Padding(
        padding: const EdgeInsets.all(6),
        child: Material(
          color: colour ?? bg,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: keySize,
              height: keySize,
              child: Center(child: child),
            ),
          ),
        ),
      );
    }

    Widget digit(String d) => key(
          Text(d,
              style: TextStyle(
                fontSize: keySize * 0.36,
                fontWeight: FontWeight.w500,
                color: fg,
              )),
          () => onDigit(d),
        );

    Widget row(List<Widget> children) =>
        Row(mainAxisSize: MainAxisSize.min, children: children);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([digit('1'), digit('2'), digit('3')]),
        row([digit('4'), digit('5'), digit('6')]),
        row([digit('7'), digit('8'), digit('9')]),
        row([
          key(Icon(Icons.backspace_outlined, size: keySize * 0.32, color: fg),
              onBackspace),
          digit('0'),
          key(
            Icon(Icons.check,
                size: keySize * 0.34,
                color: enterEnabled ? Colors.white : Colors.white38),
            enterEnabled ? onEnter : null,
            colour: enterEnabled
                ? (enterColour ?? scheme.primary)
                : bg,
          ),
        ]),
      ],
    );
  }
}
