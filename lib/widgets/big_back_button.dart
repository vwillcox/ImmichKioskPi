import 'package:flutter/material.dart';

/// Large, high-contrast back button with a generous touch target for the
/// DSI touchscreen. Pops the current route (or calls [onTap] if given).
class BigBackButton extends StatelessWidget {
  final VoidCallback? onTap;
  final IconData icon;
  const BigBackButton({super.key, this.onTap, this.icon = Icons.arrow_back});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap ?? () => Navigator.of(context).maybePop(),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(icon, color: Colors.white, size: 34),
        ),
      ),
    );
  }
}
