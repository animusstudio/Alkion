import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/stepper.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: buildTheme(Brightness.dark, accents[0]),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(child: SizedBox(width: 160, child: child)),
    ),
  );

  testWidgets('editable: tap value → type → commit fires onChanged', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 80,
          step: 2.5,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '92.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(changed, 92.5);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('92.5'), findsOneWidget);
  });

  testWidgets('editable: comma decimal and clamp below zero', (tester) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 10,
          step: 1,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10.0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12,5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changed, 12.5);

    await tester.tap(find.text('12.5'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '-4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changed, 0.0);
  });

  testWidgets('editable: invalid input reverts without onChanged', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 10,
          step: 1,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10.0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changed, isNull);
    expect(find.text('10.0'), findsOneWidget);
  });

  testWidgets('editable: parseDisplay converts typed display value back', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 100, // internal space (e.g. kg)
          step: 1,
          format: (v) => (v * 2).toStringAsFixed(0), // display = 2x internal
          parseDisplay: (d) => d / 2, // back to internal
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('200'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '250');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changed, 125.0); // 250 display → 125 internal
  });

  testWidgets('non-editable: tapping the value does nothing', (tester) async {
    await tester.pumpWidget(
      host(
        WStepper(
          value: 10,
          step: 1,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10.0'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('formatForEdit prefills a bare number for a suffixed display', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 80,
          step: 2.5,
          format: (v) => '${v.toStringAsFixed(0)}kg',
          formatForEdit: (v) => v.toStringAsFixed(0),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('80kg'), findsOneWidget);
    await tester.tap(find.text('80kg'));
    await tester.pumpAndSettle();

    // Seeded with the bare number, not "80kg" — which would not round-trip.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '80',
    );

    await tester.enterText(find.byType(TextField), '90');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changed, 90.0);
    expect(find.text('90kg'), findsOneWidget);
  });

  testWidgets('a typed value above max is clamped and displayed clamped', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 8,
          step: 1,
          min: 1,
          max: 99,
          format: (v) => v.round().toString(),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('8'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '150');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(changed, 99.0);
    expect(find.text('99'), findsOneWidget);
    expect(find.text('150'), findsNothing); // must not linger above the cap
  });

  testWidgets('a typed value below min is clamped up', (tester) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 8,
          step: 1,
          min: 1,
          max: 99,
          format: (v) => v.round().toString(),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('8'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(changed, 1.0);
  });

  testWidgets('stepping also respects max', (tester) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 99,
          step: 1,
          min: 1,
          max: 99,
          format: (v) => v.round().toString(),
          onChanged: (v) => changed = v,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('stepper-inc')));
    await tester.pump();
    // Already at max — clamping produced no actual change, so no emission
    // (same "only notify on an actual change" rule _commitEdit follows).
    expect(changed, isNull);
    expect(find.text('99'), findsOneWidget);
  });

  testWidgets('tapping + at max does not emit onChanged', (tester) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 98,
          step: 1,
          min: 1,
          max: 99,
          format: (v) => v.round().toString(),
          onChanged: (v) => changed = v,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('stepper-inc'))); // 98 -> 99
    await tester.pump();
    expect(changed, 99.0);

    changed = null;
    await tester.tap(find.byKey(const Key('stepper-inc'))); // already at max
    await tester.pump();
    expect(changed, isNull);
    expect(find.text('99'), findsOneWidget);
  });

  testWidgets('clearing the field commits emptyValue when one is given', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 90,
          step: 15,
          emptyValue: 0,
          format: (v) => v == 0 ? 'Default' : '${v.round()}s',
          formatForEdit: (v) => v == 0 ? '' : v.round().toString(),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('90s'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(changed, 0.0);
    expect(find.text('Default'), findsOneWidget);
  });

  testWidgets('clearing the field changes nothing without emptyValue', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(
      host(
        WStepper(
          value: 90,
          step: 15,
          format: (v) => v.round().toString(),
          onChanged: (v) => changed = v,
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('90'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(changed, isNull);
    expect(find.text('90'), findsOneWidget);
  });

  testWidgets(
    'allowDecimal false requests an integer keypad and blocks a dot',
    (tester) async {
      await tester.pumpWidget(
        host(
          WStepper(
            value: 8,
            step: 1,
            allowDecimal: false,
            format: (v) => v.round().toString(),
            onChanged: (_) {},
            editable: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('8'));
      await tester.pumpAndSettle();

      final args = tester.testTextInput.setClientArgs!;
      final inputType = args['inputType'] as Map<String, dynamic>;
      expect(inputType['name'], 'TextInputType.number');
      expect(inputType['decimal'], isFalse);

      // The formatter rejects a separator outright — it must reject to the
      // PRIOR text ("8"), not merely drop the dot (which would also pass an
      // `isNot(contains('.'))` check even if the formatter had wiped the field
      // to "15" or "").
      await tester.enterText(find.byType(TextField), '1.5');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '8',
      );
    },
  );

  testWidgets('allowDecimal true requests a decimal keypad', (tester) async {
    await tester.pumpWidget(
      host(
        WStepper(
          value: 80,
          step: 2.5,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (_) {},
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();

    final inputType =
        tester.testTextInput.setClientArgs!['inputType']
            as Map<String, dynamic>;
    expect(inputType['decimal'], isTrue);
  });

  testWidgets('the formatter rejects a second separator', (tester) async {
    await tester.pumpWidget(
      host(
        WStepper(
          value: 1,
          step: 1,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (_) {},
          editable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.0'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '1.2');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1.2.3');
    await tester.pumpAndSettle();
    // The rejected edit leaves the previous text in place, it does NOT wipe it.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '1.2',
    );
  });

  testWidgets('an unrelated parent rebuild does not clobber a stepped value', (
    tester,
  ) async {
    // Regression guard: the internal copy exists so consecutive taps compound.
    // A rebuild from an unrelated source must not snap the label back.
    double? changed;
    var extra = 0;
    late StateSetter setOuter;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return Column(
              children: [
                Text('extra $extra'),
                WStepper(
                  value: 10,
                  step: 1,
                  format: (v) => v.round().toString(),
                  onChanged: (v) => changed = v,
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('stepper-inc')));
    await tester.pump();
    expect(changed, 11.0);
    expect(find.text('11'), findsOneWidget);

    // Parent rebuilds for an unrelated reason, still passing value: 10.
    setOuter(() => extra = 1);
    await tester.pump();
    expect(
      find.text('11'),
      findsOneWidget,
      reason: 'an unrelated rebuild must not revert the stepped value',
    );
  });

  testWidgets(
    'tapping + while a field is open commits the typed value first, then '
    'steps from it',
    (tester) async {
      // Probe (pre-fix) emitted [82.5, 85.0, 80.0]: _step ignored _editing and
      // stepped the stale pre-edit value, then the untouched seed text later
      // reverted both taps on commit. Fixed: the open edit commits first, so
      // the step builds on what was typed and the field closes.
      final emitted = <double>[];
      await tester.pumpWidget(
        host(
          WStepper(
            value: 80,
            step: 2.5,
            format: (v) => v.toStringAsFixed(1),
            onChanged: emitted.add,
            editable: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('80.0'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '82.5');
      await tester.pump();

      await tester.tap(find.byKey(const Key('stepper-inc')));
      await tester.pump();

      expect(emitted, [82.5, 85.0]);
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'stepping also closes the open edit',
      );
      expect(find.text('85.0'), findsOneWidget);
    },
  );

  testWidgets(
    'an untouched lossy lb-mode weight field does not fire onChanged',
    (tester) async {
      // 100 kg seeds "220" (a whole-lb formatForEdit is lossy); parsing "220"
      // back gives ~99.79, not 100. Comparing the parsed VALUE to the previous
      // one cannot catch this — both are valid, merely unequal, numbers — so
      // the guard must compare the TEXT instead.
      double? changed;
      await tester.pumpWidget(
        host(
          WStepper(
            value: 100, // kg (caller space)
            step: 2.5,
            format: (v) => (v * 2.2046226).round().toString(),
            formatForEdit: (v) => (v * 2.2046226).round().toString(),
            parseDisplay: (d) => d / 2.2046226,
            onChanged: (v) => changed = v,
            editable: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('220'), findsOneWidget);
      await tester.tap(find.text('220'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '220',
      );

      // Leave without typing anything.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        changed,
        isNull,
        reason:
            'an untouched field must not rewrite the stored value even '
            'though "220" parses back to ~99.79, not 100',
      );
      expect(find.text('220'), findsOneWidget);
    },
  );
}
