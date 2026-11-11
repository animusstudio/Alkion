import 'package:alkion/ui/alkion_recovery/recovery_screen.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  Future<void> openProfile(WidgetTester tester) async {
    await harness.open(tester);
    setPhone(tester, width: 320, textScale: 2);
    await tester.pumpWidget(harness.wrap(ProfileScreen(onClose: () {})));
    await settleReal(tester);
  }

  testWidgets('Data offers backup and history sharing, with no Reps import', (
    tester,
  ) async {
    await openProfile(tester);
    final share = find.text('Share workout history');
    await scrollIntoView(tester, find.byType(ProfileScreen), share);
    final data = find.byKey(const Key('profile-data-actions'));
    expect(
      find.descendant(of: data, matching: find.text('Backup & restore')),
      findsOneWidget,
    );
    expect(find.descendant(of: data, matching: share), findsOneWidget);
    expect(find.textContaining('Import'), findsNothing);
    expect(find.textContaining('Reps'), findsNothing);
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });

  testWidgets('Backup & restore opens backup actions', (tester) async {
    await openProfile(tester);
    final action = find.text('Backup & restore');
    await scrollIntoView(tester, find.byType(ProfileScreen), action);
    await tester.tap(action);
    await settleUntilFound(
      tester,
      find.byType(AlkionRecoveryScreen),
      where: 'backup route',
    );
    expect(find.byKey(const Key('backup-create')), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets(
    'Share workout history opens the existing date picker; cancel stays in Profile',
    (tester) async {
      await openProfile(tester);
      final action = find.text('Share workout history');
      await scrollIntoView(tester, find.byType(ProfileScreen), action);
      await tester.tap(action);
      await settleUntilFound(
        tester,
        find.byType(DateRangePickerDialog),
        where: 'history date range',
      );
      Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.byType(DateRangePickerDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );
}
