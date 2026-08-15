import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// Seals a share so only the kiosk can read it.
///
/// The mirror of `lib/services/sealed_share.dart` in the kiosk. Kept as a
/// separate small file rather than a shared package because the two apps are
/// built separately; if either side changes, both must, and the version in
/// the header is what makes a mismatch fail loudly rather than quietly.
///
/// A fresh key pair is generated for every message. The private half never
/// leaves this object and is dropped when the send finishes, so a message
/// captured today cannot be read even by someone who later takes the kiosk's
/// own key. That is the point of doing this rather than trusting TLS: the
/// share passes through a reverse proxy that terminates TLS and can read
/// anything that is merely in transit.
class SealedSender {
  SealedSender({required this.address, required this.token});

  final String address;
  final String token;

  static const int version = 1;
  static const int chunkSize = 64 * 1024;
  static const String sealedMime = 'application/vnd.kiosk.sealed';
  static const String _info = 'immich-kiosk-pi/share/v1';

  static final _x25519 = X25519();
  static final _aead = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  _Recipient? _cached;

  /// The kiosk's current public key.
  ///
  /// Re-fetched whenever it might have rotated, which is what makes rotation
  /// invisible: the panel changes its key on a schedule and senders simply
  /// pick up the new one before their next message.
  Future<_Recipient> _recipient({bool force = false}) async {
    final cached = _cached;
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < const Duration(hours: 1)) {
      return cached;
    }
    final resp = await http.get(
      Uri.parse('$address/pubkey'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) {
      throw SealedSendException(
          'The kiosk would not hand out its key (HTTP ${resp.statusCode}).');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    if (j['v'] != version) {
      throw SealedSendException(
          'The kiosk speaks encryption version ${j['v']}; this app speaks '
          '$version. Update whichever is older.');
    }
    final r = _Recipient(
      kid: '${j['kid']}',
      publicKey: base64Decode('${j['key']}'),
      fetchedAt: DateTime.now(),
    );
    _cached = r;
    return r;
  }

  /// Sends [body] sealed, with [mime] carried inside so the network cannot
  /// see whether this was a note or a video.
  Future<http.Response> send(List<int> body, String mime) async {
    var recipient = await _recipient();
    var resp = await _post(recipient, body, mime);

    // A key that rotated between the fetch and the send is the one failure
    // worth retrying: fetch the new one and try once more, rather than
    // showing the user an error for something that fixes itself.
    if (resp.statusCode == 401) {
      recipient = await _recipient(force: true);
      resp = await _post(recipient, body, mime);
    }
    return resp;
  }

  Future<http.Response> _post(
      _Recipient recipient, List<int> body, String mime) async {
    final wire = await _seal(recipient, body, mime);
    return http.post(
      Uri.parse('$address/share'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': sealedMime,
      },
      body: wire,
    );
  }

  Future<Uint8List> _seal(
      _Recipient recipient, List<int> body, String mime) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final salt = SecretKeyData.random(length: 16).bytes;

    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey:
          SimplePublicKey(recipient.publicKey, type: KeyPairType.x25519),
    );
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(await shared.extractBytes()),
      nonce: salt,
      info: utf8.encode(
          '$_info|${recipient.kid}|${base64Encode(ephemeralPublic)}'),
    );

    final out = BytesBuilder();
    out.add(utf8.encode('${jsonEncode({
          'v': version,
          'kid': recipient.kid,
          'epk': base64Encode(ephemeralPublic),
          'salt': base64Encode(salt),
          'mime': mime,
        })}\n'));

    for (var offset = 0, index = 0;; index++) {
      final end = (offset + chunkSize) < body.length
          ? offset + chunkSize
          : body.length;
      final slice = body.sublist(offset, end);
      final last = end >= body.length;
      final box = await _aead.encrypt(
        slice,
        secretKey: key,
        nonce: _nonce(index),
        aad: utf8.encode('$index:${last ? 1 : 0}'),
      );
      final frame = <int>[...box.cipherText, ...box.mac.bytes];
      final header = Uint8List(4);
      ByteData.view(header.buffer).setUint32(0, frame.length, Endian.big);
      out
        ..add(header)
        ..add(frame);
      offset = end;
      if (last) break;
    }
    return out.takeBytes();
  }

  static Uint8List _nonce(int index) {
    final n = Uint8List(12);
    ByteData.view(n.buffer).setUint64(4, index, Endian.big);
    return n;
  }
}

class _Recipient {
  _Recipient({
    required this.kid,
    required this.publicKey,
    required this.fetchedAt,
  });
  final String kid;
  final List<int> publicKey;
  final DateTime fetchedAt;
}

class SealedSendException implements Exception {
  SealedSendException(this.message);
  final String message;
  @override
  String toString() => message;
}
