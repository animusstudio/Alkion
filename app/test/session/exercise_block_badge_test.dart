import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/exercise_block.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/l10n/app_localizations.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('the completion badge fits "2/3" whole at 2.0x', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final exercise = Exercise(
      id: 'e1',
      name: 'Bench Press',
      slug: 'bench',
      muscleGroup: 'chest',
      compound: true,
      plateStepKg: 2.5,
      isTemplate: false,
    );
    SetState s(String id, bool done) => SetState(
      id: id,
      weightKg: 60,
      reps: 8,
      rir: 1,
      isWarmup: false,
      done: done,
    );
    final block = BlockState(
      exercise: exercise,
      resolved: ResolvedSlot(
        exercise: exercise,
        workSets: 3,
        warmupSets: 0,
        repLow: 8,
        repHigh: 10,
        rirLow: 1,
        rirHigh: 2,
      ),
      warmupSets: [],
      workingSets: [s('s1', true), s('s2', true), s('s3', false)],
      expanded: false,
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(412, 900),
          textScaler: TextScaler.linear(2.0),
        ),
        child: wrapL10n(
          SingleChildScrollView(
            child: ExerciseBlock(
              block: block,
              unit: UnitService(),
              liveSetId: null,
              rirPromptSetId: null,
              onFocusSet: (_, __) {},
              onSetChanged: (_, __) {},
              onRir: (_, __, ___) {},
              onMarkNotDone: (_, __) {},
              onMenu: (_) {},
            ),
          ),
        ),
      ),
    );
    final text = find.text('2/3');
    final p = tester.renderObject<RenderParagraph>(text);
    expect(
      p.size.width,
      greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.01),
      reason: 'the badge clips its count',
    );
    expectOneLine(tester, text);
    final badge = tester.getSize(find.byKey(const ValueKey('block-badge-e1')));
    expect(badge.width, greaterThanOrEqualTo(40));
    expect(badge.height, greaterThanOrEqualTo(40));
    expect(tester.takeException(), isNull);
  });

  // Round 2 (A5): the all-done check is one of the live page's four accent
  // marks; the running count stays neutral.
  for (final brightness in Brightness.values) {
    WorkoutTokens tokensFor(Color accent) => brightness == Brightness.dark
        ? WorkoutTokens.dark(accent)
        : WorkoutTokens.light(accent);

    testWidgets('the all-done check uses the accent and the count stays '
        'neutral in ${brightness.name}', (tester) async {
      const exercise = Exercise(
        id: 'e1',
        name: 'Bench Press',
        slug: 'bench',
        muscleGroup: 'chest',
        compound: true,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      SetState s(String id, bool done) => SetState(
        id: id,
        weightKg: 60,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: done,
      );
      Widget host(bool lastDone) => MaterialApp(
        theme: buildTheme(brightness, accents[0]),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExerciseBlock(
              block: BlockState(
                exercise: exercise,
                resolved: const ResolvedSlot(
                  exercise: exercise,
                  workSets: 2,
                  warmupSets: 0,
                  repLow: 8,
                  repHigh: 10,
                  rirLow: 1,
                  rirHigh: 2,
                ),
                warmupSets: [],
                workingSets: [s('s1', true), s('s2', lastDone)],
                expanded: false,
              ),
              unit: UnitService(),
              liveSetId: null,
              rirPromptSetId: null,
              onFocusSet: (_, __) {},
              onSetChanged: (_, __) {},
              onRir: (_, __, ___) {},
              onMarkNotDone: (_, __) {},
              onMenu: (_) {},
            ),
          ),
        ),
      );
      final tokens = tokensFor(accents[0]);
      final badge = find.byKey(const ValueKey('block-badge-e1'));

      await tester.pumpWidget(host(false));
      expect(
        tester
            .widget<Text>(
              find.descendant(of: badge, matching: find.text('1/2')),
            )
            .style
            ?.color,
        tokens.dim,
      );

      await tester.pumpWidget(host(true));
      final check = tester.widget<AlkionIcon>(
        find.descendant(of: badge, matching: find.byType(AlkionIcon)),
      );
      expect(check.glyph, AlkionGlyph.check);
      expect(check.color, tokens.accentText);
      final fill = tester.widget<Container>(badge).decoration! as BoxDecoration;
      expect(fill.color, tokens.surface2);
    });

    test('every accent check reads at 3:1 on the badge and block in '
        '${brightness.name}', () {
      for (final accent in accents) {
        final t = tokensFor(accent);
        for (final ground in [t.surface2, t.surface]) {
          expect(
            contrastRatio(t.accentText, ground),
            greaterThanOrEqualTo(3),
            reason: '$accent on $ground',
          );
        }
      }
    });
  }
}
