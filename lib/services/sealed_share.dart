import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as legacy show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// End-to-end encryption for shared content.
///
/// The transport is already TLS, but that only protects the wire. Shares
/// reaching this kiosk from outside pass through nginx, which terminates TLS
/// and therefore sees every message in the clear; so does anything else in
/// the path. This seals the payload so only the phone that sent it and the
/// panel that receives it can read it, whatever it travels through.
///
/// ## What it does
///
/// The panel holds a long-lived X25519 identity key and publishes the public
/// half. To send, a phone generates a *fresh* key pair for that one message,
/// does X25519 against the panel's public key, and derives a one-message
/// symmetric key with HKDF-SHA256. The body is then encrypted with
/// ChaCha20-Poly1305 in 64 KiB chunks so a video streams to disk rather than
/// being held in memory on a Pi.
///
/// A new key for every single message is the strongest form of the "rotate
/// often" the design asks for: there is no long-lived message key to capture,
/// and recovering the panel's identity key later does not decrypt anything
/// sent before, because the ephemeral halves were thrown away. That is
/// forward secrecy, and it is worth more than any rotation schedule. The
/// identity key is rotated as well — see [ShareKeys] — which bounds the
/// window in which a stolen private key lets anyone impersonate the panel.
///
/// ## What it does not do
///
/// It does not prove *who* sent a message. Anyone holding the panel's public
/// key can seal one; authorship still rests on the bearer token, exactly as
/// before. Sender authentication would need each phone to carry an identity
/// key of its own and sign, which is a larger change.
///
/// It also cannot protect content from anyone with a shell on the Pi: the
/// identity key is stored on disk, readable by the account the kiosk runs as.
/// The threat this addresses is the path in between, not the endpoints.
class SealedShare {
  SealedShare._();

  static const int version = 1;

  /// 64 KiB of plaintext per chunk. Large enough that the per-chunk overhead
  /// (16-byte tag, 4-byte length) is negligible, small enough that a chunk
  /// buffer is nothing on a Pi.
  static const int chunkSize = 64 * 1024;

  static const int _tagBytes = 16;
  static const String _info = 'immich-kiosk-pi/share/v1';

  static final _x25519 = X25519();
  static final _aead = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Derives the one-message key both sides arrive at independently.
  ///
  /// The ephemeral public key and the recipient's key id go into the HKDF
  /// info, binding the derived key to this exact exchange: a chunk resealed
  /// under a different header will not decrypt.
  static Future<SecretKey> deriveKey({
    required List<int> sharedSecret,
    required List<int> salt,
    required String kid,
    required List<int> ephemeralPublicKey,
  }) {
    return _hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: salt,
      info: utf8.encode('$_info|$kid|${base64Encode(ephemeralPublicKey)}'),
    );
  }

  /// Nonce for chunk [index]: four zero bytes then a 64-bit counter.
  ///
  /// Safe only because the key is used for exactly one message — with a
  /// reused key a counter starting at zero would repeat nonces, which
  /// ChaCha20-Poly1305 does not survive.
  static Uint8List nonceFor(int index) {
    final n = Uint8List(12);
    final b = ByteData.view(n.buffer);
    b.setUint64(4, index, Endian.big);
    return n;
  }

  /// Additional data bound into every chunk.
  ///
  /// Carrying the index stops chunks being reordered, dropped or repeated;
  /// carrying the final flag stops a message being truncated, since the
  /// receiver refuses a stream that ended without a chunk marked final.
  static List<int> aadFor(int index, {required bool last}) =>
      utf8.encode('$index:${last ? 1 : 0}');

  static Future<SecretBox> sealChunk({
    required SecretKey key,
    required List<int> plaintext,
    required int index,
    required bool last,
  }) {
    return _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonceFor(index),
      aad: aadFor(index, last: last),
    );
  }

  static Future<List<int>> openChunk({
    required SecretKey key,
    required List<int> frame,
    required int index,
    required bool last,
  }) {
    if (frame.length < _tagBytes) {
      throw const FormatException('chunk shorter than its authentication tag');
    }
    final box = SecretBox(
      frame.sublist(0, frame.length - _tagBytes),
      nonce: nonceFor(index),
      mac: Mac(frame.sublist(frame.length - _tagBytes)),
    );
    return _aead.decrypt(
      box,
      secretKey: key,
      aad: aadFor(index, last: last),
    );
  }

  static Future<List<int>> sharedSecretFor({
    required SimpleKeyPair keyPair,
    required List<int> remotePublicKey,
  }) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey:
          SimplePublicKey(remotePublicKey, type: KeyPairType.x25519),
    );
    return secret.extractBytes();
  }

  static Future<SimpleKeyPair> newKeyPair() => _x25519.newKeyPair();
}

/// The header that precedes the sealed chunks: one line of JSON, then a
/// newline, then the frames.
class SealedHeader {
  const SealedHeader({
    required this.kid,
    required this.ephemeralPublicKey,
    required this.salt,
    required this.mime,
  });

  /// Which of the panel's identity keys this was sealed to. Present so a
  /// message sent moments before a rotation still opens.
  final String kid;
  final List<int> ephemeralPublicKey;
  final List<int> salt;

  /// The content type of the plaintext, which the transport can no longer
  /// see. Everything is `application/octet-stream` on the wire now.
  final String mime;

  Map<String, dynamic> toJson() => {
        'v': SealedShare.version,
        'kid': kid,
        'epk': base64Encode(ephemeralPublicKey),
        'salt': base64Encode(salt),
        'mime': mime,
      };

  static SealedHeader parse(String line) {
    final j = jsonDecode(line);
    if (j is! Map<String, dynamic>) {
      throw const FormatException('header is not an object');
    }
    if (j['v'] != SealedShare.version) {
      throw FormatException('unsupported sealed version ${j['v']}');
    }
    final header = SealedHeader(
      kid: '${j['kid'] ?? ''}',
      ephemeralPublicKey: base64Decode('${j['epk'] ?? ''}'),
      salt: base64Decode('${j['salt'] ?? ''}'),
      mime: '${j['mime'] ?? 'application/octet-stream'}',
    );
    if (header.kid.isEmpty ||
        header.ephemeralPublicKey.length != 32 ||
        header.salt.length < 16) {
      throw const FormatException('header is missing or malformed');
    }
    return header;
  }
}

/// The panel's identity keys, and their rotation.
///
/// Two are kept: the one currently published, and the one before it. A phone
/// that fetched the public key a moment before a rotation would otherwise
/// have its message rejected; keeping the previous key for one further period
/// closes that race without keeping old keys around indefinitely.
class ShareKeys {
  ShareKeys({String? directory, this.rotateEvery = const Duration(days: 7)})
      : _directory = directory ??
            p.join(Platform.environment['HOME'] ?? '.', '.config',
                'immich_kiosk_pi');

  final String _directory;

  /// How often the identity key is replaced. Frequent rotation limits how
  /// long a stolen private key is useful for; it does *not* protect past
  /// messages, which are already covered by the per-message ephemeral keys.
  final Duration rotateEvery;

  File get _file => File(p.join(_directory, 'share_keys.json'));

  _Identity? _current;
  _Identity? _previous;

  String get currentKeyId => _current?.kid ?? '';
  DateTime? get rotatedAt => _current?.createdAt;

  /// The public half, for a phone to seal against.
  Future<List<int>> currentPublicKey() async {
    final key = _current;
    if (key == null) throw StateError('no identity key');
    return (await key.keyPair.extractPublicKey()).bytes;
  }

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        if (j is Map<String, dynamic>) {
          _current = _Identity.fromJson(j['current']);
          _previous = _Identity.fromJson(j['previous']);
        }
      }
    } catch (e) {
      debugPrint('ShareKeys: could not read keys, starting fresh: $e');
    }
    if (_current == null) {
      await rotate();
    } else {
      await maybeRotate();
    }
  }

  /// Rotates when the current key has served its period. Cheap enough to call
  /// on every request.
  Future<void> maybeRotate() async {
    final key = _current;
    if (key == null || DateTime.now().difference(key.createdAt) >= rotateEvery) {
      await rotate();
    }
  }

  Future<void> rotate() async {
    final pair = await SealedShare.newKeyPair();
    final pub = await pair.extractPublicKey();
    _previous = _current;
    _current = _Identity(
      kid: _keyId(pub.bytes),
      keyPair: pair,
      createdAt: DateTime.now(),
    );
    await _save();
    debugPrint('ShareKeys: rotated to ${_current!.kid}');
  }

  /// The key pair a message named, or null if it named one we no longer hold
  /// — which is what an attacker replaying an old capture would look like.
  Future<SimpleKeyPair?> keyPairFor(String kid) async {
    if (_current?.kid == kid) return _current!.keyPair;
    if (_previous?.kid == kid) return _previous!.keyPair;
    return null;
  }

  /// First eight bytes of SHA-256 over the public key, as hex. Short enough
  /// to sit in a header, long enough not to collide by accident.
  static String _keyId(List<int> publicKey) {
    final digest = legacy.sha256.convert(publicKey).bytes.take(8);
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _save() async {
    final dir = Directory(_directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = _file;
    await file.writeAsString(jsonEncode({
      'current': await _current?.toJson(),
      'previous': await _previous?.toJson(),
    }));
    // Private keys: readable by this account and nobody else. Best effort —
    // it is a plain file on a Pi, and anyone with a shell here can read it.
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
  }
}

class _Identity {
  _Identity({required this.kid, required this.keyPair, required this.createdAt});

  final String kid;
  final SimpleKeyPair keyPair;
  final DateTime createdAt;

  static _Identity? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      final seed = base64Decode('${j['seed']}');
      final pub = base64Decode('${j['pub']}');
      return _Identity(
        kid: '${j['kid']}',
        keyPair: SimpleKeyPairData(
          seed,
          publicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        ),
        createdAt:
            DateTime.tryParse('${j['created']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> toJson() async => {
        'kid': kid,
        'seed': base64Encode(await keyPair.extractPrivateKeyBytes()),
        'pub': base64Encode((await keyPair.extractPublicKey()).bytes),
        'created': createdAt.toIso8601String(),
      };
}
