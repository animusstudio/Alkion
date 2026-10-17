import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/ui/exercise_sheet.dart';

import '../support/l10n_harness.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';

const _bench = Exercise(
  id: 'bench',
  name: 'Bench Press',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

const _curl = Exercise(
  id: 'curl',
  name: 'Curl',
  slug: 'curl',
  muscleGroup: 'arms',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

/// Opens the sheet the same way callers do — via `showExerciseSheet` behind a
/// button — so the real modal route is exercised.
Widget host({required String? current, bool showBodyweight = true}) => wrapL10n(
  Builder(
    builder: (context) => ElevatedButton(
      key: const Key('open-sheet'),
      onPressed: () => showExerciseSheet(
        context,
        exercises: const [_bench, _curl],
        current: current,
        showBodyweight: showBodyweight,
      ),
      child: const Text('open'),
    ),
  ),
);

void main() {
  setUpAll(preloadAppFonts);
  testWidgets('the current exercise row shows a trailing check; others do not', (
    tester,
  ) async {
    await tester.pumpWidget(host(current: 'bench'));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    // Bench (current) row: a check icon, a neutral selected border and the selected
    // semantics flag.
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Bench Press'),
          matching: find.byType(GestureDetector),
        ),
        matching: find.byIcon(WIcons.check),
      ),
      findsOneWidget,
    );

    final selectedBorder = tester
        .element(find.text('Bench Press'))
        .tokens
        .lineStrong;
    expect(_rowBorderColor(tester, 'Bench Press'), selectedBorder);
    expect(_isSelected(tester, 'Bench Press'), isTrue);

    // Curl (not current) row: no check icon, no accent border.
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Curl'),
          matching: find.byType(GestureDetector),
        ),
        matching: find.byIcon(WIcons.check),
      ),
      findsNothing,
    );
    expect(_rowBorderColor(tester, 'Curl'), isNot(selectedBorder));
    expect(_isSelected(tester, 'Curl'), isFalse);
  });

  testWidgets('no leading compound dot is rendered', (tester) async {
    await tester.pumpWidget(host(current: null));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    // The old leading dot was a bare 6x6 circular Container with no
    // decoration image/child; assert no such shape decoration exists at all
    // by checking there is no Container with a BoxShape.circle decoration
    // among the row's direct children (the row itself uses no circular dot).
    final decoratedBoxes = tester.widgetList<Container>(find.byType(Container));
    final hasDot = decoratedBoxes.any((c) {
      final decoration = c.decoration;
      return decoration is BoxDecoration && decoration.shape == BoxShape.circle;
    });
    expect(hasDot, isFalse);
  });

  testWidgets(
    'the bodyweight tracking row counts as current when current is the bodyweight id',
    (tester) async {
      await tester.pumpWidget(host(current: kBodyweightSentinel));
      await tester.tap(find.byKey(const Key('open-sheet')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Bodyweight'),
            matching: find.byType(GestureDetector),
          ),
          matching: find.byIcon(WIcons.check),
        ),
        findsOneWidget,
      );
      final selectedBorder = tester
          .element(find.text('Bodyweight'))
          .tokens
          .lineStrong;
      expect(_rowBorderColor(tester, 'Bodyweight'), selectedBorder);
      expect(_isSelected(tester, 'Bodyweight'), isTrue);

      // Exercise rows are unmarked when the bodyweight row is current.
      for (final name in ['Bench Press', 'Curl']) {
        expect(_rowBorderColor(tester, name), isNot(selectedBorder));
        expect(_isSelected(tester, name), isFalse);
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text(name),
              matching: find.byType(GestureDetector),
            ),
            matching: find.byIcon(WIcons.check),
          ),
          findsNothing,
        );
      }
    },
  );
  for (final code in ['en', 'de', 'es', 'it']) {
    testWidgets(
      'picker actions remain reachable at 320dp 2x with keyboard in $code',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(2),
              viewInsets: EdgeInsets.only(bottom: 240),
            ),
            child: wrapL10n(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showExerciseSheet(
                    context,
                    exercises: const [_bench, _curl],
                    current: 'bench',
                  ),
                  child: const Text('open'),
                ),
              ),
              locale: Locale(code),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expectNoSplitWords(tester);
        final done = find.byType(TextButton).last;
        expect(tester.getSize(done).height, greaterThanOrEqualTo(48));
        expect(tester.getRect(done).bottom, lessThanOrEqualTo(480));
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(find.byType(DraggableScrollableSheet), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Clear empties the search field and restores the original exercise identities',
    (tester) async {
      String? picked;
      await tester.pumpWidget(
        wrapL10n(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showExerciseSheet(
                  context,
                  exercises: const [_bench, _curl],
                  current: 'bench',
                  showBodyweight: false,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.enterText(field, 'Bench');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'Bench');
      expect(find.text('Bench Press'), findsOneWidget);
      expect(find.text('Curl'), findsNothing);
      final focusedBeforeClear = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).focusNode,
        same(focusedBeforeClear),
      );
      expect(find.text('Bench Press'), findsOneWidget);
      expect(find.text('Curl'), findsOneWidget);
      expect(_isSelected(tester, 'Bench Press'), isTrue);
      await tester.tap(find.text('Curl'));
      await tester.pumpAndSettle();
      expect(picked, _curl.id);
      expect(tester.takeException(), isNull);
    },
  );
}

/// The border colour of the nearest bordered container around [text] — the
/// picker row itself.
Color _rowBorderColor(WidgetTester tester, String text) {
  final row = tester
      .widgetList<Container>(
        find.ancestor(of: find.text(text), matching: find.byType(Container)),
      )
      .firstWhere(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).border != null,
      );
  final border = (row.decoration! as BoxDecoration).border! as Border;
  return border.top.color;
}

/// Whether any semantics wrapper around [text] marks it selected.
bool _isSelected(WidgetTester tester, String text) => tester
    .widgetList<Semantics>(
      find.ancestor(of: find.text(text), matching: find.byType(Semantics)),
    )
    .any((s) => s.properties.selected == true);
