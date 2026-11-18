import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/session/set_values_editor.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/fit_label.dart';
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

  testWidgets(
    'unavailable values keep rulers and empty typing seeds without authoring zero',
    (tester) async {
      await tester.pumpWidget(
        host(
          SetValuesEditor(
            weightKg: 0,
            reps: 0,
            unit: UnitService(),
            weightAvailable: false,
            repsAvailable: false,
            onWeight: (v) {
              weightCalls++;
              lastWeight = v;
            },
            onReps: (_) {},
          ),
        ),
      );
      for (final key in ['live-weight', 'live-reps']) {
        final ruler = tester.widget<RulerPicker>(find.byKey(Key(key)));
        expect(ruler.format(ruler.value), '—');
      }
      expect(weightCalls, 0);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('live-weight')),
          matching: find.byKey(const Key('ruler-centre')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('number-entry-field')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(find.byKey(const Key('number-entry-field')), '0');
      await tester.tap(find.byKey(const Key('number-entry-done')));
      await tester.pumpAndSettle();
      expect(weightCalls, 1, reason: 'explicit zero is a deliberate selection');
      expect(lastWeight, 0);
    },
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

  Finder guide(int i) => find.byType(SetFieldGuide).at(i);
  Finder guideUnit(int i) => find.descendant(
    of: guide(i),
    matching: find.byKey(const Key('set-field-unit')),
  );

  testWidgets(
    'field captions paint no marker or leader and show the unit in the accent',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final unit in [UnitService(), UnitService()..setUnit(Unit.lb)]) {
        await tester.pumpWidget(host(editor(unit: unit)));
        expect(find.byType(SetFieldGuide), findsNWidgets(2));
        final tokens = tester.element(guide(0)).tokens;
        for (var i = 0; i < 2; i++) {
          expect(
            find.descendant(of: guide(i), matching: find.byType(CustomPaint)),
            findsNothing,
            reason: 'the caption draws no marker square or dashed leader',
          );
          final unitText = tester.widget<Text>(guideUnit(i));
          expect(unitText.style!.color, tokens.accentText);
          // The unit sits on the right edge of the inset caption row.
          expect(
            tester.getRect(guideUnit(i)).right,
            moreOrLessEquals(tester.getRect(guide(i)).right),
          );
        }
        expect(tester.widget<Text>(guideUnit(0)).data, unit.uLabel);
        expect(tester.widget<Text>(guideUnit(1)).data, 'reps');
        final name = tester.widget<Text>(
          find.descendant(of: guide(0), matching: find.text('WEIGHT')),
        );
        expect(name.style!.color, tokens.dim);
        expect(name.style!.letterSpacing, closeTo(0.72, 1e-9));
        expect(find.text('REPS'), findsOneWidget);
      }
    },
  );

  testWidgets('the caption is excluded from semantics; the ruler names it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(host(editor()));
      expect(find.bySemanticsLabel('WEIGHT'), findsNothing);
      expect(find.bySemanticsLabel('kg'), findsNothing);
      expect(find.bySemanticsLabel('Weight, kg'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  for (final code in ['en', 'de', 'it']) {
    testWidgets('field captions fit without splitting at 320dp 2x $code', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        wrapL10n(SingleChildScrollView(child: editor()), locale: Locale(code)),
      );
      expect(tester.takeException(), isNull);
      for (var i = 0; i < 2; i++) {
        expectNoSplitWords(tester, within: guide(i), where: '$code caption');
        final name = find.descendant(
          of: guide(i),
          matching: find.byType(FitLabel),
        );
        // The name never runs under the unit, and never ellipsizes.
        expect(
          tester.getRect(name).right,
          lessThanOrEqualTo(tester.getRect(guideUnit(i)).left),
        );
        expect(tester.renderObject<RenderFitLabel>(name).ellipsized, isFalse);
      }
    });
  }

  testWidgets(
    'the long German reps caption stays one whole word beside its unit',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(child: editor()),
          locale: const Locale('de'),
        ),
      );
      final word = find.text('WIEDERHOLUNGEN');
      expect(word, findsOneWidget);
      expect(tester.widget<Text>(guideUnit(1)).data, 'Wdh.');
      expectOneLine(tester, word);
      expect(
        tester
            .renderObject<RenderFitLabel>(
              find.ancestor(of: word, matching: find.byType(FitLabel)),
            )
            .ellipsized,
        isFalse,
      );
      expectNoSplitWords(tester, within: guide(1), where: 'de reps');
      expect(
        tester.getRect(word).right,
        lessThanOrEqualTo(tester.getRect(guideUnit(1)).left),
      );
      expect(
        tester.getRect(guideUnit(1)).right,
        lessThanOrEqualTo(320 - 16 + 0.01),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a hint follows the name when wide and stacks when narrow', (
    tester,
  ) async {
    Widget caption(double width) => wrapL10n(
      Center(
        child: SizedBox(
          width: width,
          child: const SetFieldGuide(
            label: 'Weight',
            unit: 'kg',
            hint: 'last 60',
          ),
        ),
      ),
    );
    await tester.pumpWidget(caption(400));
    expect(find.text('last 60'), findsNothing, reason: 'inline in the name');
    expect(find.textContaining('last 60', findRichText: true), findsOneWidget);
    await tester.pumpWidget(caption(110));
    expect(find.text('last 60'), findsOneWidget, reason: 'stacked below');
    expect(
      tester.getRect(find.text('last 60')).top,
      greaterThan(tester.getRect(find.text('WEIGHT')).bottom - 0.5),
    );
    expect(tester.takeException(), isNull);
  });

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
