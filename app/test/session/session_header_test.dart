import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_header.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/l10n_harness.dart';

const _ex = Exercise(
  id: 'lc',
  name: 'Lying leg curl',
  slug: 'lc',
  muscleGroup: 'hamstrings',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
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
  }) => wrapL10n(
    SessionHeader(
      draft: _draft,
      elapsed: const Duration(minutes: 1, seconds: 2),
      doneWork: 1,
      totalWork: 14,
      prCount: 0,
      restStart: restStart,
      restTotal: restTotal,
      restEndedAt: restEndedAt,
      showRestRow: showRestRow,
      nextLabel: 'Next · Lying leg curl · set 1 · 40kg × 8',
      onMinimize: () => mins++,
      onMenu: () => menus++,
      onAdd30s: () => adds++,
      onSkip: () => skips++,
    ),
    locale: locale,
  );

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
    expect(find.text('1:30'), findsOneWidget);
    expect(
      find.text('Next · Lying leg curl · set 1 · 40kg × 8'),
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
        find.text('Next · Lying leg curl · set 1 · 40kg × 8'),
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
      for (final locale in const [Locale('en'), Locale('it')]) {
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
    final nextLine = find.text('Next · Lying leg curl · set 1 · 40kg × 8');
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
    final next = find.text('Next · Lying leg curl · set 1 · 40kg × 8');
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
    final clock = find.text('1:30');
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

  group('restNextLabel', () {
    final l = lookupAppLocalizations(const Locale('en'));
    final unit = UnitService();
    BlockState block(List<SetState> warm, List<SetState> work) => BlockState(
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

    test('names the exercise, set and prescription', () {
      final s = SetState(
        id: 's',
        weightKg: 40,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      expect(
        restNextLabel(l, unit, (block: block([], [s]), set: s)),
        'Next · Lying leg curl · set 1 · 40kg × 8',
      );
    });
    test('warm-up variant', () {
      final w = SetState(
        id: 'w',
        weightKg: 20,
        reps: 8,
        rir: null,
        isWarmup: true,
        done: false,
      );
      expect(
        restNextLabel(l, unit, (block: block([w], []), set: w)),
        'Next · Lying leg curl · warm-up · 20kg × 8',
      );
    });
    test('nothing left: finish', () {
      expect(restNextLabel(l, unit, null), 'Next · Finish workout');
    });

    test(
      'while a logged set is open for correction, names the real next set',
      () {
        final s1 = SetState(
          id: 's1',
          weightKg: 40,
          reps: 8,
          rir: 1,
          isWarmup: false,
          done: true,
        );
        final s2 = SetState(
          id: 's2',
          weightKg: 42.5,
          reps: 8,
          rir: 1,
          isWarmup: false,
          done: false,
        );
        final c = ActiveSessionController()
          ..seedForTest(
            SessionDraft(
              templateId: null,
              name: 'W',
              focus: '',
              startedAt: DateTime(2026, 9, 29, 10),
              blocks: [
                block([], [s1, s2]),
              ],
            ),
          );
        c.focusSet(s1);
        expect(
          restNextLabel(l, unit, c.nextPendingSet),
          'Next · Lying leg curl · set 2 · 42.5kg × 8',
        );
      },
    );
  });
}
