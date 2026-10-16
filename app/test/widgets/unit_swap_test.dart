import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/motion.dart';

void main() {
  testWidgets(
    'UnitSwap cross-fades when the key changes and settles on the new child',
    (tester) async {
      Widget build(String unit, String text) => MaterialApp(
        home: UnitSwap(unitKey: unit, child: Text(text)),
      );
      await tester.pumpWidget(build('kg', '100 kg'));
      await tester.pumpAndSettle();
      expect(find.text('100 kg'), findsOneWidget);

      await tester.pumpWidget(build('lb', '220 lb'));
      await tester.pump(const Duration(milliseconds: 40));
      // Mid-swap both children exist (cross-fade).
      expect(find.text('220 lb'), findsOneWidget);
      expect(find.text('100 kg'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('100 kg'), findsNothing);
      expect(find.text('220 lb'), findsOneWidget);
    },
  );

  testWidgets('UnitSwap does not animate when only the value changes', (
    tester,
  ) async {
    Widget build(String text) => MaterialApp(
      home: UnitSwap(unitKey: 'kg', child: Text(text)),
    );
    await tester.pumpWidget(build('100 kg'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(build('102.5 kg'));
    await tester.pump(const Duration(milliseconds: 40));
    // Same key → AnimatedSwitcher swaps in place, old child gone immediately.
    expect(find.text('100 kg'), findsNothing);
    expect(find.text('102.5 kg'), findsOneWidget);
  });

  testWidgets('UnitSwap works under Expanded in a Row (flex stays outside)', (
    tester,
  ) async {
    // Regression guard for the Profile quick-stat row: Expanded must be the
    // direct Row child — a flex ParentDataWidget INSIDE UnitSwap's
    // AnimatedSwitcher throws "Incorrect use of ParentDataWidget" at runtime.
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Expanded(
              child: UnitSwap(
                unitKey: 'kg',
                child: Container(height: 40, color: const Color(0xFF112233)),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The card stretches to the full Expanded width.
    expect(tester.getSize(find.byType(Container)).width, 800);
  });

  testWidgets('a content-sized child still fills the Expanded width', (
    tester,
  ) async {
    // AnimatedSwitcher's default Stack loosens constraints, which shrank the
    // Profile bodyweight card to its text and centred it.
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Expanded(
              child: UnitSwap(
                unitKey: 'kg',
                child: Container(
                  key: const Key('card'),
                  padding: const EdgeInsets.all(8),
                  child: const Text('66.4kg'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('card'))).width, 800);
  });
}
