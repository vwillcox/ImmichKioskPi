import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/sealed_share.dart';
import 'package:immich_kiosk_pi/services/sealed_stream.dart';

Stream<List<int>> one(List<int> bytes) => Stream.value(bytes);

/// Delivered in awkward pieces, the way a socket actually delivers them.
Stream<List<int>> dribble(List<int> bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, min(i + size, bytes.length));
  }
}

Future<List<int>> collect(Stream<List<int>> s) async {
  final out = <int>[];
  await for (final c in s) {
    out.addAll(c);
  }
  return out;
}

void main() {
  late SimpleKeyPair panel;
  late List<int> panelPublic;
  const kid = 'abcdef0123456789';

  setUp(() async {
    panel = await SealedShare.newKeyPair();
    panelPublic = (await panel.extractPublicKey()).bytes;
  });

  SealedReader readerFor(SimpleKeyPair pair, {String accept = kid}) =>
      SealedReader(keyFor: (k) async => k == accept ? pair : null);

  Future<List<int>> sealed(List<int> plaintext, {String mime = 'text/plain'}) =>
      collect(SealedWriter(recipientPublicKey: panelPublic, kid: kid)
          .seal(one(plaintext), mime: mime));

  group('round trip', () {
    test('a short message comes back exactly', () async {
      final msg = utf8.encode('Meet me by the bins at four');
      final out = await collect(readerFor(panel).open(one(await sealed(msg))));
      expect(utf8.decode(out), 'Meet me by the bins at four');
    });

    test('an empty body is still sealed and still verifies', () async {
      final out = await collect(readerFor(panel).open(one(await sealed([]))));
      expect(out, isEmpty);
    });

    test('a payload spanning many chunks survives intact', () async {
      final rnd = Random(7);
      final big = Uint8List.fromList(
          List.generate(SealedShare.chunkSize * 3 + 1234, (_) => rnd.nextInt(256)));
      final out = await collect(readerFor(panel).open(one(await sealed(big))));
      expect(out.length, big.length);
      expect(out, equals(big));
    });

    test('arriving in small irregular pieces makes no difference', () async {
      final msg = utf8.encode('x' * 5000);
      final wire = await sealed(msg);
      final out = await collect(readerFor(panel).open(dribble(wire, 97)));
      expect(out.length, msg.length);
    });

    test('the content type travels inside the sealed part', () async {
      SealedHeader? seen;
      await collect(readerFor(panel).open(
        one(await sealed(utf8.encode('hi'), mime: 'video/mp4')),
        onHeader: (h) => seen = h,
      ));
      expect(seen!.mime, 'video/mp4');
    });
  });

  group('an eavesdropper or tamperer gets nothing', () {
    test('a different panel key cannot open it', () async {
      final other = await SealedShare.newKeyPair();
      final wire = await sealed(utf8.encode('secret'));
      expect(
        () => collect(readerFor(other).open(one(wire))),
        throwsA(isA<SealedAuthException>()),
      );
    });

    test('flipping a byte of ciphertext is detected', () async {
      final wire = await sealed(utf8.encode('the quick brown fox'));
      wire[wire.length - 20] ^= 0x01;
      expect(
        () => collect(readerFor(panel).open(one(wire))),
        throwsA(isA<SealedAuthException>()),
      );
    });

    test('truncating the stream is detected, not silently accepted', () async {
      final big = Uint8List(SealedShare.chunkSize * 2);
      final wire = await sealed(big);
      // Drop the final chunk: a naive reader would hand back what it had.
      final cut = wire.sublist(0, wire.length - 40);
      expect(
        () => collect(readerFor(panel).open(one(cut))),
        throwsA(isA<SealedAuthException>()),
      );
    });

    test('a message sealed to a retired key is refused', () async {
      final wire = await sealed(utf8.encode('old'));
      final reader = readerFor(panel, accept: 'some-other-kid');
      expect(() => collect(reader.open(one(wire))),
          throwsA(isA<SealedAuthException>()));
    });

    test('a header claiming an enormous chunk is refused, not allocated',
        () async {
      final header = utf8.encode('${jsonEncode({
            'v': 1,
            'kid': kid,
            'epk': base64Encode(List.filled(32, 1)),
            'salt': base64Encode(List.filled(16, 2)),
            'mime': 'text/plain',
          })}\n');
      final frame = Uint8List(4);
      ByteData.view(frame.buffer).setUint32(0, 0x7fffffff);
      expect(
        () => collect(readerFor(panel).open(one([...header, ...frame]))),
        throwsA(isA<SealedFormatException>()),
      );
    });

    test('rubbish in place of a header is refused', () async {
      expect(
        () => collect(readerFor(panel).open(one(utf8.encode('not json\n')))),
        throwsA(isA<SealedFormatException>()),
      );
    });
  });

  group('keys', () {
    test('every message uses a different ephemeral key', () async {
      final a = await sealed(utf8.encode('same text'));
      final b = await sealed(utf8.encode('same text'));
      final headerA = jsonDecode(utf8.decode(a.sublist(0, a.indexOf(10))));
      final headerB = jsonDecode(utf8.decode(b.sublist(0, b.indexOf(10))));
      expect(headerA['epk'], isNot(headerB['epk']),
          reason: 'a reused ephemeral key would cost forward secrecy');
    });

    test('identical plaintext seals to different bytes each time', () async {
      final a = await sealed(utf8.encode('same text'));
      final b = await sealed(utf8.encode('same text'));
      expect(a, isNot(equals(b)));
    });
  });
}
