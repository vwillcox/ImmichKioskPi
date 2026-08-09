import 'package:flutter_test/flutter_test.dart';
import 'package:immich_kiosk_pi/services/spotify_service.dart';

void main() {
  group('PKCE code challenge', () {
    test('matches RFC 7636\'s own worked example', () {
      // https://www.rfc-editor.org/rfc/rfc7636#appendix-B — the standard's
      // own verifier/challenge pair, so this is checked against a fixed
      // external answer rather than just against its own algorithm.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expected = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
      expect(SpotifyService.codeChallengeFor(verifier), expected);
    });

    test('never contains base64 padding', () {
      // Spotify's /authorize rejects a code_challenge containing "=".
      final challenge = SpotifyService.codeChallengeFor('x' * 43);
      expect(challenge.contains('='), isFalse);
    });
  });

  group('repeat state', () {
    test('cycles off -> repeat all -> repeat one -> off', () {
      expect(SpotifyService.nextRepeatState('off'), 'context');
      expect(SpotifyService.nextRepeatState('alltracks'), 'track');
      expect(SpotifyService.nextRepeatState('singletrack'), 'off');
    });

    test('an unrecognised state is treated as off', () {
      expect(SpotifyService.nextRepeatState('bogus'), 'context');
    });

    test('repeatStateFrom is the inverse mapping', () {
      expect(SpotifyService.repeatStateFrom('off'), 'off');
      expect(SpotifyService.repeatStateFrom('context'), 'alltracks');
      expect(SpotifyService.repeatStateFrom('track'), 'singletrack');
    });

    test('round-trips through a full cycle', () {
      var state = 'off';
      final seen = <String>[];
      for (var i = 0; i < 3; i++) {
        state = SpotifyService.nextRepeatState(
            SpotifyService.repeatStateFrom(state));
        seen.add(state);
      }
      expect(seen, ['context', 'track', 'off']);
    });
  });
}
