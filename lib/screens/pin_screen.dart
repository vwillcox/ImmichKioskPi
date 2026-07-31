import 'package:flutter/material.dart';

/// Numeric PIN entry. Returns the entered PIN string via [onSubmit]-style
/// Navigator.pop(pin), or pop(null) on cancel. Use [title]/[subtitle] to
/// repurpose for "unlock", "set new PIN", or "confirm PIN".
class PinScreen extends StatefulWidget {
  final String title;
  final String subtitle;

  /// Validate the entered PIN. Return an error string to show, or null to
  /// accept (which pops with the PIN). If null, any 4+ digit PIN is accepted.
  final String? Function(String pin)? validator;

  const PinScreen({
    super.key,
    this.title = 'Enter PIN',
    this.subtitle = '',
    this.validator,
  });

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = '';
  String? _error;
  static const _maxLen = 8;

  void _press(String d) {
    if (_pin.length >= _maxLen) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _submit() {
    if (_pin.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }
    final err = widget.validator?.call(_pin);
    if (err != null) {
      setState(() {
        _error = err;
        _pin = '';
      });
      return;
    }
    Navigator.of(context).pop(_pin);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        title: Text(widget.title),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(widget.subtitle,
                      style: const TextStyle(fontSize: 18, color: Colors.white70)),
                ),
              // PIN dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pin.isEmpty ? 4 : _pin.length, (i) {
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _pin.length
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white24,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 28,
                child: Text(
                  _error ?? '',
                  style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 16),
                ),
              ),
              const SizedBox(height: 8),
              _Keypad(onDigit: _press, onBackspace: _backspace, onEnter: _submit),
            ],
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  final void Function(String) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;
  const _Keypad({
    required this.onDigit,
    required this.onBackspace,
    required this.onEnter,
  });

  @override
  Widget build(BuildContext context) {
    Widget key(Widget child, VoidCallback onTap, {Color? color}) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: color ?? const Color(0xFF1B1E27),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 88, height: 88, child: Center(child: child)),
          ),
        ),
      );
    }

    Widget digit(String d) => key(
          Text(d, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w500)),
          () => onDigit(d),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [digit('1'), digit('2'), digit('3')]),
        Row(mainAxisSize: MainAxisSize.min, children: [digit('4'), digit('5'), digit('6')]),
        Row(mainAxisSize: MainAxisSize.min, children: [digit('7'), digit('8'), digit('9')]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          key(const Icon(Icons.backspace_outlined, size: 28), onBackspace),
          digit('0'),
          key(const Icon(Icons.check, size: 30, color: Colors.white),
              onEnter,
              color: Theme.of(context).colorScheme.primary),
        ]),
      ],
    );
  }
}
