import 'package:flutter/material.dart';

import '../widgets/numeric_keypad.dart';

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
              NumericKeypad(onDigit: _press, onBackspace: _backspace, onEnter: _submit),
            ],
          ),
        ),
      ),
    );
  }
}
