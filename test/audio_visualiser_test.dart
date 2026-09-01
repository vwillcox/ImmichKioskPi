import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:immich_kiosk_pi/config/app_config.dart';
import 'package:immich_kiosk_pi/services/audio_levels_service.dart';
import 'package:immich_kiosk_pi/widgets/audio_visualiser.dart';

/// A service that opens cleanly and then says nothing, so the widget renders
/// as it would on the panel without a capture process anywhere near it.
AudioLevelsService quietService(StreamController<List<int>> pcm) =>
    AudioLevelsService(
      open: () async => PcmStream(bytes: pcm.stream, stop: () async {}),
    );

void main() {
  group('the style cycle', () {
    test('tapping runs bars, waveform, off and back round', () {
      expect(nextVisualiser(VisualiserStyle.bars), VisualiserStyle.wave);
      expect(nextVisualiser(VisualiserStyle.wave), VisualiserStyle.off);
      expect(nextVisualiser(VisualiserStyle.off), VisualiserStyle.bars);
    });

    test('every style is reachable by tapping, from any of them', () {
      for (final start in VisualiserStyle.values) {
        var style = start;
        final seen = <VisualiserStyle>{};
        for (var i = 0; i < VisualiserStyle.values.length; i++) {
          seen.add(style);
          style = nextVisualiser(style);
        }
        expect(seen, VisualiserStyle.values.toSet());
        expect(style, start, reason: 'the cycle must come back round');
      }
    });

    test('the chosen style survives being written out and read back', () {
      for (final style in VisualiserStyle.values) {
        final json = NowPlayingSettings(visualiser: style).toJson();
        expect(NowPlayingSettings.fromJson(json).visualiser, style);
      }
    });

    test('a config written before the visualiser existed still loads', () {
      final old = {'enabled': true, 'corner': 'bottomLeft'};
      expect(NowPlayingSettings.fromJson(old).visualiser, VisualiserStyle.bars);
    });
  });

  group('touching it', () {
    late StreamController<List<int>> pcm;
    late AudioLevelsService service;

    setUp(() {
      pcm = StreamController<List<int>>.broadcast();
      service = quietService(pcm);
    });

    tearDown(() async => pcm.close());

    Future<void> show(
      WidgetTester tester,
      VisualiserStyle style,
      VoidCallback? onTap,
    ) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AudioLevelsService>.value(
          value: service,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: AudioVisualiser(style: style, onTap: onTap),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a tap on the picture asks for the next style', (tester) async {
      var taps = 0;
      await show(tester, VisualiserStyle.bars, () => taps++);
      await tester.tap(find.byType(AudioVisualiser));
      expect(taps, 1);
    });

    testWidgets('the empty space above the bars counts as a tap',
        (tester) async {
      // Most of the band is empty most of the time. Having to land on a bar
      // would make it unusable.
      var taps = 0;
      await show(tester, VisualiserStyle.bars, () => taps++);
      final box = tester.getRect(find.byType(AudioVisualiser));
      await tester.tapAt(Offset(box.center.dx, box.top + 2));
      expect(taps, 1);
    });

    testWidgets('switched off it leaves something to switch back on',
        (tester) async {
      var taps = 0;
      await show(tester, VisualiserStyle.off, () => taps++);
      expect(tester.getRect(find.byType(AudioVisualiser)).height,
          greaterThan(0));
      await tester.tap(find.byType(AudioVisualiser));
      expect(taps, 1, reason: 'off must not be a one-way door');
    });

    testWidgets('with nothing to tap, off takes its space back',
        (tester) async {
      await show(tester, VisualiserStyle.off, null);
      expect(tester.getRect(find.byType(AudioVisualiser)).height, 0);
    });

    testWidgets('the off strip is shorter than the picture', (tester) async {
      await show(tester, VisualiserStyle.off, () {});
      final dormant = tester.getRect(find.byType(AudioVisualiser)).height;
      await show(tester, VisualiserStyle.bars, () {});
      final live = tester.getRect(find.byType(AudioVisualiser)).height;
      expect(dormant, lessThan(live));
    });
  });
}
