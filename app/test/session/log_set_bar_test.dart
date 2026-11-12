import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/live_set_card.dart';
import 'package:alkion/session/log_set_bar.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/ruler_picker.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';

import '../support/l10n_harness.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';

const _ex = Exercise(
  id: 'lp',
  name: 'Leg press',
  slug: 'lp',
  muscleGroup: 'quads',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

BlockState _block(List<SetState> warm, List<SetState> work) => BlockState(
  exercise: _ex,
  resolved: const ResolvedSlot(
    exercise: _ex,
    workSets: 3,
    warmupSets: 1,
    repLow: 6,
    repHigh: 8,
    rirLow: 1,
    rirHigh: 1,
  ),
  warmupSets: warm,
  workingSets: work,
  expanded: true,
);

SetState _s(String id, {bool warmup = false, bool done = false}) => SetState(
  id: id,
  weightKg: warmup ? 70 : 140,
  reps: warmup ? 8 : 6,
  rir: warmup ? null : 1,
  isWarmup: warmup,
  done: done,
);

/// A catalog set in a load-and-reps context; [load] empty leaves it without
/// that value.
SetState _typed(
  String id, {
  bool warmup = false,
  bool done = false,
  String load = '18',
}) => SetState(
  id: id,
  weightKg: 0,
  reps: 0,
  rir: null,
  isWarmup: warmup,
  done: done,
  catalog: CatalogSetEvidence(
    selection: CatalogSelectionEvidence(
      exerciseId: _ex.id,
      contextId: 'machine-a',
      contextRevision: 1,
      profile: CatalogMeasurementProfileEvidence.forKey('load_reps'),
      displayLabel: 'Synthetic leg press',
      contextLabel: 'Machine A',
      resistanceSource: 'external',
      loadConvention: 'reported_mass',
    ),
    metrics: {
      'reported_load': CatalogMetricEvidence.fromInput(
        load,
        metric: 'reported_load',
        unit: 'kg',
      ),
      'repetitions': CatalogMetricEvidence.fromInput(
        '12',
        metric: 'repetitions',
        unit: 'count',
      ),
    },
  ),
);

void main() {
  setUpAll(preloadAppFonts);
  final unit = UnitService();
  final l = lookupAppLocalizations(const Locale('en'));

  for (final brightness in Brightness.values) {
    for (final code in ['en', 'de', 'es', 'it']) {
      for (final kind in ['set', 'warm-up', 'catalog']) {
        testWidgets(
          'the log action stays readable and logs once at 320dp 2x $kind $code ${brightness.name}',
          (tester) async {
            final s = switch (kind) {
              'warm-up' => _s('live', warmup: true),
              'catalog' => _typed('live'),
              _ => _s('live'),
            };
            final live = s.isWarmup
                ? (block: _block([s], []), set: s)
                : (block: _block([], [s]), set: s);
            final local = lookupAppLocalizations(Locale(code));
            final label = LogSetBar.labelFor(local, unit, live, false)!;
            expect(
              label,
              s.isWarmup ? local.sessionLogWarmup : local.sessionLogSet(1),
            );
            var logs = 0;
            await tester.pumpWidget(
              wrapL10n(
                Theme(
                  data: buildTheme(brightness, defaultWorkoutAccent),
                  child: MediaQuery(
                    data: const MediaQueryData(
                      textScaler: TextScaler.linear(2),
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        width: 320,
                        child: LogSetBar(
                          live: live,
                          canFinish: false,
                          unit: unit,
                          onLog: () => logs++,
                          onFinish: () {},
                        ),
                      ),
                    ),
                  ),
                ),
                locale: Locale(code),
              ),
            );
            final bar = find.byKey(const Key('log-set-bar'));
            expect(tester.getSize(bar).height, greaterThanOrEqualTo(48));
            final paragraph = tester.renderObject<RenderParagraph>(
              find.text(label),
            );
            expect(paragraph.didExceedMaxLines, isFalse);
            expect(paragraph.text.toPlainText(), label);
            expect(tester.getSemantics(bar).label, label);
            expectNoSplitWords(tester);
            final button = tester.widget<FilledButton>(bar);
            final background = button.style!.backgroundColor!.resolve({})!;
            final foreground = button.style!.foregroundColor!.resolve({})!;
            final a = background.computeLuminance(),
                b = foreground.computeLuminance();
            expect(
              a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05),
              greaterThanOrEqualTo(4.5),
            );
            await tester.tap(bar);
            expect(logs, 1);
            if (kind == 'set') {
              expect(s.weightKg, 140);
              expect(s.reps, 6);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  group('labelFor', () {
    final w = _s('w', warmup: true);
    final a1 = _s('a1', done: true);
    final a2 = _s('a2');
    final b = _block([w], [a1, a2]);

    test('pending working set', () {
      expect(
        LogSetBar.labelFor(l, unit, (block: b, set: a2), true),
        'Log set 2',
      );
    });
    test('pending warm-up', () {
      expect(
        LogSetBar.labelFor(l, unit, (block: b, set: w), false),
        'Log warm-up',
      );
    });
    test('catalog sets read like classic ones, with or without values', () {
      final tw = _typed('tw', warmup: true);
      final t1 = _typed('t1', done: true);
      final t2 = _typed('t2');
      final empty = _typed('t3', load: '');
      final typed = _block([tw], [t1, t2, empty]);
      String? label(SetState s) =>
          LogSetBar.labelFor(l, unit, (block: typed, set: s), true);
      expect(label(t2), 'Log set 2');
      expect(label(empty), 'Log set 3');
      expect(label(tw), 'Log warm-up');
      expect(label(t1), 'Update set 1');
    });
    test('logged working set being corrected', () {
      expect(
        LogSetBar.labelFor(l, unit, (block: b, set: a1), true),
        'Update set 1',
      );
    });
    test('logged warm-up being corrected', () {
      final dw = _s('dw', warmup: true, done: true);
      expect(
        LogSetBar.labelFor(l, unit, (block: _block([dw], []), set: dw), true),
        'Update warm-up',
      );
    });
    test('nothing live: finish when possible, hidden otherwise', () {
      expect(LogSetBar.labelFor(l, unit, null, true), 'Finish workout');
      expect(LogSetBar.labelFor(l, unit, null, false), isNull);
    });
  });

  testWidgets('the bar is 56dp tall, labelled, and logs on tap', (
    tester,
  ) async {
    final s = _s('a1');
    var logs = 0;
    await tester.pumpWidget(
      wrapL10n(
        Align(
          alignment: Alignment.bottomCenter,
          child: LogSetBar(
            live: (block: _block([], [s]), set: s),
            canFinish: false,
            unit: unit,
            onLog: () => logs++,
            onFinish: () {},
          ),
        ),
      ),
    );
    final bar = find.byKey(const Key('log-set-bar'));
    expect(tester.getSize(bar).height, 56);
    expect(find.text('Log set 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Log set 1'), findsOneWidget);
    expect(
      tester.getSemantics(bar),
      matchesSemantics(
        label: 'Log set 1',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(bar);
    expect(logs, 1);
  });

  testWidgets('renders nothing when there is nothing to log or finish', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapL10n(
        LogSetBar(
          live: null,
          canFinish: false,
          unit: unit,
          onLog: () {},
          onFinish: () {},
        ),
      ),
    );
    expect(find.byKey(const Key('log-set-bar')), findsNothing);
  });

  testWidgets('with nothing live it finishes', (tester) async {
    var finishes = 0;
    await tester.pumpWidget(
      wrapL10n(
        Align(
          alignment: Alignment.bottomCenter,
          child: LogSetBar(
            live: null,
            canFinish: true,
            unit: unit,
            onLog: () {},
            onFinish: () => finishes++,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('log-set-bar')));
    expect(finishes, 1);
  });

  testWidgets('the bar logs exactly what the weight ruler shows', (
    tester,
  ) async {
    final s = _s('a1');
    final block = _block([], [s]);
    final c = ActiveSessionController()
      ..seedForTest(
        SessionDraft(
          templateId: null,
          name: 'W',
          focus: '',
          startedAt: DateTime(2026, 9, 24),
          blocks: [block],
        ),
      );
    await tester.pumpWidget(
      wrapL10n(
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              LiveSetCard(
                set: s,
                exercise: _ex,
                workIndex: 1,
                lastTop: null,
                unit: unit,
                onChanged: () => setState(c.markChanged),
                onMarkNotDone: () {},
              ),
              const Spacer(),
              LogSetBar(
                live: c.liveSet,
                canFinish: c.canFinish,
                unit: unit,
                onLog: () => setState(() => c.logLiveSet()),
                onFinish: () {},
              ),
            ],
          ),
        ),
      ),
    );
    // ~180 dp/s: comfortably above the 120 dp/s zoom-in threshold and below
    // the 300 dp/s fling dead zone, so it stays a plain 2-step coarse swipe.
    await tester.timedDrag(
      find.byKey(const Key('live-weight')),
      const Offset(-2 * RulerPicker.defaultItemExtent, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    // The label names the set; the value is on the card.
    expect(find.text('Log set 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('log-set-bar')));
    await tester.pump();
    expect(s.weightKg, 142);
    expect(s.done, isTrue);
  });

  testWidgets(
    'tapping the bar mid-fling logs the value shown and stops the tape',
    (tester) async {
      final s = _s('a1');
      final block = _block([], [s]);
      final c = ActiveSessionController()
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'W',
            focus: '',
            startedAt: DateTime(2026, 9, 24),
            blocks: [block],
          ),
        );
      await tester.pumpWidget(
        wrapL10n(
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                LiveSetCard(
                  set: s,
                  exercise: _ex,
                  workIndex: 1,
                  lastTop: null,
                  unit: unit,
                  onChanged: () => setState(c.markChanged),
                  onMarkNotDone: () {},
                ),
                const Spacer(),
                LogSetBar(
                  live: c.liveSet,
                  canFinish: c.canFinish,
                  unit: unit,
                  onLog: () => setState(() => c.logLiveSet()),
                  onFinish: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.fling(
        find.byKey(const Key('live-weight')),
        const Offset(-150, 0),
        3000,
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final shown = s.weightKg;
      await tester.tap(find.byKey(const Key('log-set-bar')));
      await tester.pumpAndSettle();
      expect(s.done, isTrue);
      expect(
        s.weightKg,
        shown,
        reason: 'the fling kept writing after the set was logged',
      );
    },
  );

  testWidgets('a long German label ellipsises on a narrow phone', (
    tester,
  ) async {
    final s = _s('a1');
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: wrapL10n(
          Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 320,
              child: LogSetBar(
                live: (block: _block([], [s]), set: s),
                canFinish: false,
                unit: unit,
                onLog: () {},
                onFinish: () {},
              ),
            ),
          ),
          locale: const Locale('de'),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
