import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/pump_until.dart';
import '../support/screen_harness.dart';

CatalogSetEvidence _typed(String reps) => CatalogSetEvidence(
  selection: CatalogSelectionEvidence(
    exerciseId: 'synthetic-exercise',
    contextId: 'synthetic-context',
    contextRevision: 1,
    displayLabel: 'Synthetic press',
    contextLabel: 'Machine A',
    profile: CatalogMeasurementProfileEvidence.forKey('load_reps'),
  ),
  metrics: {
    'repetitions': CatalogMetricEvidence.fromInput(
      reps,
      metric: 'repetitions',
      unit: CatalogMetricEvidence.defaultUnit('repetitions'),
    ),
    'reported_load': CatalogMetricEvidence.fromInput(
      '142.5',
      metric: 'reported_load',
      unit: CatalogMetricEvidence.defaultUnit('reported_load'),
    ),
  },
);

LoggedSet _set(
  int n, {
  int? rir,
  bool warmup = false,
  bool top = false,
  bool catalog = false,
  double kg = 100,
  int reps = 6,
}) => LoggedSet(
  id: 'x$n',
  exerciseId: 'ex',
  setNumber: n,
  weightKg: kg,
  reps: reps,
  rir: rir,
  isWarmup: warmup,
  isTopSet: top,
  isPr: false,
  catalog: catalog ? _typed('$reps') : null,
  blockId: catalog ? 'b' : null,
);

ExerciseBlockData _block(List<LoggedSet> sets, {bool pr = false}) {
  final top = sets.firstWhere((s) => s.isTopSet, orElse: () => sets.first);
  return ExerciseBlockData(
    exerciseId: 'ex',
    sets: sets,
    topWeight: top.weightKg,
    topReps: top.reps,
    isPr: pr,
  );
}

void main() {
  setUpAll(preloadAppFonts);

  Widget row(
    ExerciseBlockData block, {
    String name = 'Bench Press',
    Locale locale = const Locale('en'),
  }) => wrapL10n(
    Builder(
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SummaryExerciseRow(
          block: block,
          name: name,
          unit: UnitService(),
          tokens: context.tokens,
        ),
      ),
    ),
    locale: locale,
  );

  Finder rirTags() => find.byKey(const Key('summary-set-rir'));

  group('catalog rows', () {
    testWidgets('each working set with a RIR shows the tag on the right', (
      tester,
    ) async {
      await tester.pumpWidget(
        row(
          _block([
            _set(1, catalog: true, warmup: true, reps: 12),
            _set(2, catalog: true, rir: 2),
            _set(3, catalog: true),
            _set(4, catalog: true, rir: 0),
          ]),
        ),
      );
      // The warm-up and the set with no RIR show none.
      expect(rirTags(), findsNWidgets(2));
      expect(find.text('RIR 2'), findsOneWidget);
      expect(find.text('RIR 0'), findsOneWidget);
      final tag = tester.getRect(find.text('RIR 2'));
      final values = tester.getRect(
        find
            .byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText().contains('142.5'),
            )
            .first,
      );
      expect(tag.left, greaterThan(values.right));
      expect(
        tester.getRect(rirTags().first).right,
        moreOrLessEquals(800 - 16 - 16, epsilon: 1),
      );
    });

    testWidgets('a warm-up never shows one, even when a value is stored', (
      tester,
    ) async {
      await tester.pumpWidget(
        row(
          _block([
            _set(1, catalog: true, warmup: true, rir: 3),
            _set(2, catalog: true),
          ]),
        ),
      );
      expect(rirTags(), findsNothing);
      expect(find.textContaining('RIR'), findsNothing);
    });

    testWidgets('an out-of-range stored RIR shows as stored', (tester) async {
      await tester.pumpWidget(row(_block([_set(1, catalog: true, rir: 9)])));
      expect(find.text('RIR 9'), findsOneWidget);
    });

    testWidgets('the spoken line includes the RIR', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(row(_block([_set(1, catalog: true, rir: 2)])));
      final label = tester.getSemantics(rirTags()).label;
      expect(label, contains('RIR 2'));
      expect(label, contains('142.5'));
      handle.dispose();
    });
  });

  group('classic rows', () {
    testWidgets('the top set shows its RIR beside the TOP tag', (tester) async {
      await tester.pumpWidget(
        row(
          _block([
            _set(1, warmup: true, kg: 60, reps: 12),
            _set(2, kg: 100, rir: 1, top: true),
            _set(3, kg: 90, rir: 3),
          ]),
        ),
      );
      expect(rirTags(), findsOneWidget);
      expect(find.text('RIR 1'), findsOneWidget);
      expect(find.text('TOP'), findsOneWidget);
      expect(
        tester.getRect(find.text('RIR 1')).right,
        lessThan(tester.getRect(find.text('TOP')).left),
      );
    });

    testWidgets('no RIR on the top set shows no RIR text', (tester) async {
      await tester.pumpWidget(
        row(_block([_set(1, kg: 100, top: true), _set(2, kg: 90, rir: 2)])),
      );
      expect(find.textContaining('RIR'), findsNothing);
      expect(find.text('TOP'), findsOneWidget);
    });

    testWidgets('the unflagged top is found by weight and reps', (
      tester,
    ) async {
      await tester.pumpWidget(
        row(
          _block([
            _set(1, kg: 80, rir: 4),
            _set(2, kg: 100, rir: 1),
          ]).withTop(100, 6),
        ),
      );
      expect(find.text('RIR 1'), findsOneWidget);
      expect(find.text('RIR 4'), findsNothing);
    });

    testWidgets('a PR row shows the RIR beside the PR badge', (tester) async {
      await tester.pumpWidget(
        row(_block([_set(1, rir: 2, top: true)], pr: true)),
      );
      expect(find.text('RIR 2'), findsOneWidget);
      expect(find.text('PR'), findsOneWidget);
    });

    testWidgets('the spoken line includes the RIR', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(row(_block([_set(1, rir: 2, top: true)])));
      expect(tester.getSemantics(rirTags()).label, contains('RIR 2'));
      handle.dispose();
    });
  });

  for (final width in const [320.0, 412.0]) {
    for (final code in const ['en', 'de', 'it']) {
      for (final catalog in const [true, false]) {
        testWidgets(
          'the ${catalog ? 'catalog' : 'classic'} row holds at ${width}dp, 2x, '
          '$code',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            tester.platformDispatcher.textScaleFactorTestValue = 2.0;
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            await tester.pumpWidget(
              row(
                _block([
                  _set(1, catalog: catalog, rir: 12, top: true, kg: 142.5),
                  _set(2, catalog: catalog, rir: 3, reps: 10),
                ], pr: true),
                name: longExercise,
                locale: Locale(code),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(rirTags(), findsWidgets);
            // Every tag stays on screen, inside the row's padding.
            for (final tag in rirTags().evaluate()) {
              final rect = tester.getRect(find.byWidget(tag.widget));
              expect(rect.left, greaterThanOrEqualTo(16));
              expect(rect.right, lessThanOrEqualTo(width - 16));
            }
            expectNoSplitWords(tester, where: '$width $code catalog=$catalog');
          },
        );
      }
    }
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('the summary holds at 320dp and ${scale}x', (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: scale);
      await tester.pumpWidget(
        harness.wrap(const SessionSummaryScreen(sessionId: 's0')),
      );
      await pumpUntilFound(tester, find.text(longExercise));
      await settleReal(tester, ticks: 10);
      // Each classic row shows its top set's RIR (the seed logs RIR 1, 2, 0).
      expect(find.text('RIR 1'), findsWidgets);
      expect(find.text('RIR 0'), findsWidgets);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(SessionSummaryScreen),
        'Summary 320dp ${scale}x',
      );
      await harness.unmount(tester);
    });
  }
}

extension on ExerciseBlockData {
  /// The same block with its top set named by weight and reps alone.
  ExerciseBlockData withTop(double kg, int reps) => ExerciseBlockData(
    exerciseId: exerciseId,
    sets: sets,
    topWeight: kg,
    topReps: reps,
    isPr: isPr,
  );
}
