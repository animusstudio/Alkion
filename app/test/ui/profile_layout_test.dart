import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/profile_screen.dart';

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
  // local-profile status all outgrew their slots at 2.0x.
  for (final (width, code) in [(320.0, 'de'), (320.0, 'it'), (412.0, 'de')]) {
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
      await harness.unmount(tester);
    });
  }

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

  testWidgets('the local profile status fits its row at 320dp 2.0x de', (
    tester,
  ) async {
    await harness.open(tester, prefs: syncOnPrefs);
    setPhone(tester, width: 320, textScale: 2.0);
    final auth = await signedInAuth(tester);
    await pumpProfile(tester, 'de', auth: auth);
    final status = find.text('Lokales Profil');
    await scrollIntoView(tester, find.byType(ProfileScreen), status);
    expect(tester.takeException(), isNull);
    expectNoSplitWords(tester, within: status);
    final row = tester.getRect(find.byType(ProfileScreen));
    expect(tester.getRect(status).right, lessThanOrEqualTo(row.right));
    await harness.unmount(tester);
  });

  // The account-unavailable explanation sits below its local-profile title
  // and remains readable at large text.
  for (final width in [320.0, 412.0]) {
    for (final (code, title, label) in [
      ('de', 'Lokales Profil', 'Konten sind hier noch nicht verfügbar.'),
      (
        'it',
        'Profilo locale',
        'La connessione a un account non è disponibile in questa versione di sviluppo.',
      ),
    ]) {
      testWidgets('the account-unavailable explanation stays whole at '
          '${width.round()}dp 2.0x $code', (tester) async {
        await harness.open(
          tester,
          prefs: syncOnPrefs,
          lastSyncedAt: DateTime.now().subtract(
            const Duration(hours: 3, minutes: 5),
          ),
        );
        setPhone(tester, width: width, textScale: 2.0);
        await pumpProfile(tester, code, auth: await signedInAuth(tester));
        final status = find.text(label);
        await scrollIntoView(tester, find.byType(ProfileScreen), status);
        expect(tester.takeException(), isNull);
        final p = tester.renderObject<RenderParagraph>(status);
        expect(p.didExceedMaxLines, isFalse, reason: '"$label" is cut short');
        expectNoSplitWords(tester, within: status);
        expect(
          tester.getRect(status).top,
          greaterThanOrEqualTo(tester.getRect(find.text(title)).bottom),
          reason: 'the status should sit under the title',
        );
        expect(
          tester.getRect(status).right,
          lessThanOrEqualTo(tester.getRect(find.byType(ProfileScreen)).right),
        );
        await harness.unmount(tester);
      });
    }
  }

  testWidgets(
    'the unavailable explanation stays below its title at 412dp 1.0x en',
    (tester) async {
      await harness.open(
        tester,
        prefs: syncOnPrefs,
        lastSyncedAt: DateTime.now().subtract(
          const Duration(hours: 3, minutes: 5),
        ),
      );
      setPhone(tester, width: 412);
      await pumpProfile(tester, 'en', auth: await signedInAuth(tester));
      final status = find.text(
        'Account connection is unavailable in this development build.',
      );
      await scrollIntoView(tester, find.byType(ProfileScreen), status);
      final title = tester.getRect(find.text('Local profile'));
      expect(tester.getRect(status).top, greaterThanOrEqualTo(title.bottom));
      expectNoSplitWords(tester, within: status);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );
}
