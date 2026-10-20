import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/profile_screen.dart';

import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  Future<void> pumpProfile(WidgetTester tester, Locale locale) async {
    setPhone(tester, width: 412);
    await tester.pumpWidget(
      harness.wrap(
        ProfileScreen(onClose: () {}, onLogout: () async {}, auth: Object()),
        locale: locale,
      ),
    );
    await settleReal(tester);
  }

  Finder sheetRow(int i) => find.byKey(ValueKey('sheet-action-$i'));

  for (final brightness in Brightness.values) {
    testWidgets(
      'all six accent choices remain usable and persisted at 320dp 2x in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await harness.open(tester);
        await tester.runAsync(() => harness.settings.setAccent(accents[1]));
        setPhone(tester, width: 320, textScale: 2);
        await tester.pumpWidget(
          harness.wrap(
            Theme(
              data: buildTheme(brightness, accents[1]),
              child: ProfileScreen(onClose: () {}),
            ),
          ),
        );
        await settleReal(tester);
        Finder swatch(int i) => find.byKey(ValueKey('profile-accent-${i + 1}'));
        await scrollIntoView(tester, find.byType(ProfileScreen), swatch(0));
        expect(
          harness.settings.accent,
          accents[1],
          reason: 'an explicit stored legacy accent is retained',
        );
        for (var i = 0; i < accents.length; i++) {
          await scrollIntoView(tester, find.byType(ProfileScreen), swatch(i));
          final bounds = tester.getRect(swatch(i));
          expect(bounds.width, greaterThanOrEqualTo(48));
          expect(bounds.height, greaterThanOrEqualTo(48));
          expect(bounds.left, greaterThanOrEqualTo(16));
          expect(bounds.right, lessThanOrEqualTo(304));
          await tester.tap(swatch(i));
          await settleReal(tester, ticks: 2);
          expect(harness.settings.accent, accents[i]);
          final selected = find
              .ancestor(of: swatch(i), matching: find.byType(Semantics))
              .first;
          expect(
            tester
                .getSemantics(selected)
                .getSemanticsData()
                .flagsCollection
                .isSelected,
            Tristate.isTrue,
          );
          final check = tester.widget<Icon>(
            find.descendant(of: swatch(i), matching: find.byIcon(WIcons.check)),
          );
          final a = check.color!.computeLuminance();
          final b = accents[i].computeLuminance();
          final contrast = a > b
              ? (a + 0.05) / (b + 0.05)
              : (b + 0.05) / (a + 0.05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: 'the selected mark remains readable for choice ${i + 1}',
          );
        }
        await tester.runAsync(() async {
          await harness.settings.flushPersistence();
          final reloaded = SettingsService.local(harness.database);
          await reloaded.load();
          expect(reloaded.accent, accents.last);
          reloaded.dispose();
        });
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await harness.unmount(tester);
      },
    );
  }

  testWidgets('the goal sheet checks the current goal after its label and '
      'keeps every target icon', (tester) async {
    final semantics = tester.ensureSemantics();
    await harness.open(tester, prefs: {'settings.bodyweight_goal': 'bulk'});
    await pumpProfile(tester, const Locale('en'));
    final goalRow = find.text('Goal');
    await scrollIntoView(tester, find.byType(ProfileScreen), goalRow);
    await tester.tap(goalRow);
    await settleUntilFound(tester, sheetRow(2), where: 'goal sheet');
    await settleReal(tester, ticks: 10);
    // Rows follow BodyweightGoal.values: cut, bulk, maintain.
    final check = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byIcon(WIcons.check),
    );
    expect(check, findsOneWidget);
    expect(find.descendant(of: sheetRow(1), matching: check), findsOneWidget);
    expect(
      tester.getRect(check).left,
      greaterThan(
        tester
            .getRect(
              find.descendant(of: sheetRow(1), matching: find.text('Bulk')),
            )
            .right,
      ),
      reason: 'the check should trail the label',
    );
    for (var i = 0; i < 3; i++) {
      expect(
        find.descendant(of: sheetRow(i), matching: find.byIcon(WIcons.target)),
        findsOneWidget,
        reason: 'row $i',
      );
      expect(
        tester
            .getSemantics(sheetRow(i))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        i == 1 ? Tristate.isTrue : Tristate.none,
        reason: 'row $i',
      );
    }
    semantics.dispose();
    await harness.unmount(tester);
  });

  // In English this passed before: the en ARB happened to hold endonyms.
  testWidgets('in an Italian UI the language sheet and row name German '
      '"Deutsch"', (tester) async {
    await harness.open(tester);
    await pumpProfile(tester, const Locale('it'));
    final languageRow = find.text('Lingua');
    await scrollIntoView(tester, find.byType(ProfileScreen), languageRow);
    expect(find.text('Predefinita di sistema'), findsOneWidget);
    await tester.tap(languageRow);
    await settleUntilFound(
      tester,
      find.text('Italiano'),
      where: 'language picker',
    );
    // Let the sheet finish sliding in, so the tap lands on its row.
    await settleReal(tester, ticks: 10);
    expect(find.text('Tedesco'), findsNothing);
    await tester.tap(find.text('Deutsch'));
    await settleReal(tester, ticks: 10);
    expect(harness.settings.localeOverride, 'de');
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      find.text('Deutsch'),
      findsOneWidget,
      reason: 'the Language row should name the choice in its own language',
    );
    expect(find.text('Tedesco'), findsNothing);

    // Reopened, the sheet checks the stored choice, not the system row.
    await tester.tap(languageRow);
    await settleUntilFound(tester, sheetRow(4), where: 'language picker again');
    await settleReal(tester, ticks: 10);
    final check = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byIcon(WIcons.check),
    );
    expect(check, findsOneWidget);
    expect(
      find.descendant(of: sheetRow(3), matching: check),
      findsOneWidget,
      reason: 'the Deutsch row should carry the check',
    );
    await harness.unmount(tester);
  });
}
