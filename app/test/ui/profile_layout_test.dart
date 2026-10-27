import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:alkion/l10n/app_localizations.dart';

import '../support/layout_expect.dart';
import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  Future<void> pumpProfile(
    WidgetTester tester,
    String code, {
    Object? auth,
  }) async {
    await tester.pumpWidget(
      harness.wrap(
        ProfileScreen(
          onClose: () {},
          onLogout: () async {},
          auth: auth ?? Object(),
        ),
        locale: Locale(code),
      ),
    );
    await settleReal(tester);
  }

  // The quick stats ("KÖRPERGEWICHT", "82.4kg"), the theme chips and the
  // Data actions all need room at 2.0x.
  for (final (width, code) in [
    (320.0, 'en'),
    (320.0, 'de'),
    (320.0, 'es'),
    (320.0, 'it'),
    (412.0, 'de'),
  ]) {
    testWidgets('Profile holds at ${width.round()}dp 2.0x $code', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: width, textScale: 2.0);
      await pumpProfile(tester, code);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(ProfileScreen),
        'Profile ${width.round()}dp $code',
      );
      final l = AppLocalizations.of(tester.element(find.byType(ProfileScreen)));
      final data = find.byKey(const Key('profile-data-actions'));
      await scrollIntoView(tester, find.byType(ProfileScreen), data);
      for (final label in [l.alkionBackupRestore, l.exportHistory]) {
        final title = find.descendant(of: data, matching: find.text(label));
        expect(title, findsOneWidget);
        expectNoSplitWords(tester, within: title);
      }
      expect(
        find.descendant(of: data, matching: find.byType(InkWell)),
        findsNWidgets(2),
      );
      expect(find.textContaining('Reps'), findsNothing);
      expect(find.text(l.exportAllData), findsNothing);
      expect(find.text(l.profileGroupSync.toUpperCase()), findsNothing);
      expect(find.text(l.alkionAccountUnavailable), findsNothing);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    });
  }

  testWidgets(
    'rest controls retain full targets and exact typed values at 320dp 2x',
    (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: 2);
      await pumpProfile(tester, 'en');
      final value = find.text('180s');
      await scrollIntoView(tester, find.byType(ProfileScreen), value);
      final target = find
          .ancestor(of: value, matching: find.byType(GestureDetector))
          .first;
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      expect(
        tester.getRect(target).top,
        greaterThan(tester.getRect(find.text('Compound rest')).bottom),
      );
      await tester.tap(value);
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(tester.getSize(field).height, greaterThanOrEqualTo(48));
      await tester.enterText(field, '195');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleReal(tester, ticks: 3);
      expect(harness.settings.restCompoundSeconds, 195);
      expect(find.text('195s'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );

  testWidgets('the theme chips wrap in their slot and leave the title room', (
    tester,
  ) async {
    await harness.open(tester);
    setPhone(tester, width: 320, textScale: 2.0);
    await pumpProfile(tester, 'it');
    final title = find.text('Tema');
    await scrollIntoView(tester, find.byType(ProfileScreen), title);
    final p = tester.renderObject<RenderParagraph>(title);
    expect(
      p.size.width,
      greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) * 0.8),
      reason: 'the chips squeeze the title',
    );
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });
}
