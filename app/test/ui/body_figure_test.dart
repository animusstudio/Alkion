import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/character_body.dart';
import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';

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
      'workload sheet has native counts and controls at 320dp 2x in $code',
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
        await tester.tap(find.text(l.bodyWorkload));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(CharacterBody), findsOneWidget);
        final body = tester.widget<CharacterBody>(find.byType(CharacterBody));
        expect(body.compact, isFalse);
        expect(find.text(l.bodyMapped(2)), findsOneWidget);
        expect(find.text(l.bodyUnmapped(1)), findsOneWidget);
        expect(find.text(l.bodyUnknownKind(1)), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('body-count-chest')))
              .data,
          '2',
        );
        for (final label in [l.bodyViewFront, l.bodyViewBack, l.bodyPause]) {
          final control = find.widgetWithText(TextButton, label);
          expect(tester.getSize(control).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
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
                height: 320,
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
    await tester.pumpWidget(wrapL10n(BodyWorkloadCounts(workload: empty)));
    expect(find.text('No working sets to map yet.'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('body-count-chest'))).data,
      '0',
    );
  });
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
  testWidgets('reduced motion is explicit and keeps manual view controls', (
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
    await tester.tap(find.text('Workout workload'));
    await tester.pumpAndSettle();
    expect(find.text('Pause rotation'), findsNothing);
    expect(find.text('Front'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
