import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:alkion/ui/workload_top_muscles.dart';
import 'package:alkion/widgets/glyph_loading.dart';
import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/body_sheet_expect.dart';
import '../support/icon_finders.dart';

WorkoutWorkload _workload() => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.planned,
  exercises: [
    const WorkloadExerciseInput(
      muscleGroup: 'chest',
      sets: [
        WorkloadSetInput(completed: false, isWarmup: false),
        WorkloadSetInput(completed: false, isWarmup: false),
      ],
    ),
    const WorkloadExerciseInput(
      muscleGroup: 'unknown',
      sets: [
        WorkloadSetInput(completed: false, isWarmup: false),
        WorkloadSetInput(completed: false, isWarmup: null),
      ],
    ),
  ],
);

WorkoutWorkload _legacy(Map<String, int> sets) => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.planned,
  exercises: [
    for (final entry in sets.entries)
      WorkloadExerciseInput(
        muscleGroup: entry.key,
        sets: [
          for (var i = 0; i < entry.value; i++)
            const WorkloadSetInput(completed: false, isWarmup: false),
        ],
      ),
  ],
);

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('character ink follows approved theme and live custom accents', (
    tester,
  ) async {
    Widget scene(Brightness brightness, Color accent) => wrapL10n(
      Theme(
        data: buildTheme(brightness, accent),
        child: Center(child: BodyFigure(workload: _workload())),
      ),
    );
    CharacterBody artwork() =>
        tester.widget<CharacterBody>(find.byType(CharacterBody));
    await tester.pumpWidget(scene(Brightness.light, defaultWorkoutAccent));
    await tester.pump();
    expect(artwork().accent, const Color(0xFFA82D00));
    final controller = artwork().controller;
    final scores = Map.of(artwork().scores);

    const customAccent = Color(0xFF5CC8FF);
    final customInk = WorkoutTokens.light(customAccent).accentText;
    expect(customInk, isNot(customAccent));
    await tester.pumpWidget(scene(Brightness.light, customAccent));
    await tester.pump();
    expect(artwork().accent, customInk);
    expect(artwork().controller, same(controller));
    expect(artwork().scores, scores);

    await tester.pumpWidget(scene(Brightness.dark, defaultWorkoutAccent));
    await tester.pump();
    expect(artwork().accent, defaultWorkoutAccent);
    expect(artwork().controller, same(controller));
    expect(artwork().scores, scores);
    await tester.pumpWidget(const SizedBox());
  });
  for (final code in ['en', 'de', 'es', 'it']) {
    testWidgets(
      'workload sheet keeps only body, legend and counts at 320dp 2x in $code',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final locale = Locale(code);
        final l = lookupAppLocalizations(locale);
        await tester.pumpWidget(
          wrapL10n(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: Center(child: BodyFigure(workload: _workload())),
              ),
            ),
            locale: locale,
          ),
        );
        await tester.pump();
        expect(find.text(l.bodyWorkloadEntry), findsOneWidget);
        await tester.tap(find.byKey(const Key('body-workload-entry')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(CharacterBody), findsOneWidget);
        final body = tester.widget<CharacterBody>(find.byType(CharacterBody));
        expect(body.compact, isFalse);
        expect(
          tester.getSize(find.byType(CharacterBody)).height,
          greaterThanOrEqualTo(420),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('body-count-chest')))
              .data,
          '2',
        );
        expectWorkloadSheetSections(tester, l, mode: l.bodyPlanned);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final brightness in Brightness.values) {
    testWidgets('workload entry is a 48dp pill speaking the sheet title '
        '(${brightness.name})', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        wrapL10n(
          Theme(
            data: buildTheme(brightness, defaultWorkoutAccent),
            child: Center(child: BodyFigure(workload: _workload())),
          ),
        ),
      );
      await tester.pump();
      final entry = find.byKey(const Key('body-workload-entry'));
      expect(tester.getSize(entry).height, 48);
      expect(
        tester.getSize(find.byType(BodyFigure)),
        Size(
          BodyFigure.largeWidth,
          BodyFigure.heightFor(BodyFigure.largeWidth),
        ),
      );
      for (final glyph in [AlkionGlyph.wholeBody, AlkionGlyph.chevronRight]) {
        expect(
          find.descendant(of: entry, matching: findGlyph(glyph)),
          findsOneWidget,
        );
      }
      expect(find.text('Workload'), findsOneWidget);
      expect(
        tester.getSemantics(entry),
        matchesSemantics(
          label: 'Workout workload',
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final reduced in [false, true]) {
    testWidgets('artwork drag owns horizontal pager gestures (reduced: $reduced)', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = reduced
          ? FakeAccessibilityFeatures.allOn
          : const FakeAccessibilityFeatures();
      addTearDown(
        () => tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(),
      );
      final pages = PageController();
      final scroll = ScrollController();
      addTearDown(pages.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        wrapL10n(
          ListView(
            controller: scroll,
            children: [
              SizedBox(
                height: 400,
                child: PageView(
                  controller: pages,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: BodyFigure(workload: _workload()),
                    ),
                    const Center(child: Text('Second split')),
                  ],
                ),
              ),
              const SizedBox(height: 1800),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      CharacterBody art() =>
          tester.widget<CharacterBody>(find.byType(CharacterBody));
      final compact = art().controller;
      expect(compact.paused, isFalse);
      await tester.drag(find.byType(CharacterBody), const Offset(-90, 0));
      await tester.pumpAndSettle();
      expect(compact.yaw, isNot(0));
      expect(compact.paused, isTrue);
      expect(pages.page, 0);
      expect(find.byType(BottomSheet), findsNothing);
      expect(art().compact, isTrue);

      // The horizontal artwork recognizer must yield vertical drags to the list.
      await tester.drag(find.byType(CharacterBody), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      scroll.jumpTo(0);
      await tester.pumpAndSettle();

      // A tap still opens detail; its drag uses the same native controller API.
      await tester.tap(find.byType(CharacterBody));
      await tester.pumpAndSettle();
      expect(art().compact, isFalse);
      final enlarged = art().controller;
      expect(enlarged.paused, isFalse);
      await tester.drag(find.byType(CharacterBody), const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(enlarged.yaw, greaterThan(0));
      expect(enlarged.paused, isTrue);
      expect(pages.page, 0);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Artwork style'), findsNothing);
      expect(find.text('Male artwork'), findsNothing);
      expect(find.text('Female artwork'), findsNothing);
      await tester.tap(find.byTooltip('Done'));
      await tester.pumpAndSettle();
      expect(art().compact, isTrue);

      // The split pager remains available when the drag starts outside artwork.
      final pagerBounds = tester.getRect(find.byType(PageView));
      await tester.dragFrom(
        Offset(pagerBounds.right - 40, pagerBounds.center.dy),
        Offset(-pagerBounds.width * .7, 0),
      );
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('loading and read failure never appear as zero counts', (
    tester,
  ) async {
    for (final workload in [
      WorkoutWorkload.loading(WorkoutWorkloadMode.saved),
      WorkoutWorkload.unavailable(WorkoutWorkloadMode.saved),
    ]) {
      await tester.pumpWidget(wrapL10n(BodyWorkloadCounts(workload: workload)));
      expect(find.byKey(const Key('body-workload-read-state')), findsOneWidget);
      expect(find.byKey(const ValueKey('body-count-chest')), findsNothing);
    }
  });
  testWidgets('empty custom remains neutral with real zero counts', (
    tester,
  ) async {
    final empty = calculateWorkoutWorkload(
      mode: WorkoutWorkloadMode.planned,
      exercises: const [],
    );
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(child: BodyWorkloadCounts(workload: empty)),
      ),
    );
    expect(find.text('No working sets to map yet.'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('body-count-chest'))).data,
      '0',
    );
  });
  for (final (locale, adductors, abductors) in [
    ('en', 'Adductors', 'Abductors'),
    ('it', 'Adduttori', 'Abduttori'),
    ('de', 'Adduktoren', 'Abduktoren'),
    ('es', 'Aductores', 'Abductores'),
  ]) {
    testWidgets('readable counts list all thirteen regions in $locale', (
      tester,
    ) async {
      final empty = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.planned,
        exercises: const [],
      );
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(child: BodyWorkloadCounts(workload: empty)),
          locale: Locale(locale),
        ),
      );
      expect(WorkloadMuscle.values, hasLength(13));
      for (final muscle in WorkloadMuscle.values) {
        expect(
          find.byKey(ValueKey('body-count-${muscle.name}')),
          findsOneWidget,
        );
      }
      expect(find.text(adductors), findsOneWidget);
      expect(find.text(abductors), findsOneWidget);
    });
  }
  testWidgets('route coverage and scroll viewport stop compact artwork', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          controller: scroll,
          child: Column(
            children: [
              BodyFigure(workload: _workload()),
              const SizedBox(height: 1800),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    CharacterBody art() =>
        tester.widget<CharacterBody>(find.byType(CharacterBody));
    expect(art().visible, isTrue);
    scroll.jumpTo(700);
    await tester.pumpAndSettle();
    expect(art().visible, isFalse);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(art().visible, isTrue);
    final context = tester.element(find.byType(BodyFigure));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Covered')),
      ),
    );
    await tester.pumpAndSettle();
    final covered = tester.widget<CharacterBody>(
      find.byType(CharacterBody, skipOffstage: false),
    );
    expect(covered.visible, isFalse);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(art().visible, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('reduced motion is explicit and the sheet has no view buttons', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(
      () => tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(),
    );
    await tester.pumpWidget(wrapL10n(BodyFigure(workload: _workload())));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CharacterBody>(find.byType(CharacterBody)).reducedMotion,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('body-workload-entry')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CharacterBody>(find.byType(CharacterBody)).reducedMotion,
      isTrue,
    );
    expect(find.text('Pause rotation'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Front'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Back'), findsNothing);
    expectWorkloadSheetSections(
      tester,
      lookupAppLocalizations(const Locale('en')),
      mode: 'Planned working sets',
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('exported counts and labels are the ones the sheet lists', (
    tester,
  ) async {
    final workload = _workload();
    final counts = workloadDisplayCounts(workload);
    expect(counts[WorkloadMuscle.chest]!.count, 2);
    late BuildContext context;
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: Builder(
            builder: (c) {
              context = c;
              return BodyWorkloadCounts(workload: workload);
            },
          ),
        ),
      ),
    );
    for (final muscle in WorkloadMuscle.values) {
      expect(
        tester
            .widget<Text>(find.byKey(ValueKey('body-count-${muscle.name}')))
            .data,
        '${counts[muscle]!.count}',
      );
      expect(find.text(workloadRegionLabel(context, muscle)), findsOneWidget);
    }
    expect(workloadRegionLabel(context, WorkloadMuscle.glutes), 'Glutes');
    expect(workloadRegionLabel(context, WorkloadMuscle.chest), 'Chest');
  });
  test('top muscles are highest first, ties in region order, zeros out', () {
    final workload = _legacy({'biceps': 2, 'back': 5, 'chest': 5, 'quads': 1});
    expect(topWorkloadMuscles(workload, 3), [
      (muscle: WorkloadMuscle.chest, count: 5),
      (muscle: WorkloadMuscle.back, count: 5),
      (muscle: WorkloadMuscle.biceps, count: 2),
    ]);
    expect(topWorkloadMuscles(workload, 10), hasLength(4));
    expect(topWorkloadMuscles(workload, 0), isEmpty);
    expect(topWorkloadMuscles(_legacy(const {}), 3), isEmpty);
    for (final pending in [
      WorkoutWorkload.loading(WorkoutWorkloadMode.planned),
      WorkoutWorkload.unavailable(WorkoutWorkloadMode.planned),
    ]) {
      expect(topWorkloadMuscles(pending, 3), isEmpty);
    }
  });
  testWidgets('top muscles list rows, and never reads loading as zero', (
    tester,
  ) async {
    final l = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(
      wrapL10n(WorkloadTopMuscles(workload: _legacy({'chest': 9, 'back': 4}))),
    );
    expect(find.byKey(const ValueKey('workload-top-chest')), findsOneWidget);
    expect(find.text('Chest'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.byKey(const ValueKey('workload-top-quads')), findsNothing);

    await tester.pumpWidget(
      wrapL10n(
        WorkloadTopMuscles(
          workload: WorkoutWorkload.loading(WorkoutWorkloadMode.planned),
        ),
      ),
    );
    expect(find.byType(GlyphSkeleton), findsOneWidget);
    expect(find.text('0'), findsNothing);

    for (final (workload, text) in [
      (
        WorkoutWorkload.unavailable(WorkoutWorkloadMode.planned),
        l.bodyReadUnavailable,
      ),
      (_legacy(const {}), l.bodyEmpty),
    ]) {
      await tester.pumpWidget(wrapL10n(WorkloadTopMuscles(workload: workload)));
      expect(find.text(text), findsOneWidget);
      expect(find.byKey(const Key('workload-top-muscles')), findsNothing);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
