import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/day_view.dart';

import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  // The long seeded day: four long exercise names, a long name and focus.
  final loaded = find.byKey(const Key('day-view-working-sets'));

  Future<void> sweep(WidgetTester tester, LayoutCondition c) async {
    final name = 'Day view ${describeCondition(c)}';
    await harness.open(tester);
    setPhone(tester, width: c.width, textScale: c.textScale);
    await tester.pumpWidget(
      harness.wrap(
        Scaffold(
          body: DayView(
            id: 'd1',
            onEdit: () {},
            onClose: () {},
            onStart: (_) {},
          ),
        ),
        locale: c.locale,
      ),
    );
    await settleUntilFound(tester, loaded, where: name);
    await expectLayoutHoldsWhileScrolling(tester, find.byType(DayView), name);
    await harness.unmount(tester);
  }

  for (final c in layoutConditions) {
    testWidgets(
      'Day view holds at ${describeCondition(c)}',
      (tester) => sweep(tester, c),
    );
  }

  // Spanish is outside the sweep's locales and has the longest Start label.
  testWidgets(
    'Day view holds at 320dp 2.0x es',
    (tester) =>
        sweep(tester, (width: 320, textScale: 2.0, locale: const Locale('es'))),
  );
}
