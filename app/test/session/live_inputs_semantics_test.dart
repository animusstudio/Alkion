import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/catalog_set_values_editor.dart';
import 'package:alkion/session/log_set_bar.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/session/set_values_editor.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/ruler_picker.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';

// P7: the busy Finish bar, set-line and RIR semantics, typed-entry limits
// and the coarse duration/distance rulers.

final AppLocalizations _l = lookupAppLocalizations(const Locale('en'));

SetState _s({
  bool done = false,
  bool warmup = false,
  int? rir = 1,
  double w = 140,
  int reps = 6,
}) => SetState(
  id: 's1',
  weightKg: w,
  reps: reps,
  rir: warmup ? null : rir,
  isWarmup: warmup,
  done: done,
);

UnitService _lb() => UnitService()..setUnit(Unit.lb);

Future<void> _openEntry(WidgetTester tester, String ruler) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(Key(ruler)),
      matching: find.byKey(const Key('ruler-centre')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('number-entry-field')), text);
  await tester.tap(find.byKey(const Key('number-entry-done')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(preloadAppFonts);

  group('Finish bar', () {
    Widget bar({required bool busy, VoidCallback? onFinish}) => wrapL10n(
      Scaffold(
        bottomNavigationBar: LogSetBar(
          live: null,
          canFinish: true,
          busy: busy,
          unit: UnitService(),
          onLog: () {},
          onFinish: onFinish ?? () {},
        ),
      ),
    );

    testWidgets('busy: disabled, labelled, live and visibly working', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var finishes = 0;
      await tester.pumpWidget(bar(busy: true, onFinish: () => finishes++));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(_l.sessionFinishSaving), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('log-set-bar'))),
        isA<FilledButton>().having((b) => b.onPressed, 'onPressed', isNull),
      );
      expect(find.byKey(const Key('log-set-bar-progress')), findsOneWidget);
      final data = tester
          .getSemantics(find.bySemanticsLabel(_l.sessionFinishSaving))
          .getSemanticsData();
      expect(data.flagsCollection.isLiveRegion, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      await tester.tap(find.byKey(const Key('log-set-bar')));
      expect(finishes, 0);
      handle.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('busy under reduced motion shows no spinner', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(bar(busy: true));
      expect(find.text(_l.sessionFinishSaving), findsOneWidget);
      expect(find.byKey(const Key('log-set-bar-progress')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('idle: Finish is tappable', (tester) async {
      var finishes = 0;
      await tester.pumpWidget(bar(busy: false, onFinish: () => finishes++));
      expect(find.text(_l.sessionFinishWorkout), findsOneWidget);
      await tester.tap(find.byKey(const Key('log-set-bar')));
      expect(finishes, 1);
    });
  });

  group('set line semantics', () {
    Widget line(SetState s, {int idx = 1}) => SetLine(
      set: s,
      workIndex: s.isWarmup ? -1 : idx,
      unit: UnitService(),
      isLiveTop: false,
      isLivePr: false,
      showRirPrompt: false,
      onTap: () {},
      onRir: (_) {},
    );

    for (final (name, set, idx, label) in [
      ('logged', _s(done: true), 1, 'Set 1, 140 kg × 6, RIR 1, done'),
      // A pending line is blank on screen and reads no values either.
      ('pending', _s(), 3, 'Set 3, not done'),
      ('warm-up', _s(warmup: true, w: 70, reps: 8), -1, 'Warm-up, not done'),
      (
        'logged warm-up',
        _s(warmup: true, w: 70, reps: 8, done: true),
        -1,
        'Warm-up, 70 kg × 8, done',
      ),
    ]) {
      testWidgets('a $name line reads its state', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(wrapL10n(line(set, idx: idx)));
        final data = tester
            .getSemantics(find.byType(SetLine))
            .getSemanticsData();
        expect(data.label, label);
        expect(data.flagsCollection.isButton, isTrue);
        handle.dispose();
      });
    }

    test('an unknown weight reads as no value, never zero', () {
      final set = _s(done: true)..weightUnavailable = true;
      expect(
        setLineSemanticsLabel(_l, UnitService(), set, 2),
        'Set 2, no value × 6, RIR 1, done',
      );
    });
  });

  group('typed entry limits', () {
    Widget editor({
      UnitService? unit,
      List<double>? weights,
      List<int>? reps,
    }) => wrapL10n(
      SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: SetValuesEditor(
            weightKg: 100,
            reps: 6,
            unit: unit ?? UnitService(),
            onWeight: (v) => weights?.add(v),
            onReps: (v) => reps?.add(v),
          ),
        ),
      ),
    );

    testWidgets('reps outside 1–100 keep the sheet open with a message', (
      tester,
    ) async {
      final reps = <int>[];
      await tester.pumpWidget(editor(reps: reps));
      await _openEntry(tester, 'live-reps');
      for (final (typed, message) in [
        ('0', _l.numberEntryMin('1')),
        ('101', _l.numberEntryMax('100')),
      ]) {
        await _submit(tester, typed);
        expect(find.byKey(const Key('number-entry-field')), findsOneWidget);
        expect(find.text(message), findsOneWidget);
      }
      await _submit(tester, '100');
      expect(find.byKey(const Key('number-entry-field')), findsNothing);
      expect(reps, [100]);
      final ruler = tester.widget<RulerPicker>(
        find.byKey(const Key('live-reps')),
      );
      expect((ruler.min, ruler.max), (1.0, 100.0));
    });

    testWidgets('weight over 500 kg is refused; an unparseable entry too', (
      tester,
    ) async {
      final weights = <double>[];
      await tester.pumpWidget(editor(weights: weights));
      await _openEntry(tester, 'live-weight');
      await _submit(tester, '500.5');
      expect(find.text(_l.numberEntryMax('500 kg')), findsOneWidget);
      await _submit(tester, '.');
      expect(find.text(_l.numberEntryInvalid), findsOneWidget);
      await _submit(tester, '500');
      expect(find.byKey(const Key('number-entry-field')), findsNothing);
      expect(weights, [500]);
    });

    testWidgets('in lb the limit is 1100 lb and the ruler ends there', (
      tester,
    ) async {
      final weights = <double>[];
      await tester.pumpWidget(editor(unit: _lb(), weights: weights));
      expect(
        tester.widget<RulerPicker>(find.byKey(const Key('live-weight'))).max,
        1100,
      );
      await _openEntry(tester, 'live-weight');
      await _submit(tester, '1101');
      expect(find.text(_l.numberEntryMax('1100 lb')), findsOneWidget);
      await _submit(tester, '1100');
      expect(weights.single, closeTo(UnitService.toKg(1100, Unit.lb), .01));
    });
  });

  group('coarse catalog rulers', () {
    CatalogSetEvidence evidence() => CatalogSetEvidence(
      selection: CatalogSelectionEvidence(
        exerciseId: 'synthetic',
        contextId: 'track',
        contextRevision: 1,
        profile: CatalogMeasurementProfileEvidence.forKey(
          'duration_distance_optional',
        ),
        displayLabel: 'Synthetic run',
      ),
      metrics: {
        'duration': CatalogMetricEvidence.fromInput(
          '60',
          metric: 'duration',
          unit: 's',
        ),
        'distance': CatalogMetricEvidence.fromInput(
          '400',
          metric: 'distance',
          unit: 'm',
        ),
      },
    );

    testWidgets('duration steps 5 s and distance 10 m, with no fine zoom', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: CatalogSetValuesEditor(
              evidence: evidence(),
              unit: UnitService(),
              onMetricChanged: (metric, text, unit) {},
            ),
          ),
        ),
      );
      for (final (metric, step) in [('duration', 5.0), ('distance', 10.0)]) {
        final ruler = tester.widget<RulerPicker>(
          find.byKey(ValueKey('catalog-ruler-$metric')),
        );
        expect(ruler.step, step, reason: metric);
        expect(ruler.fineStep, isNull, reason: metric);
      }
    });
  });
}
