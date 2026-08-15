import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'sealed_share.dart';

/// Reads a sealed body: the header line, then length-prefixed sealed chunks.
///
/// Written as a streaming reader rather than "decrypt the whole body" so a
/// video is decrypted straight to disk in 64 KiB pieces. Holding a phone
/// video in memory to decrypt it would be the one change most likely to make
/// this Pi fall over.
class SealedReader {
  SealedReader({required this.keyFor});

  /// Looks up the identity key a header names. Returning null means the
  /// message was sealed to a key this panel no longer holds.
  final Future<SimpleKeyPair?> Function(String kid) keyFor;

  /// Decrypts [input], emitting plaintext as it arrives.
  ///
  /// Throws [SealedFormatException] on anything malformed and
  /// [SealedAuthException] when a chunk fails its authentication tag — which
  /// is what tampering, truncation, reordering and a wrong key all look like.
  Stream<List<int>> open(Stream<List<int>> input,
      {void Function(SealedHeader header)? onHeader}) async* {
    final buffer = _Buffer();
    SealedHeader? header;
    SecretKey? key;
    var index = 0;
    var sawFinal = false;

    await for (final data in input) {
      buffer.add(data);

      if (header == null) {
        final line = buffer.takeLine();
        if (line == null) {
          // A header this long is not a header.
          if (buffer.length > 4096) {
            throw const SealedFormatException('no header found');
          }
          continue;
        }
        try {
          header = SealedHeader.parse(line);
        } on FormatException catch (e) {
          throw SealedFormatException(e.message);
        }
        onHeader?.call(header);

        final pair = await keyFor(header.kid);
        if (pair == null) {
          throw SealedAuthException(
              'sealed to key ${header.kid}, which this panel no longer holds');
        }
        key = await SealedShare.deriveKey(
          sharedSecret: await SealedShare.sharedSecretFor(
            keyPair: pair,
            remotePublicKey: header.ephemeralPublicKey,
          ),
          salt: header.salt,
          kid: header.kid,
          ephemeralPublicKey: header.ephemeralPublicKey,
        );
      }

      while (true) {
        if (sawFinal) {
          if (buffer.length > 0) {
            throw const SealedFormatException('data after the final chunk');
          }
          break;
        }
        final frame = buffer.takeFrame();
        if (frame == null) break;
        // The last chunk is the one that authenticates as last; every chunk
        // is tried as ordinary first, so an attacker cannot end the stream
        // early by flipping a flag they do not have the key to change.
        List<int>? plain;
        try {
          plain = await SealedShare.openChunk(
              key: key!, frame: frame.bytes, index: index, last: false);
        } on SecretBoxAuthenticationError {
          try {
            plain = await SealedShare.openChunk(
                key: key!, frame: frame.bytes, index: index, last: true);
            sawFinal = true;
          } on SecretBoxAuthenticationError {
            throw SealedAuthException(
                'chunk $index failed authentication — wrong key, or altered '
                'in transit');
          }
        }
        index++;
        if (plain.isNotEmpty) yield plain;
      }
    }

    if (header == null) throw const SealedFormatException('empty body');
    if (!sawFinal) {
      throw const SealedAuthException(
          'the message ended without its final chunk — it was cut short');
    }
    if (buffer.length > 0) {
      throw const SealedFormatException('trailing data');
    }
  }
}

/// Seals a body the way [SealedReader] expects.
///
/// Lives here rather than only in the phone app so the format has one
/// definition, and so the round trip can be tested without an Android build.
class SealedWriter {
  SealedWriter({required this.recipientPublicKey, required this.kid});

  final List<int> recipientPublicKey;
  final String kid;

  /// A fresh key pair per message: the ephemeral private half never leaves
  /// this function and is discarded when it returns, which is what makes past
  /// messages unrecoverable even if the panel's identity key is later taken.
  Stream<List<int>> seal(Stream<List<int>> plaintext,
      {required String mime}) async* {
    final ephemeral = await SealedShare.newKeyPair();
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final salt = _randomBytes(16);

    final key = await SealedShare.deriveKey(
      sharedSecret: await SealedShare.sharedSecretFor(
        keyPair: ephemeral,
        remotePublicKey: recipientPublicKey,
      ),
      salt: salt,
      kid: kid,
      ephemeralPublicKey: ephemeralPublic,
    );

    yield utf8.encode('${jsonEncode(SealedHeader(
          kid: kid,
          ephemeralPublicKey: ephemeralPublic,
          salt: salt,
          mime: mime,
        ).toJson())}\n');

    var index = 0;
    final pending = _Buffer();
    await for (final data in plaintext) {
      pending.add(data);
      while (pending.length >= SealedShare.chunkSize) {
        yield await _frame(key, pending.take(SealedShare.chunkSize), index++,
            last: false);
      }
    }
    // Always a final chunk, even for an empty body, so the receiver has
    // something to verify the end against.
    yield await _frame(key, pending.take(pending.length), index, last: true);
  }

  static Future<List<int>> _frame(
      SecretKey key, List<int> plain, int index, {required bool last}) async {
    final box = await SealedShare.sealChunk(
        key: key, plaintext: plain, index: index, last: last);
    final body = <int>[...box.cipherText, ...box.mac.bytes];
    final out = Uint8List(4 + body.length);
    ByteData.view(out.buffer).setUint32(0, body.length, Endian.big);
    out.setRange(4, out.length, body);
    return out;
  }

  static List<int> _randomBytes(int n) =>
      SecretKeyData.random(length: n).bytes;
}

class SealedFormatException implements Exception {
  const SealedFormatException(this.message);
  final String message;
  @override
  String toString() => 'Sealed message malformed: $message';
}

class SealedAuthException implements Exception {
  const SealedAuthException(this.message);
  final String message;
  @override
  String toString() => 'Sealed message rejected: $message';
}

/// A byte queue that can hand back a header line or a length-prefixed frame
/// once enough has arrived.
class _Buffer {
  final _chunks = BytesBuilder(copy: false);
  Uint8List _bytes = Uint8List(0);

  void add(List<int> data) {
    _chunks.add(data);
    _flatten();
  }

  void _flatten() {
    if (_chunks.isEmpty) return;
    final more = _chunks.takeBytes();
    final joined = Uint8List(_bytes.length + more.length)
      ..setRange(0, _bytes.length, _bytes)
      ..setRange(_bytes.length, _bytes.length + more.length, more);
    _bytes = joined;
  }

  int get length => _bytes.length;

  List<int> take(int n) {
    final out = _bytes.sublist(0, n);
    _bytes = _bytes.sublist(n);
    return out;
  }

  String? takeLine() {
    final i = _bytes.indexOf(0x0a);
    if (i < 0) return null;
    final line = utf8.decode(_bytes.sublist(0, i));
    _bytes = _bytes.sublist(i + 1);
    return line;
  }

  _Frame? takeFrame() {
    if (_bytes.length < 4) return null;
    final size = ByteData.view(_bytes.buffer, _bytes.offsetInBytes)
        .getUint32(0, Endian.big);
    // A frame larger than a chunk plus its tag is not one this format
    // produces, and is the shape a memory-exhaustion attempt would take.
    if (size > SealedShare.chunkSize + 64) {
      throw SealedFormatException('chunk claims to be $size bytes');
    }
    if (_bytes.length < 4 + size) return null;
    final frame = _bytes.sublist(4, 4 + size);
    _bytes = _bytes.sublist(4 + size);
    return _Frame(frame);
  }
}

class _Frame {
  _Frame(this.bytes);
  final Uint8List bytes;
}
