import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/live_set_card.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/widgets/ruler_picker.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/rir_expect.dart';

const _ex = Exercise(
  id: 'lp',
  name: 'Leg press',
  slug: 'lp',
  muscleGroup: 'quads',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

SetState _s({bool done = false, bool warmup = false}) => SetState(
  id: 's',
  weightKg: 140,
  reps: 6,
  rir: warmup ? null : 1,
  isWarmup: warmup,
  done: done,
);

void main() {
  // Real metrics: the RIR row's layout depends on the caption's width.
  setUpAll(preloadAppFonts);

  late int changes;
  late int unlogs;
  setUp(() {
    changes = 0;
    unlogs = 0;
  });

  Widget card(
    SetState s, {
    int idx = 2,
    ({double weight, int reps, String date})? last,
  }) => LiveSetCard(
    set: s,
    exercise: _ex,
    workIndex: s.isWarmup ? -1 : idx,
    lastTop: last,
    unit: UnitService(),
    onChanged: () => changes++,
    onMarkNotDone: () => unlogs++,
  );

  Widget host(
    Widget child, {
    Locale locale = const Locale('en'),
    double width = 260,
  }) => wrapL10n(
    SingleChildScrollView(
      child: SizedBox(width: width, child: child),
    ),
    locale: locale,
  );

  testWidgets('labels: pending set, warm-up, logged', (tester) async {
    await tester.pumpWidget(host(card(_s())));
    expect(find.text('SET 2'), findsOneWidget);
    await tester.pumpWidget(host(card(_s(warmup: true))));
    expect(find.text('WARM-UP'), findsOneWidget);
    await tester.pumpWidget(host(card(_s(done: true), idx: 1)));
    expect(find.text('SET 1 · LOGGED'), findsOneWidget);
  });

  Future<void> swipe(WidgetTester tester, Key ruler, int steps) async {
    await tester.timedDrag(
      find.byKey(ruler),
      Offset(-steps * RulerPicker.defaultItemExtent, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
  }

  // The weight ruler's coarse step: fast and short enough to stay well above
  // the 120 dp/s zoom-in threshold and below the 300 dp/s fling dead zone.
  Future<void> coarseSwipeWeight(WidgetTester tester, int steps) async {
    await tester.timedDrag(
      find.byKey(const Key('live-weight')),
      Offset(-steps * RulerPicker.defaultItemExtent, 0),
      Duration(milliseconds: 400 * steps.abs()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'swiping the weight ruler moves in whole-kilo steps, not the plate step',
    (tester) async {
      final s = _s(); // the exercise's plate step is 2.5 kg
      await tester.pumpWidget(host(card(s)));
      await coarseSwipeWeight(tester, 2);
      expect(s.weightKg, 142);
      expect(changes, greaterThanOrEqualTo(1));
    },
  );

  testWidgets('in lb the weight ruler steps five pounds at a time', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final lb = UnitService()..setUnit(Unit.lb);
    // Start exactly on the coarse lb grid (220 lb), so the ruler rests
    // coarse and a single-step swipe is unambiguous.
    final s = SetState(
      id: 's',
      weightKg: UnitService.toKg(220, Unit.lb),
      reps: 6,
      rir: 1,
      isWarmup: false,
      done: false,
    );
    await tester.pumpWidget(
      host(
        LiveSetCard(
          set: s,
          exercise: _ex,
          workIndex: 1,
          lastTop: null,
          unit: lb,
          onChanged: () => changes++,
          onMarkNotDone: () {},
        ),
      ),
    );
    await coarseSwipeWeight(tester, -1);
    expect(s.weightKg, closeTo(UnitService.toKg(220 - 5, Unit.lb), 0.01));
    expect(lb.fmtWt(s.weightKg), '215'); // 220 lb → 215 lb
  });

  testWidgets('swiping the reps ruler right lowers reps', (tester) async {
    final s = _s();
    await tester.pumpWidget(host(card(s)));
    await swipe(tester, const Key('live-reps'), -2);
    expect(s.reps, 4);
  });

  testWidgets('the rulers are labelled sliders for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(card(_s())));
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Weight, kg'))
          .flagsCollection
          .isSlider,
      isTrue,
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Reps'))
          .flagsCollection
          .isSlider,
      isTrue,
    );
    handle.dispose();
  });

  testWidgets(
    'tapping the weight opens typed entry and commits the typed value',
    (tester) async {
      final s = _s();
      await tester.pumpWidget(host(card(s)));
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
      expect(s.weightKg, 151.5);
      expect(changes, 1);
    },
  );

  testWidgets('an untouched typed entry changes nothing', (tester) async {
    final s = _s();
    await tester.pumpWidget(host(card(s)));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('live-reps')),
        matching: find.byKey(const Key('ruler-centre')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('number-entry-done')));
    await tester.pumpAndSettle();
    expect(s.reps, 6);
    expect(changes, 0);
  });

  testWidgets('an untouched typed weight in lb does not rewrite the kg value', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final lb = UnitService()..setUnit(Unit.lb);
    final s = SetState(
      id: 's',
      weightKg: 100,
      reps: 6,
      rir: 1,
      isWarmup: false,
      done: false,
    );
    await tester.pumpWidget(
      host(
        LiveSetCard(
          set: s,
          exercise: _ex,
          workIndex: 1,
          lastTop: null,
          unit: lb,
          onChanged: () => changes++,
          onMarkNotDone: () {},
        ),
      ),
    );
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
    expect(s.weightKg, 100);
    expect(changes, 0);
  });

  testWidgets('a logged working set can still correct its RIR', (tester) async {
    final s = _s(done: true);
    await tester.pumpWidget(host(card(s)));
    expect(tester.getSize(find.byKey(const Key('rir-3'))).height, 48);
    await tester.tap(find.byKey(const Key('rir-3')));
    expect(s.rir, 3);
    expect(changes, 1);
  });

  // The card's width in a block on a 320dp and a 412dp phone (the list
  // padding, block border and sets padding take 58dp), and the chip rows
  // its RIR row must fall into there.
  for (final (width, scale, rows) in const [
    (262.0, 1.0, 2),
    (262.0, 2.0, 2),
    (354.0, 1.0, 1),
    (354.0, 2.0, 2),
  ]) {
    testWidgets(
      'every RIR chip is at least 48x48 at ${width.toInt()}dp / ${scale}x, '
      'in $rows row${rows == 1 ? '' : 's'}',
      (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width + 58, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: host(card(_s(done: true)), width: width),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(expectRirChipsAtLeast48(tester), rows);
      },
    );
  }

  testWidgets('in two rows the RIR caption sits level with the first', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(_s(done: true)), width: 262));
    await tester.pumpAndSettle();
    expect(expectRirChipsAtLeast48(tester), 2);
    expectCaptionOnFirstRirRow(tester, find.text('RIR'));
  });

  testWidgets('no RIR picker for a pending set or a logged warm-up', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(_s())));
    expect(find.byKey(const Key('rir-0')), findsNothing);
    await tester.pumpWidget(host(card(_s(done: true, warmup: true))));
    expect(find.byKey(const Key('rir-0')), findsNothing);
  });

  testWidgets('shows the last-session reference or no previous data', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        card(_s(), last: (weight: 140, reps: 9, date: isoDate(DateTime.now()))),
      ),
    );
    expect(find.text('last 140kg × 9 · today'), findsOneWidget);
    await tester.pumpWidget(host(card(_s())));
    expect(find.text('No previous data'), findsOneWidget);
  });

  testWidgets('mark-as-not-done shows only for a logged set and is 48dp tall', (
    tester,
  ) async {
    await tester.pumpWidget(host(card(_s())));
    expect(find.text('Mark as not done'), findsNothing);
    await tester.pumpWidget(host(card(_s(done: true))));
    final btn = find.byKey(const Key('live-mark-not-done'));
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(48));
    await tester.tap(btn);
    expect(unlogs, 1);
  });

  testWidgets('no overflow at 320dp / 1.3× (it)', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 900),
          textScaler: TextScaler.linear(1.3),
        ),
        child: host(
          card(
            _s(done: true),
            last: (weight: 142.5, reps: 12, date: '2026-09-01'),
          ),
          locale: const Locale('it'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
