import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
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

void main() {
  setUpAll(preloadAppFonts);
  final unit = UnitService();
  final l = lookupAppLocalizations(const Locale('en'));

  for (final brightness in Brightness.values) {
    for (final code in ['en', 'de', 'es', 'it']) {
      testWidgets(
        'the log action stays readable and logs once at 320dp 2x $code ${brightness.name}',
        (tester) async {
          final s = _s('live');
          final live = (block: _block([], [s]), set: s);
          final local = lookupAppLocalizations(Locale(code));
          final label = LogSetBar.labelFor(local, unit, live, false)!;
          var logs = 0;
          await tester.pumpWidget(
            wrapL10n(
              Theme(
                data: buildTheme(brightness, defaultWorkoutAccent),
                child: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
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
          expect(s.weightKg, 140);
          expect(s.reps, 6);
          expect(tester.takeException(), isNull);
        },
      );
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
        'Log set 2 · 140kg × 6',
      );
    });
    test('pending warm-up', () {
      expect(
        LogSetBar.labelFor(l, unit, (block: b, set: w), false),
        'Log warm-up · 70kg × 8',
      );
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
    expect(find.bySemanticsLabel('Log set 1 · 140kg × 6'), findsOneWidget);
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
    expect(find.text('Log set 1 · 142kg × 6'), findsOneWidget);
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
