import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Cached network image that sends the Immich x-api-key header, retries on
/// failure with staggered backoff (the DSI home grid loads ~30 thumbnails at
/// once and the server drops some concurrent connections), and optionally
/// falls back to [fallbackUrl] (e.g. the original) for assets whose thumbnail
/// was never generated.
class RemoteImage extends StatefulWidget {
  final String url;
  final String? fallbackUrl;
  final Map<String, String> headers;
  final BoxFit fit;
  final int maxRetries;

  const RemoteImage({
    super.key,
    required this.url,
    required this.headers,
    this.fallbackUrl,
    this.fit = BoxFit.cover,
    this.maxRetries = 4,
  });

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  int _attempt = 0;
  bool _usingFallback = false;
  bool _retryPending = false;
  bool _gaveUp = false;
  final _rng = Random();

  String get _activeUrl =>
      _usingFallback && widget.fallbackUrl != null ? widget.fallbackUrl! : widget.url;

  void _onError() {
    if (_retryPending || _gaveUp || !mounted) return;
    if (_attempt < widget.maxRetries) {
      _retryPending = true;
      final ms = 250 * (_attempt + 1) + _rng.nextInt(400); // backoff + jitter
      Future.delayed(Duration(milliseconds: ms), () {
        if (!mounted) return;
        setState(() {
          _attempt++;
          _retryPending = false;
        });
      });
    } else if (widget.fallbackUrl != null && !_usingFallback) {
      _retryPending = true;
      Future.microtask(() {
        if (!mounted) return;
        setState(() {
          _usingFallback = true;
          _attempt = 0;
          _retryPending = false;
        });
      });
    } else {
      _gaveUp = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      key: ValueKey('$_activeUrl#$_attempt'),
      imageUrl: _activeUrl,
      httpHeaders: widget.headers,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 200),
      placeholder: (_, __) => const _Placeholder(loading: true),
      errorWidget: (_, __, ___) {
        _onError();
        // While retrying, keep showing a loading shimmer rather than a broken
        // icon; only show the broken icon once we've truly given up.
        return _Placeholder(loading: !_gaveUp);
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  final bool loading;
  const _Placeholder({required this.loading});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF20232E),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : const Icon(Icons.broken_image_outlined,
                color: Colors.white38, size: 34),
      ),
    );
  }
}
