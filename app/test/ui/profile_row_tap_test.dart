import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/profile_screen.dart';

import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  Finder sheetRow(int i) => find.byKey(ValueKey('sheet-action-$i'));

  // Taps the middle of the widest empty stretch of a row at its vertical
  // centre, a point on none of the row's texts or icons.
  Future<void> tapEmptyMiddle(WidgetTester tester, String label) async {
    final title = find.text(label);
    await scrollIntoView(tester, find.byType(ProfileScreen), title);
    final row = find
        .ancestor(of: title, matching: find.byType(GestureDetector))
        .first;
    final rowRect = tester.getRect(row);
    final y = rowRect.center.dy;
    final painted =
        <Rect>[
            for (final f in [
              find.descendant(of: row, matching: find.byType(Text)),
              find.descendant(of: row, matching: find.byType(Icon)),
            ])
              for (final e in f.evaluate())
                tester.getRect(find.byWidget(e.widget).first),
          ].where((r) => r.top <= y && y <= r.bottom).toList()
          ..sort((a, b) => a.left.compareTo(b.left));
    var bestLeft = rowRect.left;
    var bestWidth = 0.0;
    var cursor = rowRect.left;
    for (final r in [...painted, Rect.fromLTWH(rowRect.right, y, 0, 0)]) {
      if (r.left - cursor > bestWidth) {
        bestWidth = r.left - cursor;
        bestLeft = cursor;
      }
      if (r.right > cursor) {
        cursor = r.right;
      }
    }
    expect(
      bestWidth,
      greaterThan(24),
      reason: '$label row has an empty stretch',
    );
    final point = Offset(bestLeft + bestWidth / 2, y);
    expect(painted.any((r) => r.contains(point)), isFalse);
    await tester.tapAt(point);
  }

  Future<void> pumpProfile(WidgetTester tester) async {
    setPhone(tester, width: 412);
    await tester.pumpWidget(
      harness.wrap(
        ProfileScreen(onClose: () {}, onLogout: () async {}, auth: Object()),
        locale: const Locale('en'),
      ),
    );
    await settleReal(tester);
  }

  testWidgets('tapping the empty middle of the Goal row opens the goal sheet', (
    tester,
  ) async {
    await harness.open(tester);
    await pumpProfile(tester);
    await tapEmptyMiddle(tester, 'Goal');
    await settleUntilFound(tester, sheetRow(2), where: 'goal sheet');
    expect(sheetRow(0), findsOneWidget);
    expect(sheetRow(1), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets('tapping the empty middle of the Language row opens the '
      'language sheet', (tester) async {
    await harness.open(tester);
    await pumpProfile(tester);
    await tapEmptyMiddle(tester, 'Language');
    await settleUntilFound(tester, sheetRow(4), where: 'language sheet');
    expect(sheetRow(0), findsOneWidget);
    await harness.unmount(tester);
  });
}
