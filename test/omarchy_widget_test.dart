import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:immich_kiosk_pi/dashboard/dashboard_model.dart';
import 'package:immich_kiosk_pi/dashboard/dashboard_theme.dart';
import 'package:immich_kiosk_pi/dashboard/widget_registry.dart';
import 'package:immich_kiosk_pi/dashboard/widgets/omarchy_hotkeys.dart';
import 'package:immich_kiosk_pi/dashboard/widgets/omarchy_widget.dart';

/// The panel's own dashboard area, near enough: 1920x1200 less the chrome.
const Size panel = Size(1900, 1050);

/// Put the sheet on a surface the size of the real tile.
///
/// The default 800x600 test window is not a detail here: how many columns
/// there are, how many pages a section takes and which tabs get built are all
/// decided by the box, so testing this widget at the wrong size would be
/// testing a different widget.
Future<void> pumpSheet(
  WidgetTester tester, {
  Map<String, dynamic> options = const {},
  Size size = panel,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0B0F1A),
        body: DashboardOmarchyWidget(
          w: DashboardWidgetContext(
            theme: kBuiltInThemes.first,
            config: DashboardWidgetConfig(
              id: 'test',
              type: 'omarchy',
              x: 0,
              y: 0,
              width: 12,
              height: 8,
              options: Map<String, dynamic>.from(options),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the hotkeys themselves', () {
    test('every section has a name and some keys in it', () {
      expect(omarchyHotkeys, isNotEmpty);
      for (final s in omarchyHotkeys) {
        expect(s.title.trim(), isNotEmpty);
        expect(s.keys, isNotEmpty, reason: '${s.title} is empty');
        for (final k in s.keys) {
          expect(k.keys.trim(), isNotEmpty, reason: 'blank keys in ${s.title}');
          expect(k.action.trim(), isNotEmpty,
              reason: 'blank action for ${k.keys}');
        }
      }
    });

    test('section names are unique, since they are the tab labels', () {
      final titles = omarchyHotkeys.map((s) => s.title).toList();
      expect(titles.toSet().length, titles.length);
    });

    test('the whole manual is here', () {
      // A guard on the transcription: if a section is dropped in an edit, the
      // count moves and this says so rather than the panel quietly losing a
      // page of shortcuts.
      final total =
          omarchyHotkeys.fold<int>(0, (n, s) => n + s.keys.length);
      expect(omarchyHotkeys.length, 20);
      expect(total, 224);
    });
  });

  group('reading the notation', () {
    test('a plain combination is one run of caps', () {
      expect(omarchyCaps('Super + Ctrl + L'), [
        ['Super', 'Ctrl', 'L']
      ]);
    });

    test('"or" separates two ways of doing the same thing', () {
      expect(omarchyCaps('Super + W or Super + Q'), [
        ['Super', 'W'],
        ['Super', 'Q']
      ]);
    });

    test("the manual's own shorthand is left alone", () {
      // Splitting these further would invent notation the reader has never
      // seen on the page they are memorising.
      expect(omarchyCaps('Super + 1/2/3/4'), [
        ['Super', '1/2/3/4']
      ]);
      expect(omarchyCaps('CapsLock M S'), [
        ['CapsLock M S']
      ]);
      expect(omarchyCaps('Print Screen'), [
        ['Print Screen']
      ]);
    });

    test('every shortcut in the manual splits into something drawable', () {
      for (final s in omarchyHotkeys) {
        for (final k in s.keys) {
          for (final alternative in omarchyCaps(k.keys)) {
            expect(alternative, isNotEmpty);
            for (final cap in alternative) {
              expect(cap.trim(), isNotEmpty, reason: 'empty cap in ${k.keys}');
            }
          }
        }
      }
    });
  });

  group('fitting a page', () {
    test('a full page of the panel reads in columns, not one long list', () {
      final fit = omarchySheetFit(
        width: 1900,
        height: 950,
        minColumnWidth: 560,
        rowHeight: 66,
        count: 51,
      );
      expect(fit.columns, 3);
      expect(fit.rows, 14);
      expect(fit.pages, 2);
    });

    test('a narrow tile drops to one column rather than truncating', () {
      final fit = omarchySheetFit(
        width: 400,
        height: 950,
        minColumnWidth: 560,
        rowHeight: 66,
        count: 51,
      );
      expect(fit.columns, 1);
    });

    test('a tile too small for a single row still asks for one', () {
      final fit = omarchySheetFit(
        width: 100,
        height: 20,
        minColumnWidth: 560,
        rowHeight: 66,
        count: 51,
      );
      expect(fit.columns, 1);
      expect(fit.rows, 1);
      expect(fit.pages, 51);
    });

    test('bigger text means more pages, not lost shortcuts', () {
      int pagesAt(double rowHeight, double minColumn) => omarchySheetFit(
            width: 1900,
            height: 950,
            minColumnWidth: minColumn,
            rowHeight: rowHeight,
            count: 51,
          ).pages;
      expect(pagesAt(66, 560), greaterThan(pagesAt(42, 380)));
    });

    test('an empty section is one page, not none', () {
      final fit = omarchySheetFit(
        width: 1900,
        height: 950,
        minColumnWidth: 560,
        rowHeight: 66,
        count: 0,
      );
      expect(fit.pages, 1);
    });
  });

  group('on the panel', () {
    testWidgets('it opens on the first section', (tester) async {
      await pumpSheet(tester);
      expect(find.text('Navigating'), findsWidgets);
      expect(
          find.text('Omarchy menu (apps and everything else)'), findsOneWidget);
    });

    testWidgets('a combination is drawn as separate caps', (tester) async {
      await pumpSheet(tester);
      // Three caps and two joiners, not one long string.
      expect(find.text('Ctrl'), findsWidgets);
      expect(find.text('+'), findsWidgets);
      expect(find.text('or'), findsWidgets,
          reason: 'Super + W or Super + Q is on the first page');
    });

    testWidgets('tapping the sheet turns the page', (tester) async {
      await pumpSheet(tester);
      final first = find.text('Omarchy menu (apps and everything else)');
      expect(first, findsOneWidget);
      await tester.tap(find.byType(DashboardOmarchyWidget));
      await tester.pumpAndSettle();
      expect(first, findsNothing, reason: 'page one should be behind us');
    });

    testWidgets('turning past the last page moves to the next section',
        (tester) async {
      await pumpSheet(tester);
      // Navigating runs to a second page on a tile this size; one more turn
      // has to leave the section rather than sticking on the last page.
      await tester.tap(find.byType(DashboardOmarchyWidget));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DashboardOmarchyWidget));
      await tester.pumpAndSettle();
      expect(find.text('Audio panel'), findsOneWidget);
    });

    testWidgets('tapping a tab jumps straight to that section',
        (tester) async {
      await pumpSheet(tester);
      await tester.tap(find.text('Universal clipboard'));
      await tester.pumpAndSettle();
      expect(find.text('Clipboard manager'), findsOneWidget);
    });

    testWidgets('the strip brings the selected section into view',
        (tester) async {
      await pumpSheet(tester);
      // Walk far enough that the tab started off the right-hand side. A
      // highlight you cannot see is no use.
      for (var i = 0; i < 9; i++) {
        await tester.tap(find.byType(DashboardOmarchyWidget));
        await tester.pumpAndSettle();
      }
      expect(find.text('Toggle locking on idle'), findsOneWidget,
          reason: 'nine turns should land on Toggles');
      final strip = tester.getRect(find.byType(Scrollable).first);
      // The name is on screen twice — as the heading and as its tab. It is
      // the tab whose position matters here.
      final tab = tester.getRect(find.descendant(
        of: find.byType(Scrollable).first,
        matching: find.text('Toggles'),
      ));
      expect(tab.left, greaterThanOrEqualTo(strip.left - 1));
      expect(tab.right, lessThanOrEqualTo(strip.right + 1));
    });

    testWidgets('pinned to one section, the tabs go away', (tester) async {
      await pumpSheet(tester, options: {'section': 'Universal clipboard'});
      expect(find.text('Clipboard manager'), findsOneWidget);
      expect(find.text('Navigating'), findsNothing);
    });

    testWidgets('a section renamed out of a saved config does not go blank',
        (tester) async {
      await pumpSheet(tester, options: {'section': 'Gone Away'});
      expect(
          find.text('Omarchy menu (apps and everything else)'), findsOneWidget);
    });

    testWidgets('smaller text fits more on a page', (tester) async {
      await pumpSheet(tester, options: {'textSize': 'small'});
      // Large runs Navigating to two pages; small has to do better than that.
      expect(find.text('Cycle focus backwards through monitors'),
          findsOneWidget);
    });

    testWidgets('a small tile shows fewer shortcuts rather than overflowing',
        (tester) async {
      await pumpSheet(tester, size: const Size(420, 300));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tile too small for the page dots uses a counter instead',
        (tester) async {
      await pumpSheet(tester, size: const Size(420, 300));
      // Navigating in a box this size is well past what dots can say.
      expect(find.textContaining(RegExp(r'^1 / \d+$')), findsOneWidget);
    });
  });
}
