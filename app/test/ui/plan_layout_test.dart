import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/targets_tab.dart';
import 'package:alkion/widgets/stepper.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/exercise_library_tab.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../alkion/domains/local_screen_harness.dart';

void main() {
  setUpAll(preloadAppFonts);

  group('Plan over a real database', () {
    final harness = ScreenHarness();
    tearDown(harness.close);

    // The day cards' exercise count, the "new training day" button and the
    // targets rows' muscle names all ran out of room at 320dp and 2.0x.
    for (final code in ['en', 'de', 'es', 'it']) {
      testWidgets('the split and targets hold at 320dp 2.0x $code', (
        tester,
      ) async {
        await harness.open(tester);
        setPhone(tester, width: 320, textScale: 2.0);
        final locale = Locale(code);
        await tester.pumpWidget(
          harness.wrap(const Scaffold(body: PlanScreen()), locale: locale),
        );
        await settleReal(tester);
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(PlanScreen),
          'Plan split $code',
        );
        await tester.tap(
          find
              .descendant(
                of: find.byType(PlanScreen),
                matching: find.text(
                  lookupAppLocalizations(locale).planTabTargets,
                ),
              )
              .first,
        );
        await settleReal(tester, ticks: 15);
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(PlanScreen),
          'Plan targets $code',
        );
        await harness.unmount(tester);
      });
    }
  });

  Future<void> pumpTargets(WidgetTester tester, double scale) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 900),
          textScaler: TextScaler.linear(scale),
        ),
        child: wrapL10n(TargetsList(targets: const {}, onChanged: (_, __) {})),
      ),
    );
  }

  testWidgets('a target row keeps its stepper beside the name at 1.0x', (
    tester,
  ) async {
    await pumpTargets(tester, 1.0);
    final name = tester.getRect(find.text('Hamstrings'));
    final stepper = tester.getRect(find.byType(WStepper).at(4));
    expect(stepper.left, greaterThan(name.right));
    expect(stepper.top, lessThan(name.bottom));
  });

  testWidgets('a target row puts its stepper under the name at 2.0x on 320dp', (
    tester,
  ) async {
    await pumpTargets(tester, 2.0);
    final label = find.text('Chest');
    final name = tester.getRect(label);
    final stepper = tester.getRect(find.byType(WStepper).first);
    expect(stepper.top, greaterThanOrEqualTo(name.bottom));
    expectOneLine(tester, label);
    expectNoSplitWords(tester);
    expect(tester.takeException(), isNull);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'shared plan controls scale and retain focus/contrast in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = TextEditingController(text: 'Bench press');
        addTearDown(controller.dispose);
        final theme = buildTheme(brightness, defaultWorkoutAccent);
        final tokens = theme.extension<WorkoutTokens>()!;
        var saved = false;
        await tester.pumpWidget(
          wrapL10n(
            Theme(
              data: theme,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Field(
                        label: 'Exercise name',
                        child: TextInput(controller: controller),
                      ),
                      PrimaryBtn(
                        'Save exercise',
                        enabled: true,
                        onTap: () => saved = true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        final input = find.byType(TextField);
        expect(tester.getSize(input).height, greaterThanOrEqualTo(48));
        await tester.tap(input);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
        );
        final border = tester
            .widget<TextField>(input)
            .decoration!
            .focusedBorder!;
        expect(border.borderSide.color, tokens.focus);
        expect(border.borderSide.width, 2);
        final button = tester.widget<FilledButton>(find.byType(FilledButton));
        final background = button.style!.backgroundColor!.resolve({});
        final foreground = button.style!.foregroundColor!.resolve({});
        expect(background, tokens.action);
        expect(
          contrastRatio(background!, foreground!),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          tester.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(48),
        );
        expectNoSplitWords(tester);
        await tester.tap(find.byType(FilledButton));
        expect(saved, isTrue);
        expect(controller.text, 'Bench press');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final code in ['de', 'it']) {
    for (final day in [true, false]) {
      testWidgets(
        '${day ? 'day' : 'exercise'} editor holds at 320dp 2x $code',
        (tester) async {
          final harness = ScreenHarness();
          addTearDown(harness.close);
          addTearDown(() => harness.unmount(tester));
          await harness.open(tester, withWorkoutHistory: true);
          setPhone(tester, width: 320, textScale: 2);
          final editor = day
              ? DayEditor(id: 'd1', onBack: () {})
              : ExerciseEditor(id: 'ex1', onBack: () {});
          await tester.pumpWidget(
            harness.wrap(Scaffold(body: editor), locale: Locale(code)),
          );
          await settleUntilFound(
            tester,
            find.byType(TextInput),
            where: 'loaded editor',
          );
          await expectLayoutHoldsWhileScrolling(
            tester,
            find.byType(day ? DayEditor : ExerciseEditor),
            'T5 editor $code',
          );
        },
      );
    }
  }

  testWidgets(
    'empty and populated catalog preserve the create and exercise identity paths',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      await harness.open(tester, seed: (_) async {}, withWorkoutHistory: true);
      String? selected;
      var creates = 0;
      await tester.pumpWidget(
        harness.wrap(
          Scaffold(
            body: LibraryTab(
              onOpenEditor: (id) {
                if (id == null) {
                  creates++;
                } else {
                  selected = id;
                }
              },
            ),
          ),
        ),
      );
      final l = lookupAppLocalizations(const Locale('en'));
      await settleUntilFound(
        tester,
        find.text(l.progressEmpty),
        where: 'empty catalog',
      );
      await tester.tap(find.text(l.planNewExercise));
      expect(creates, 1);
      await tester.runAsync(
        () => seedExercise(
          harness.localDatabase,
          'identity-preserved',
          'Synthetic bench',
        ),
      );
      await settleUntilFound(
        tester,
        find.text('Synthetic bench'),
        where: 'populated catalog',
      );
      expect(find.text(l.progressEmpty), findsNothing);
      await tester.tap(find.text('Synthetic bench'));
      expect(selected, 'identity-preserved');
      expect(tester.takeException(), isNull);
    },
  );
}
