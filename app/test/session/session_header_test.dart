import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_header.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/theme/alkion_icon.dart';

import '../support/l10n_harness.dart';
import '../support/icon_finders.dart';
import '../support/layout_expect.dart';

const _ex = Exercise(
  id: 'lc',
  name: 'Lying leg curl',
  slug: 'lc',
  muscleGroup: 'hamstrings',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

/// A catalog set in a load-and-reps context; an empty [load] or [reps]
/// leaves that value out.
SetState _typed(
  String id, {
  bool warmup = false,
  bool done = false,
  String load = '18',
  String reps = '12',
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
      displayLabel: 'Seated leg curl, single leg with ankle strap',
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
        reps,
        metric: 'repetitions',
        unit: 'count',
      ),
    },
  ),
);

BlockState _blockOf(List<SetState> warm, List<SetState> work) => BlockState(
  exercise: _ex,
  resolved: const ResolvedSlot(
    exercise: _ex,
    workSets: 1,
    warmupSets: 0,
    repLow: 8,
    repHigh: 10,
    rirLow: 1,
    rirHigh: 1,
  ),
  warmupSets: warm,
  workingSets: work,
  expanded: true,
);

final _draft = SessionDraft(
  templateId: 't',
  name: 'Lower B',
  focus: 'Posterior Chain',
  startedAt: DateTime(2026, 9, 24, 16),
  blocks: const [],
);

void main() {
  late int adds, skips, menus, mins;
  setUp(() => adds = skips = menus = mins = 0);

  Widget header({
    DateTime? restStart,
    int restTotal = 0,
    DateTime? restEndedAt,
    bool showRestRow = false,
    Locale locale = const Locale('en'),
    TextDirection direction = TextDirection.ltr,
    String nextLabel = 'Next · Lying leg curl · Set 1 · 40kg × 8',
  }) => wrapL10n(
    Directionality(
      textDirection: direction,
      child: SessionHeader(
        draft: _draft,
        elapsed: const Duration(minutes: 1, seconds: 2),
        doneWork: 1,
        totalWork: 14,
        prCount: 0,
        restStart: restStart,
        restTotal: restTotal,
        restEndedAt: restEndedAt,
        showRestRow: showRestRow,
        nextLabel: nextLabel,
        onMinimize: () => mins++,
        onMenu: () => menus++,
        onAdd30s: () => adds++,
        onSkip: () => skips++,
      ),
    ),
    locale: locale,
  );

  for (final direction in TextDirection.values) {
    testWidgets('minimize points down and keeps its target in $direction', (
      tester,
    ) async {
      await tester.pumpWidget(header(direction: direction));
      final button = find.byKey(const Key('session-minimize'));
      expect(
        find.descendant(
          of: button,
          matching: findGlyph(AlkionGlyph.chevronDown),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: button,
          matching: findGlyph(AlkionGlyph.chevronRight),
        ),
        findsNothing,
      );
      expect(tester.getSize(button), const Size(48, 48));
      await tester.tap(button);
      expect(mins, 1);
    });
  }

  testWidgets('before the first log: no rest row', (tester) async {
    await tester.pumpWidget(header());
    expect(find.text('REST'), findsNothing);
    expect(find.text('+30s'), findsNothing);
    expect(find.text('1:02'), findsOneWidget);
  });

  testWidgets('resting: countdown, next line and 48dp chips that fire', (
    tester,
  ) async {
    await tester.pumpWidget(header(restStart: DateTime.now(), restTotal: 90));
    expect(find.text('REST'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('rest-clock'))).data,
      '1:30',
    );
    expect(
      find.text('Next · Lying leg curl · Set 1 · 40kg × 8'),
      findsOneWidget,
    );
    final add = find.byKey(const Key('rest-add'));
    final skip = find.byKey(const Key('rest-skip'));
    expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(skip).height, greaterThanOrEqualTo(48));
    await tester.tap(add);
    await tester.tap(skip);
    expect((adds, skips), (1, 1));
  });

  testWidgets(
    'after rest: RESTED counts up from the end, chips keep their space but are gone',
    (tester) async {
      await tester.pumpWidget(
        header(
          showRestRow: true,
          restEndedAt: DateTime.now().subtract(const Duration(seconds: 84)),
        ),
      );
      expect(find.text('RESTED'), findsOneWidget);
      expect(find.text('1:24'), findsOneWidget);
      expect(
        find.text('Next · Lying leg curl · Set 1 · 40kg × 8'),
        findsOneWidget,
      );
      expect(find.text('+30s').hitTestable(), findsNothing);
      expect(find.bySemanticsLabel('+30s'), findsNothing);
    },
  );

  testWidgets('after rest with no known end: the label without a time', (
    tester,
  ) async {
    await tester.pumpWidget(header(showRestRow: true));
    expect(find.text('RESTED'), findsOneWidget);
    expect(find.textContaining(':'), findsOneWidget); // only the elapsed 1:02
  });

  testWidgets(
    "a finished countdown the controller hasn't stopped yet reads as rested from its end",
    (tester) async {
      await tester.pumpWidget(
        header(
          showRestRow: true,
          restStart: DateTime.now().subtract(const Duration(seconds: 100)),
          restTotal: 90,
        ),
      );
      expect(find.text('RESTED'), findsOneWidget);
      expect(find.text('0:10'), findsOneWidget);
    },
  );

  testWidgets('a future end clamps to 0:00; a very long rest caps at 99:59', (
    tester,
  ) async {
    await tester.pumpWidget(
      header(
        showRestRow: true,
        restEndedAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
    );
    expect(find.text('0:00'), findsOneWidget);
    await tester.pumpWidget(
      header(
        showRestRow: true,
        restEndedAt: DateTime.now().subtract(const Duration(hours: 3)),
      ),
    );
    expect(find.text('99:59'), findsOneWidget);
  });

  for (final width in const [412.0, 320.0]) {
    for (final scale in const [1.0, 2.0]) {
      for (final locale in const [
        Locale('en'),
        Locale('de'),
        Locale('es'),
        Locale('it'),
      ]) {
        testWidgets(
          'resting and rested are the same height at ${width}dp / $scale× ${locale.languageCode}',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            Future<double> heightOf(Widget h) async {
              await tester.pumpWidget(
                MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: h,
                ),
              );
              expect(tester.takeException(), isNull);
              expect(
                tester.getTopLeft(find.byKey(const Key('session-progress'))).dx,
                tester.getTopLeft(find.byKey(const Key('session-title'))).dx,
              );
              return tester.getSize(find.byType(SessionHeader)).height;
            }

            final resting = await heightOf(
              header(
                showRestRow: true,
                restStart: DateTime.now(),
                restTotal: 180,
                locale: locale,
              ),
            );
            final rested = await heightOf(
              header(
                showRestRow: true,
                restEndedAt: DateTime.now().subtract(
                  const Duration(seconds: 84),
                ),
                locale: locale,
              ),
            );
            final unknown = await heightOf(
              header(showRestRow: true, locale: locale),
            );
            expect(rested, resting);
            expect(unknown, resting);
          },
        );
      }
    }
  }

  testWidgets('menu and minimize are labelled 48dp buttons', (tester) async {
    await tester.pumpWidget(header());
    await tester.tap(find.bySemanticsLabel('Workout options'));
    await tester.tap(find.bySemanticsLabel('Minimize'));
    expect((menus, mins), (1, 1));
    expect(
      tester.getSize(find.byKey(const Key('session-menu'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('no overflow at 320dp / 1.3× (de) while resting', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: header(
          restStart: DateTime.now(),
          restTotal: 180,
          locale: const Locale('de'),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final skip = find.byKey(const Key('rest-skip'));
    expect(tester.getSize(skip).width, greaterThanOrEqualTo(56));
    expect(tester.getSize(skip).height, greaterThanOrEqualTo(48));
    final nextLine = find.text('Next · Lying leg curl · Set 1 · 40kg × 8');
    expect(tester.getSize(nextLine).width, greaterThanOrEqualTo(200));
  });

  testWidgets('392dp / 1.0× en: the next line gets its own full-width row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(392, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(392, 800)),
        child: header(restStart: DateTime.now(), restTotal: 90),
      ),
    );
    final next = find.text('Next · Lying leg curl · Set 1 · 40kg × 8');
    expect(tester.getSize(next).width, greaterThanOrEqualTo(300));
  });

  testWidgets(
    '392dp / 1.0× en: the rest chips hug their labels instead of filling the row',
    (tester) async {
      tester.view.physicalSize = const Size(392, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(392, 800)),
          child: header(restStart: DateTime.now(), restTotal: 90),
        ),
      );
      for (final key in const [Key('rest-add'), Key('rest-skip')]) {
        final size = tester.getSize(find.byKey(key));
        expect(size.width, inInclusiveRange(56, 100), reason: '$key');
        expect(size.height, 48, reason: '$key');
      }
    },
  );

  for (final width in const [360.0, 412.0]) {
    testWidgets(
      '${width}dp / 1.0× de: the Skip chip shows its whole label while resting',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(size: Size(width, 800)),
            child: header(
              restStart: DateTime.now(),
              restTotal: 90,
              locale: const Locale('de'),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        for (final key in const [Key('rest-add'), Key('rest-skip')]) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find
                .descendant(
                  of: find.byKey(key),
                  matching: find.byType(RichText),
                )
                .first,
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: '$key');
        }
      },
    );
  }

  testWidgets('412dp / 1.0× en: the rest clock is drawn at full size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(412, 800)),
        child: header(restStart: DateTime.now(), restTotal: 90),
      ),
    );
    final clock = find.byKey(const Key('rest-clock'));
    final laidOut = tester.getSize(clock);
    final drawn = tester.getRect(clock);
    expect(drawn.width, closeTo(laidOut.width, 0.01));
    expect(drawn.height, closeTo(laidOut.height, 0.01));
    // The chips still sit flush right, inside the 12dp end padding.
    expect(
      tester.getRect(find.byKey(const Key('rest-skip'))).right,
      closeTo(400, 0.01),
    );
  });

  testWidgets('remaining line and endpoint use the current rest total', (
    tester,
  ) async {
    final start = DateTime.now().subtract(const Duration(seconds: 36));
    Future<void> expectScale(
      int total,
      String endpoint,
      double fraction,
    ) async {
      await tester.pumpWidget(header(restStart: start, restTotal: total));
      expect(
        tester.widget<Text>(find.byKey(const Key('rest-total'))).data,
        endpoint,
      );
      final track = find.byKey(const Key('rest-remaining-track'));
      expect(tester.getSize(track).height, 2);
      final fill = tester.widget<FractionallySizedBox>(
        find.descendant(of: track, matching: find.byType(FractionallySizedBox)),
      );
      expect(fill.widthFactor, closeTo(fraction, 0.01));
      final semantics = tester.widget<Semantics>(
        find.byKey(const Key('rest-remaining-value')),
      );
      expect(
        semantics.properties.value,
        '${total == 120 ? '1:24' : '1:54'} / $endpoint',
      );
    }

    await expectScale(120, '2:00', 0.7);
    // Extending rest keeps the same origin and changes both the scale and
    // countdown; the accepted specimen's 120 seconds is never hard-coded.
    await expectScale(150, '2:30', 0.76);
  });

  testWidgets('outside rest the line retains completed set progress', (
    tester,
  ) async {
    await tester.pumpWidget(header());
    expect(find.byKey(const Key('rest-scale')), findsNothing);
    final fill = tester.widget<FractionallySizedBox>(
      find.descendant(
        of: find.byKey(const Key('rest-remaining-track')),
        matching: find.byType(FractionallySizedBox),
      ),
    );
    expect(fill.widthFactor, closeTo(1 / 14, 0.0001));
  });

  for (final code in const ['en', 'de', 'es', 'it']) {
    testWidgets('the Next row fits at 320dp / 2× $code with the exercise', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final l = lookupAppLocalizations(Locale(code));
      final s = _typed('t', warmup: true);
      final label = restNextLabel(l, UnitService(), (
        block: _blockOf([s], []),
        set: s,
      ));
      expect(label, contains('Seated leg curl'));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 900),
            textScaler: TextScaler.linear(2),
          ),
          child: header(
            showRestRow: true,
            restStart: DateTime.now(),
            restTotal: 90,
            locale: Locale(code),
            nextLabel: label,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(label), findsOneWidget);
      expect(find.bySemanticsLabel(label), findsOneWidget);
      expectNoSplitWords(tester);
    });
  }

  group('restNextLabel', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final unit = UnitService();
    SetState classic(
      String id, {
      double kg = 40,
      bool warmup = false,
      bool done = false,
    }) => SetState(
      id: id,
      weightKg: kg,
      reps: 8,
      rir: warmup ? null : 1,
      isWarmup: warmup,
      done: done,
    );

    test('the exercise leads while its block has no logged set', () {
      final s = classic('s');
      expect(
        restNextLabel(l, unit, (block: _blockOf([], [s]), set: s)),
        'Next · Lying leg curl · Set 1 · 40kg × 8',
      );
      final w = classic('w', kg: 20, warmup: true);
      expect(
        restNextLabel(l, unit, (block: _blockOf([w], []), set: w)),
        'Next · Lying leg curl · Warm-up · 20kg × 8',
      );
    });

    test('after a logged set in the block, only the set and values', () {
      final w = classic('w', kg: 20, warmup: true, done: true);
      final s = classic('s');
      expect(
        restNextLabel(l, unit, (block: _blockOf([w], [s]), set: s)),
        'Next · Set 1 · 40kg × 8',
      );
    });

    test('a classic set with unavailable values says so', () {
      final s = classic('s')..weightUnavailable = true;
      final done = classic('d', done: true);
      expect(
        restNextLabel(l, unit, (block: _blockOf([], [done, s]), set: s)),
        'Next · Set 2 · Values unavailable',
      );
    });

    test('catalog sets use the compact values and the same rule', () {
      final t1 = _typed('t1');
      expect(
        restNextLabel(l, unit, (block: _blockOf([], [t1]), set: t1)),
        'Next · Seated leg curl, single leg with ankle strap · Set 1 · '
        '18 kg × 12',
      );
      final done = _typed('d', done: true);
      final t2 = _typed('t2', load: '20.5');
      final warm = _typed('w', warmup: true, load: '10');
      final b = _blockOf([warm], [done, t2]);
      expect(
        restNextLabel(l, unit, (block: b, set: t2)),
        'Next · Set 2 · 20.5 kg × 12',
      );
      expect(
        restNextLabel(l, unit, (block: b, set: warm)),
        'Next · Warm-up · 10 kg × 12',
      );
    });

    test('a catalog set without values shows none', () {
      final done = _typed('d', done: true);
      final empty = _typed('e', load: '', reps: '');
      final repsOnly = _typed('r', load: '');
      final b = _blockOf([], [done, empty, repsOnly]);
      expect(restNextLabel(l, unit, (block: b, set: empty)), 'Next · Set 2');
      expect(
        restNextLabel(l, unit, (block: b, set: repsOnly)),
        'Next · Set 3 · 12 reps',
      );
    });

    test('nothing left: finish', () {
      expect(restNextLabel(l, unit, null), 'Next · Finish workout');
    });

    test(
      'while a logged set is open for correction, names the real next set',
      () {
        final s1 = classic('s1', done: true);
        final s2 = classic('s2', kg: 42.5);
        final c = ActiveSessionController()
          ..seedForTest(
            SessionDraft(
              templateId: null,
              name: 'W',
              focus: '',
              startedAt: DateTime(2026, 9, 29, 10),
              blocks: [
                _blockOf([], [s1, s2]),
              ],
            ),
          );
        c.focusSet(s1);
        expect(
          restNextLabel(l, unit, c.nextPendingSet),
          'Next · Set 2 · 42.5kg × 8',
        );
      },
    );
  });
}
