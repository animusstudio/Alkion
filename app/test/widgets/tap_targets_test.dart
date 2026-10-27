import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/shell/w_tab_bar.dart';
import 'package:alkion/widgets/split_card.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/widgets/delete_button.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:alkion/widgets/progress_widgets.dart';
import 'package:alkion/widgets/stepper.dart';

import '../support/l10n_harness.dart';

void main() {
  testWidgets('ChipSelect chip is at least 48 tall', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        ChipSelect<int>(
          items: const [0, 1, 2],
          selected: 0,
          onSelect: (_) {},
          labelOf: (i) => 'Item $i',
        ),
      ),
    );

    final size = tester.getSize(find.text('Item 0'));
    // The chip's hit area is its ConstrainedBox ancestor, not the Text itself
    // — measure the tappable GestureDetector instead.
    final gd = find.ancestor(
      of: find.text('Item 0'),
      matching: find.byType(GestureDetector),
    );
    final hitSize = tester.getSize(gd.first);
    expect(hitSize.height, greaterThanOrEqualTo(48));
    expect(size.height, lessThan(48)); // visual pill stays small
  });

  testWidgets('ChipSelect chips share a row and hug their label', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapL10n(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: ChipSelect<int>(
              items: const [0, 1, 2],
              selected: 0,
              onSelect: (_) {},
              labelOf: (i) => 'D$i',
            ),
          ),
        ),
      ),
    );
    Finder chip(int i) => find
        .ancestor(of: find.text('D$i'), matching: find.byType(GestureDetector))
        .first;
    // Stacked full-width chips was a shipped regression.
    expect(tester.getTopLeft(chip(1)).dy, tester.getTopLeft(chip(0)).dy);
    expect(tester.getTopLeft(chip(2)).dy, tester.getTopLeft(chip(0)).dy);
    expect(tester.getSize(chip(0)).width, lessThan(200));
  });

  testWidgets("Toggle's hit area is >= 48x48 and reports toggled", (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapL10n(
        Toggle(
          value: true,
          onChanged: (_) {},
          semanticLabel: 'Auto-check updates',
        ),
      ),
    );

    final gdFinder = find.byType(GestureDetector);
    final hitSize = tester.getSize(gdFinder);
    expect(hitSize.width, greaterThanOrEqualTo(48));
    expect(hitSize.height, greaterThanOrEqualTo(48));

    final semantics = tester.getSemantics(find.byType(Toggle));
    expect(semantics.flagsCollection.isToggled, Tristate.isTrue);
  });

  testWidgets("Toggle's visual pill stays 50x30 despite the larger hit area", (
    tester,
  ) async {
    await tester.pumpWidget(wrapL10n(Toggle(value: true, onChanged: (_) {})));

    final pill = find.byType(AnimatedContainer);
    expect(tester.getSize(pill), const Size(50, 30));
  });

  testWidgets('MetricTabs segments are at least 48 tall', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SizedBox(
          width: 360,
          child: MetricTabs(selected: 'top', onSelect: (_) {}),
        ),
      ),
    );

    final segment = find.byType(GestureDetector).first;
    expect(tester.getSize(segment).height, greaterThanOrEqualTo(48));
  });

  testWidgets('WDeleteButton is at least 48 tall', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        Builder(
          builder: (context) {
            return WDeleteButton(
              tokens: context.tokens,
              label: 'Delete',
              onTap: () {},
            );
          },
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(WDeleteButton)).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('all five destinations expose 48dp tap targets', (tester) async {
    final selected = <int>[];
    await tester.pumpWidget(
      wrapL10n(WTabBar(currentIndex: 0, onTab: selected.add)),
    );
    for (final index in [1, 2, 0, 3, 4]) {
      final target = find.byKey(ValueKey('destination-$index'));
      expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      expect(
        tester
            .getSemantics(target)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      await tester.tap(target);
    }
    expect(selected, [1, 2, 0, 3, 4]);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('Today card owns the 56dp Start action', (tester) async {
    var starts = 0;
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(
          child: SplitCard(
            days: const [],
            nextIndex: 0,
            onStart: (_) => starts++,
          ),
        ),
      ),
    );
    final start = find.byKey(const Key('today-start'));
    await tester.ensureVisible(start);
    expect(tester.getSize(start).height, greaterThanOrEqualTo(56));
    await tester.tap(start);
    expect(starts, 1);
  });

  testWidgets(
    'the stepper + and the Toggle expose a screen-reader tap action',
    (tester) async {
      await tester.pumpWidget(
        wrapL10n(
          Column(
            children: [
              WStepper(
                value: 10,
                step: 1,
                format: (v) => v.round().toString(),
                onChanged: (_) {},
              ),
              Toggle(value: true, onChanged: (_) {}),
            ],
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byKey(const Key('stepper-inc'))),
        matchesSemantics(hasTapAction: true, isButton: true),
      );
      expect(
        tester.getSemantics(find.byType(Toggle)),
        matchesSemantics(
          hasTapAction: true,
          hasToggledState: true,
          isToggled: true,
        ),
      );
    },
  );
}
