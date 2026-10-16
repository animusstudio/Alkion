import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/profile_screen.dart';

import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  // The header's training line comes from its own query: wait for it, or the
  // header is checked without its longest line. Never match on ' · ': the
  // sync status and the local-first hint contain it too.
  final trainingLine = find.byKey(const Key('profile-training-line'));

  for (final c in layoutConditions) {
    final name = describeCondition(c);
    testWidgets('Profile holds at $name', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: c.width, textScale: c.textScale);
      await tester.pumpWidget(
        harness.wrap(
          ProfileScreen(onClose: () {}, onLogout: () async {}, auth: Object()),
          locale: c.locale,
        ),
      );
      await settleReal(tester);
      await settleUntilFound(tester, trainingLine, where: 'Profile $name');
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(ProfileScreen),
        'Profile $name',
      );
      await harness.unmount(tester);
    });

    // Signed in with sync on, offline, last synced 3h ago: the longest
    // sync status ("Offline · synchronisiert vor 3 Std").
    testWidgets('Profile signed in holds at $name', (tester) async {
      await harness.open(
        tester,
        prefs: syncOnPrefs,
        lastSyncedAt: DateTime.now().subtract(
          const Duration(hours: 3, minutes: 5),
        ),
      );
      setPhone(tester, width: c.width, textScale: c.textScale);
      final auth = await signedInAuth(tester);
      await tester.pumpWidget(
        harness.wrap(
          ProfileScreen(onClose: () {}, onLogout: () async {}, auth: auth),
          locale: c.locale,
        ),
      );
      await settleReal(tester);
      await settleUntilFound(
        tester,
        trainingLine,
        where: 'Profile signed in $name',
      );
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(ProfileScreen),
        'Profile signed in $name',
      );
      await harness.unmount(tester);
    });
  }

  // Spanish is not in the sweep's locales, and its training line is the
  // longest of the four ("Entrenando desde … · rutina de 3 días").
  testWidgets('Profile holds at 320dp 2.0x es', (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 320, textScale: 2.0);
    await tester.pumpWidget(
      harness.wrap(
        ProfileScreen(onClose: () {}, onLogout: () async {}, auth: Object()),
        locale: const Locale('es'),
      ),
    );
    await settleReal(tester);
    await settleUntilFound(
      tester,
      trainingLine,
      where: 'Profile 320dp 2.0x es',
    );
    await expectLayoutHoldsWhileScrolling(
      tester,
      find.byType(ProfileScreen),
      'Profile 320dp 2.0x es',
    );
    await harness.unmount(tester);
  });
}
