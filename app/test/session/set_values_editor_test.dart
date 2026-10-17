import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/session/set_values_editor.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/ruler_picker.dart';

import '../support/l10n_harness.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);
  late int weightCalls;
  late double? lastWeight;
  setUp(() {
    weightCalls = 0;
    lastWeight = null;
  });

  Widget editor({double weightKg = 140, int reps = 6, UnitService? unit}) =>
      SetValuesEditor(
        weightKg: weightKg,
        reps: reps,
        unit: unit ?? UnitService(),
        onWeight: (v) {
          weightCalls++;
          lastWeight = v;
        },
        onReps: (_) {},
      );

  Widget host(Widget child) => wrapL10n(
    SingleChildScrollView(child: SizedBox(width: 260, child: child)),
  );

  for (final code in ['en', 'de', 'es', 'it']) {
    testWidgets(
      'typed live weight retains exact comma input above keyboard at 320dp 2x $code',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          wrapL10n(
            SingleChildScrollView(child: editor()),
            locale: Locale(code),
          ),
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('live-weight')),
            matching: find.byKey(const Key('ruler-centre')),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('number-entry-field'));
        final done = find.byKey(const Key('number-entry-done'));
        expect(tester.getSize(field).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(done).height, greaterThanOrEqualTo(48));
        expect(tester.getRect(done).bottom, lessThanOrEqualTo(560));
        expect(weightCalls, 0);
        await tester.enterText(field, '151,5');
        expectNoSplitWords(tester);
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(lastWeight, 151.5);
        expect(weightCalls, 1);
        expect(find.byKey(const Key('number-entry-field')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  // A coarse drag: each step's worth of distance covered at ~180 dp/s, safely
  // between the 120 dp/s zoom-in threshold and the 300 dp/s fling dead zone,
  // so it neither zooms in nor overshoots on release.
  Future<void> coarseSwipe(WidgetTester tester, Key ruler, int steps) async {
    await tester.timedDrag(
      find.byKey(ruler),
      Offset(-steps * RulerPicker.defaultItemExtent, 0),
      Duration(milliseconds: 400 * steps),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a coarse weight swipe in kg reports the whole-kilo value', (
    tester,
  ) async {
    await tester.pumpWidget(host(editor(weightKg: 60)));
    await coarseSwipe(tester, const Key('live-weight'), 2);
    expect(lastWeight, 62);
    expect(weightCalls, greaterThanOrEqualTo(1));
  });

  testWidgets(
    'a coarse weight swipe in lb reports the kg of the stepped pound value',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final lb = UnitService()..setUnit(Unit.lb);
      // 135 lb in kg, so the ruler's display value starts exactly on 135 lb.
      final startKg = UnitService.toKg(135, Unit.lb);
      await tester.pumpWidget(host(editor(weightKg: startKg, unit: lb)));
      await coarseSwipe(tester, const Key('live-weight'), 1);
      expect(lastWeight, closeTo(UnitService.toKg(140, Unit.lb), 0.01));
    },
  );

  testWidgets('a slow drag in kg zooms in and reports a quarter-kilo value', (
    tester,
  ) async {
    await tester.pumpWidget(host(editor(weightKg: 60)));
    // 75 dp/s: below kZoomInSpeed (120) for well over kZoomInDwell (200ms),
    // so the tape zooms into the 0.25 kg fine step before it finishes. It
    // lands on the fine neighbour reached in the drag's direction (up the
    // tape), not necessarily the very first one.
    await tester.timedDrag(
      find.byKey(const Key('live-weight')),
      const Offset(-150, 0),
      const Duration(seconds: 2),
    );
    await tester.pumpAndSettle();
    final v = lastWeight!;
    expect(v, greaterThan(60));
    expect(v, lessThanOrEqualTo(61));
    expect(
      (v * 4).roundToDouble() / 4,
      closeTo(v, 1e-9),
      reason: 'not on a quarter-kilo value: $v',
    );
  });

  testWidgets('typed entry calls onWeight with the typed value', (
    tester,
  ) async {
    await tester.pumpWidget(host(editor()));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('live-weight')),
        matching: find.byKey(const Key('ruler-centre')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('number-entry-field')),
      '151,5',
    );
    await tester.tap(find.byKey(const Key('number-entry-done')));
    await tester.pumpAndSettle();
    expect(lastWeight, 151.5);
    expect(weightCalls, 1);
  });

  testWidgets('an untouched lb entry calls nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final lb = UnitService()..setUnit(Unit.lb);
    await tester.pumpWidget(host(editor(weightKg: 100, unit: lb)));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('live-weight')),
        matching: find.byKey(const Key('ruler-centre')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('220'), findsWidgets); // 100 kg shown as whole pounds
    await tester.tap(find.byKey(const Key('number-entry-done')));
    await tester.pumpAndSettle();
    expect(weightCalls, 0);
  });
}
