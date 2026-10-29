import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/add_weight_sheet.dart';

import '../alkion/domains/local_screen_harness.dart' show ScreenHarness;
import '../support/pump_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness harness;

  Future<void> open(WidgetTester tester) async {
    final current = ScreenHarness();
    harness = current;
    // The sheet starts a real SQLite watch while building. Keep its work and
    // complete native-pool shutdown outside Flutter's fake async zone.
    addTearDown(current.close);
    await current.open(tester, seed: (_) async {});
    addTearDown(() => current.unmount(tester));
  }

  Widget wrapped() => harness.wrap(
    Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showAddWeightSheet(context),
          child: const Text('open'),
        ),
      ),
    ),
  );

  testWidgets(
    'tapping the number opens a field seeded with the current value',
    (tester) async {
      await open(tester);
      await tester.pumpWidget(wrapped());
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('open')));
      await tester.pumpAndSettle();

      // Wait for the last-entry seed query (empty table -> 70.0 kg default) to
      // land, rather than a fixed delay.
      await pumpUntilFound(tester, find.text('70.0'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('70.0'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '70.0');
    },
  );

  testWidgets('typing a value and submitting shows it', (tester) async {
    await open(tester);
    await tester.pumpWidget(wrapped());
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('open')));
    await tester.pumpAndSettle();

    await pumpUntilFound(tester, find.text('70.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('70.0'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '81.4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('81.4'), findsOneWidget);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
      reducedMotion
          ? 'reduced motion direct Save commits 81.4 before close'
          : 'tapping Save while a field is open persists the typed value, not the pre-edit one',
      (tester) async {
        if (reducedMotion) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        // THE critical regression: nothing on Android unfocuses a TextField from
        // a tap outside it (tap-outside-to-unfocus only fires for touch on web),
        // and Save's own tap handler never requests focus either — so without
        // flushing the in-flight edit as the FIRST statement of _save, this
        // writes the seeded 70.0 instead of what was typed.
        await open(tester);
        await tester.pumpWidget(wrapped());
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('open')));
        await tester.pumpAndSettle();

        await pumpUntilFound(tester, find.text('70.0'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('70.0'));
        await tester.pumpAndSettle();

        // Type but do NOT submit or blur — tap Save directly while the field is
        // still focused and open.
        await tester.enterText(find.byType(TextField), '81.4');
        await tester.pump();

        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await tester.pump();

        // Observe the UI's post-COMMIT close before querying the ordered owner.
        for (
          var i = 0;
          i < 100 && find.text('Save entry').evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(find.text('Save entry'), findsNothing);
        final rows = (await tester.runAsync(
          () => harness.database
              .getAll(
                'SELECT CAST(weight_kg AS REAL) AS weight FROM bodyweight_logs',
              )
              .timeout(const Duration(seconds: 5)),
        ))!;

        expect(rows, hasLength(1));
        expect((rows.first['weight'] as num).toDouble(), closeTo(81.4, 0.005));
      },
    );
  }

  testWidgets(
    'tapping + while a differing edit is open builds on the typed value',
    (tester) async {
      // The ± buttons are always visible (unlike WStepper's, which hide behind
      // the field), so without committing the in-flight edit first, tapping +
      // silently discards it: the bump lands on the stale pre-edit _val, then
      // the field's later (untouched-looking) commit overwrites the bump with
      // the typed text, and the button feels dead.
      await open(tester);
      await tester.pumpWidget(wrapped());
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('open')));
      await tester.pumpAndSettle();

      await pumpUntilFound(tester, find.text('70.0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('70.0'));
      await tester.pumpAndSettle();

      // Type but do NOT submit — tap + directly while the field is still open.
      await tester.enterText(find.byType(TextField), '81.4');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // kg mode steps by 0.1: one step above the TYPED 81.4, not the seeded 70.0.
      expect(find.text('81.5'), findsOneWidget);
    },
  );

  testWidgets('typing a negative value clamps to 0', (tester) async {
    await open(tester);
    await tester.pumpWidget(wrapped());
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('open')));
    await tester.pumpAndSettle();

    await pumpUntilFound(tester, find.text('70.0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('70.0'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '-5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('0.0'), findsOneWidget);
  });
}
