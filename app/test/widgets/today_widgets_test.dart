import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/widgets/stat_tile.dart';
import 'package:alkion/widgets/week_strip.dart';
import 'package:alkion/widgets/volume_bars.dart';

import '../support/l10n_harness.dart';

/// Pump [widget] inside the localized workout-theme harness so that
/// `context.tokens` and `AppLocalizations.of(context)` both resolve.
Future<void> pumpWithTheme(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(wrapL10n(SingleChildScrollView(child: widget)));
}

// ── WeekStrip ─────────────────────────────────────────────────────────────────

void main() {
  group('WeekStrip', () {
    const days = [
      (name: 'Upper A', weekday: 0, isNext: true, done: false),
      (name: 'Lower A', weekday: 1, isNext: false, done: true),
      (name: 'Upper B', weekday: 3, isNext: false, done: false),
      (name: 'Lower B', weekday: 4, isNext: false, done: false),
    ];

    testWidgets('renders NEXT label for the isNext chip', (tester) async {
      await pumpWithTheme(tester, const WeekStrip(days: days));

      // The NEXT label is a Text widget with exactly 'NEXT'.
      expect(find.text('NEXT'), findsOneWidget);
    });

    testWidgets('renders WIcons.check for a done chip', (tester) async {
      await pumpWithTheme(tester, const WeekStrip(days: days));

      // Lower A is done → expect a check Icon in the tree.
      expect(
        find.byWidgetPredicate((w) => w is Icon && w.icon == WIcons.check),
        findsOneWidget,
      );
    });

    testWidgets('does not render NEXT or check for idle chips', (tester) async {
      await pumpWithTheme(tester, const WeekStrip(days: days));

      // Only one NEXT, only one check.
      expect(find.text('NEXT'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Icon && w.icon == WIcons.check),
        findsOneWidget,
      );
    });

    testWidgets('keeps spaces in day names', (tester) async {
      await pumpWithTheme(tester, const WeekStrip(days: days));

      expect(find.text('Upper A'), findsOneWidget);
    });

    testWidgets(
      'without onSelect it behaves as before: no Custom chip, nothing tappable',
      (tester) async {
        await pumpWithTheme(tester, const WeekStrip(days: days));
        expect(find.bySemanticsLabel('Custom'), findsNothing);
      },
    );

    testWidgets(
      'tapping a chip selects that day; the Custom chip selects past the end',
      (tester) async {
        final picked = <int>[];
        await pumpWithTheme(
          tester,
          WeekStrip(days: days, selectedIndex: 0, onSelect: picked.add),
        );
        await tester.tap(find.text('Upper B'));
        await tester.tap(find.bySemanticsLabel('Custom'));
        expect(picked, [2, days.length]);
        expect(
          tester.getSize(find.byKey(const ValueKey('week-chip-2'))).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('week-chip-custom'))).width,
          greaterThanOrEqualTo(48),
        );
      },
    );

    testWidgets('the selected chip is filled; NEXT stays on the rotation day', (
      tester,
    ) async {
      await pumpWithTheme(
        tester,
        WeekStrip(days: days, selectedIndex: 2, onSelect: (_) {}),
      );
      final tokens = tester.element(find.byType(WeekStrip)).tokens;
      BoxDecoration deco(int i) =>
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byKey(ValueKey('week-chip-$i')),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(deco(2).color, tokens.surface2);
      expect(deco(0).color, tokens.surface);
      expect(
        find.text('NEXT'),
        findsOneWidget,
      ); // on Upper A (isNext), not selected
    });

    testWidgets(
      'a chip that is both isNext and done shows NEXT and the check icon',
      (tester) async {
        const mixed = [
          (name: 'Upper A', weekday: 0, isNext: true, done: true),
          (name: 'Lower A', weekday: 1, isNext: false, done: false),
        ];
        await pumpWithTheme(tester, const WeekStrip(days: mixed));

        expect(find.text('NEXT'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is Icon && w.icon == WIcons.check),
          findsOneWidget,
        );
      },
    );

    for (final lang in ['it', 'de']) {
      testWidgets(
        'six days fit a narrow phone at large text ($lang), with a done day that is next',
        (tester) async {
          tester.view.physicalSize = const Size(320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const six = [
            (name: 'Upper A', weekday: 0, isNext: true, done: true),
            (name: 'Lower A', weekday: 1, isNext: false, done: true),
            (name: 'Upper B', weekday: 2, isNext: false, done: false),
            (name: 'Lower B', weekday: 3, isNext: false, done: false),
            (name: 'Arms', weekday: 4, isNext: false, done: false),
            (name: 'Conditioning', weekday: 5, isNext: false, done: false),
          ];
          await tester.pumpWidget(
            MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 800),
                textScaler: TextScaler.linear(1.3),
              ),
              child: wrapL10n(
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: WeekStrip(
                    days: six,
                    selectedIndex: 0,
                    onSelect: (_) {},
                  ),
                ),
                locale: Locale(lang),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  // ── VolumeBars ───────────────────────────────────────────────────────────────

  group('VolumeBars', () {
    /// The app's dark-mode lime accent token for comparison.
    final darkTokens = WorkoutTokens.dark(accents[0]);

    const rows = [
      (muscle: 'quads', sets: 8, target: 16), // under target → lineStrong
      (muscle: 'back', sets: 14, target: 14), // on target    → accent
      (muscle: 'chest', sets: 13, target: 12), // over target  → accent
    ];

    testWidgets('uses lineStrong fill when sets < target', (tester) async {
      await pumpWithTheme(tester, const VolumeBars(rows: rows));

      // Find Containers whose decoration uses lineStrong as their color.
      // The fill bar is a Container with a BoxDecoration color.
      final muteContainers = tester.widgetList<Container>(
        find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final deco = w.decoration;
          if (deco is! BoxDecoration) return false;
          return deco.color == darkTokens.lineStrong;
        }),
      );
      expect(
        muteContainers.isNotEmpty,
        isTrue,
        reason: 'Expected at least one fill bar with lineStrong color',
      );
    });

    testWidgets('uses accent fill when sets >= target', (tester) async {
      await pumpWithTheme(tester, const VolumeBars(rows: rows));

      // There are 2 rows with sets >= target (back: 14/14, chest: 13/12).
      final accentContainers = tester.widgetList<Container>(
        find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final deco = w.decoration;
          if (deco is! BoxDecoration) return false;
          return deco.color == darkTokens.accent;
        }),
      );
      expect(
        accentContainers.length,
        greaterThanOrEqualTo(2),
        reason: 'Expected at least 2 fill bars with accent color',
      );
    });

    testWidgets('shows sets/target text for each row', (tester) async {
      await pumpWithTheme(tester, const VolumeBars(rows: rows));

      expect(find.text('8/16'), findsOneWidget);
      expect(find.text('14/14'), findsOneWidget);
      expect(find.text('13/12'), findsOneWidget);
    });

    testWidgets('value text is dim when under target, text-color when met', (
      tester,
    ) async {
      await pumpWithTheme(tester, const VolumeBars(rows: rows));

      // '8/16' is under target → dim color.
      final underText = tester.widget<Text>(find.text('8/16'));
      expect(underText.style?.color, darkTokens.dim);

      // '14/14' is on target → text color.
      final onText = tester.widget<Text>(find.text('14/14'));
      expect(onText.style?.color, darkTokens.text);
    });
  });

  // ── StatTile ─────────────────────────────────────────────────────────────────

  group('StatTile', () {
    testWidgets(
      'value texts line up across tiles when one label wraps (Italian, 1.3x)',
      (tester) async {
        // A narrow phone: the value row must also fit (it scales down).
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(1.3),
            ),
            child: wrapL10n(
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: StatTile(label: 'PESO', value: '82', unit: 'kg'),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        label: 'SERIE QUESTA SETTIMANA',
                        value: '12',
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: StatTile(label: 'PR', value: '3'),
                    ),
                  ],
                ),
              ),
              locale: const Locale('it'),
            ),
          ),
        );

        final yWeight = tester.getTopLeft(find.text('82')).dy;
        final ySets = tester.getTopLeft(find.text('12')).dy;
        final yPrs = tester.getTopLeft(find.text('3')).dy;
        expect(yWeight, ySets);
        expect(ySets, yPrs);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the PR subtitle shrinks instead of truncating (German, 1.3x)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(1.3),
            ),
            child: wrapL10n(
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: StatTile(
                        label: 'KÖRPERGEWICHT',
                        value: '82',
                        unit: 'kg',
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        label: 'SÄTZE DIESE WOCHE',
                        value: '12',
                        sub: 'wie Vorwoche',
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        label: 'PRS DIESE WOCHE',
                        value: '3',
                        sub: 'zuletzt 12 Sept.',
                        fitSub: true,
                      ),
                    ),
                  ],
                ),
              ),
              locale: const Locale('de'),
            ),
          ),
        );

        final sub = find.text('zuletzt 12 Sept.');
        expect(sub, findsOneWidget);
        final text = tester.widget<Text>(sub);
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        expect(text.maxLines, 1);
        // It is scaled into the tile, not clipped: the scaled width fits.
        final tile = find.ancestor(of: sub, matching: find.byType(StatTile));
        final subRect = tester.getRect(sub);
        expect(subRect.right, lessThanOrEqualTo(tester.getRect(tile).right));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
