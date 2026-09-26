import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:home_canvas/dashboard/widget_registry.dart';
import 'package:home_canvas/dashboard/widgets/widgets.dart';
import 'package:home_canvas/services/timer_service.dart';
import 'package:home_canvas/services/timer_sounds.dart';

Uint8List _mp3() => Uint8List.fromList([...'ID3'.codeUnits, ...List.filled(20, 0)]);

void main() {
  group('a finished timer', () {
    test('plays its sound, then says which timer it was', () async {
      var now = DateTime(2026, 9, 26, 12);
      final heard = <String>[];
      final ringing = Completer<void>();
      final s = TimerService(
        play: (sound) async {
          heard.add('sound:$sound');
          await ringing.future;
        },
        speak: (t) async => heard.add(t),
        clock: () => now,
      );
      s.start(const Duration(minutes: 7), label: 'Eggs', sound: 'bell');
      now = now.add(const Duration(minutes: 7));
      s.tick();
      // Not on top of the sound: the voice waits for it to end.
      expect(heard, ['sound:bell']);
      ringing.complete();
      await pumpEventQueue();
      expect(heard, ['sound:bell', 'The eggs timer is done.']);
      s.dispose();
    });

    test('with speech off, only the sound', () async {
      var now = DateTime(2026, 9, 26, 12);
      final heard = <String>[];
      final s = TimerService(
        play: (sound) async => heard.add('sound:$sound'),
        speak: (t) async => heard.add(t),
        clock: () => now,
      );
      s.start(const Duration(minutes: 1), sound: 'chime', speaks: false);
      now = now.add(const Duration(minutes: 1));
      s.tick();
      await pumpEventQueue();
      expect(heard, ['sound:chime']);
      s.dispose();
    });

    test('with no sound, speaks at once', () {
      var now = DateTime(2026, 9, 26, 12);
      final heard = <String>[];
      final s = TimerService(
        play: (sound) async => heard.add('sound:$sound'),
        speak: (t) async => heard.add(t),
        clock: () => now,
      );
      s.start(const Duration(minutes: 1), label: 'Tea');
      now = now.add(const Duration(minutes: 1));
      s.tick();
      expect(heard, ['The tea timer is done.']);
      s.dispose();
    });

    test('dismissed while ringing: the sound stops and nothing is said',
        () async {
      var now = DateTime(2026, 9, 26, 12);
      final heard = <String>[];
      final ringing = Completer<void>();
      var silenced = 0;
      final s = TimerService(
        play: (sound) => ringing.future,
        silence: () async {
          silenced++;
          ringing.complete();
        },
        speak: (t) async => heard.add(t),
        clock: () => now,
      );
      final t = s.start(const Duration(minutes: 1), sound: 'alarm');
      now = now.add(const Duration(minutes: 1));
      s.tick();
      s.remove(t.id);
      await pumpEventQueue();
      expect(silenced, 1);
      expect(heard, isEmpty);
      s.dispose();
    });
  });

  group('uploaded sounds', () {
    late Directory dir;
    late TimerSounds sounds;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('sounds');
      sounds = TimerSounds(uploadDir: '${dir.path}/up', cacheDir: dir.path);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('names are kept to a plain file name with a sound\'s extension', () {
      expect(TimerSounds.safeName('Ding Dong.mp3'), 'Ding Dong.mp3');
      expect(TimerSounds.safeName('../../etc/passwd.mp3'), 'passwd.mp3');
      expect(TimerSounds.safeName(r'C:\Music\cuckoo.MP3'), 'cuckoo.mp3');
      expect(TimerSounds.safeName('bell (1)!.wav'), 'bell 1.wav');
      expect(TimerSounds.safeName('.hidden.mp3'), isNull);
      expect(TimerSounds.safeName('notes.txt'), isNull);
      expect(TimerSounds.safeName('.mp3'), isNull);
    });

    test('are listed after the built-ins, and can be deleted', () async {
      final id = await sounds.save('Cuckoo.mp3', _mp3());
      expect(id, 'custom:Cuckoo.mp3');
      final choices = await sounds.choices();
      expect(choices.keys.first, 'none');
      expect(choices.keys.last, 'custom:Cuckoo.mp3');
      expect(choices.keys, containsAll(TimerSounds.builtIn.keys));
      expect(await sounds.path(id), '${dir.path}/up/Cuckoo.mp3');

      expect(await sounds.delete('chime'), isFalse);
      expect(await sounds.delete(id), isTrue);
      expect((await sounds.choices()).containsKey(id), isFalse);
    });

    test('must look like audio, and not be too big', () async {
      await expectLater(
        sounds.save('fake.mp3', Uint8List.fromList(List.filled(40, 65))),
        throwsFormatException,
      );
      await expectLater(
        sounds.save('big.mp3', Uint8List(TimerSounds.maxUploadBytes + 1)
          ..setAll(0, 'ID3'.codeUnits)),
        throwsFormatException,
      );
      expect(await sounds.uploads(), isEmpty);
    });

    test('an id is never read as a path', () async {
      expect(await sounds.path('custom:../../secret.mp3'), isNull);
      expect(await sounds.delete('custom:../x.mp3'), isFalse);
      expect(await sounds.path('nonsense'), isNull);
    });
  });

  test('the timers tile offers the sounds, with the chime by default', () {
    registerBuiltInWidgets();
    final options = WidgetRegistry.find('timers')!.options;
    final sound = options.firstWhere((o) => o.key == 'sound');
    expect(sound.kind, OptionKind.choice);
    expect(sound.defaultValue, 'chime');
    expect(sound.choicesFrom, 'timerSounds');
    expect(sound.choices.keys, contains('none'));
    expect(options.firstWhere((o) => o.key == 'speak').defaultValue, isTrue);
  });
}
