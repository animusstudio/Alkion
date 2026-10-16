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

  Widget stepper(void Function(double) onChanged) => WStepper(
    value: 80,
    step: 2.5,
    format: (v) => v.toStringAsFixed(1),
    onChanged: onChanged,
    editable: true,
  );

  testWidgets('the field requests the done action', (tester) async {
    await tester.pumpWidget(host(stepper((_) {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();

    expect(
      tester.testTextInput.setClientArgs!['inputAction'],
      'TextInputAction.done',
    );
  });

  testWidgets('dismissing the keyboard commits the typed value', (
    tester,
  ) async {
    // THE reported defect. Hiding the Android keyboard does not drop focus, so
    // without an inset-collapse listener the typed text is silently discarded.
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1.0;

    double? changed;
    await tester.pumpWidget(host(stepper((v) => changed = v)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();

    // Keyboard comes up.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '92.5');
    await tester.pump();
    expect(changed, isNull, reason: 'not committed until an exit path fires');

    // System dismisses the keyboard; focus is deliberately untouched.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pumpAndSettle();

    expect(changed, 92.5);
    expect(find.text('92.5'), findsOneWidget);
  });

  testWidgets(
    'a second edit begun while insets are already > 0 still commits on '
    'dismiss',
    (tester) async {
      // THE user-reported defect surviving for the SECOND (and every
      // subsequent) field of an editing run: _beginEdit used to always start
      // `_sawKeyboard` at false, so an edit begun while the keyboard was
      // already up (the common case once you're past the first field) got NO
      // didChangeMetrics rising edge to arm it, and the later collapse then
      // found `_sawKeyboard` false and did nothing.
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;

      final emitted = <double>[];
      await tester.pumpWidget(host(stepper(emitted.add)));
      await tester.pumpAndSettle();

      // First edit: open, bring the keyboard up, commit via the IME done
      // action — the keyboard itself never goes back down, mirroring moving
      // straight on to another field in one keyboard session.
      await tester.tap(find.text('80.0'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.enterText(find.byType(TextField), '85');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(emitted, [85.0]);

      // Second edit begins WHILE insets are already > 0 (the keyboard never
      // went down between the two edits) — no didChangeMetrics event fires
      // for this transition, the exact case this fix targets.
      await tester.tap(find.text('85.0'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '92.5');
      await tester.pump();
      expect(emitted, [85.0], reason: 'not committed until an exit path fires');

      // System dismisses the keyboard.
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(emitted, [85.0, 92.5]);
    },
  );

  testWidgets('losing focus commits the typed value', (tester) async {
    // NOTE: tester.tap on another widget does NOT unfocus in a widget test
    // (tap-outside only unfocuses for touch on web, and tests force Android),
    // so drive focus loss explicitly.
    double? changed;
    await tester.pumpWidget(host(stepper((v) => changed = v)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '85');
    await tester.pump();

    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(changed, 85.0);
  });

  testWidgets('being disposed mid-edit commits the typed value', (
    tester,
  ) async {
    double? changed;
    await tester.pumpWidget(host(stepper((v) => changed = v)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '77.5');
    await tester.pump();

    // Replacing the root deactivates and unmounts the stepper in one pump.
    await tester.pumpWidget(host(const Text('gone')));
    await tester.pump();

    expect(changed, 77.5);
  });

  testWidgets('text that is not a number commits nothing', (tester) async {
    double? changed;
    await tester.pumpWidget(host(stepper((v) => changed = v)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(changed, isNull);
    expect(find.text('80.0'), findsOneWidget);
  });

  testWidgets(
    'several exit paths firing in sequence still yield a single emission',
    (tester) async {
      // What this actually proves: once the done action has committed and
      // flipped _editing to false, the OTHER exit paths' own external checks
      // (_onFocusChange and deactivate both test `_editing` themselves before
      // ever calling into the commit path) keep firing them a no-op — not the
      // internal guard inside _applyCommit. This is a real property (three
      // independent listeners firing in a row still yield one emission) but it
      // does not pin that guard; see "a duplicate done action does not
      // double-emit" below for the one path that guard alone protects, and why
      // even that test can't prove the guard is load-bearing either.
      final emitted = <double>[];
      await tester.pumpWidget(host(stepper(emitted.add)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('80.0'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '99');
      await tester.pump();

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pumpWidget(host(const Text('gone')));
      await tester.pump();

      expect(emitted, [99.0]);
    },
  );

  testWidgets('a duplicate done action does not double-emit', (tester) async {
    // onSubmitted is the one exit path with no external `_editing` check of
    // its own — it calls _commitEdit() unconditionally and relies solely on
    // the internal guard in _applyCommit. This test does NOT prove that
    // guard is load-bearing, though: by the second action, the first commit
    // has already nulled _editCtrl, so the second re-parses an empty string,
    // which (with no emptyValue configured here) parses to null — a no-op
    // independent of the guard. This is kept as a behavior-locking
    // regression test — a duplicate IME done action (a real platform
    // occurrence) must not crash and must not re-emit — not as evidence the
    // guard matters. See the comment on the guard itself for where it does.
    final emitted = <double>[];
    await tester.pumpWidget(host(stepper(emitted.add)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('80.0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '99');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(emitted, [99.0]);
  });
}
