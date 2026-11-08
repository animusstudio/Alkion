import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/volume_bars.dart';
import '../support/l10n_harness.dart';

Future<void> _pumpLive(
  WidgetTester tester,
  List<({String muscle, int sets, int target})> rows,
  List<({int live, int pending})> live,
) async {
  await tester.pumpWidget(wrapL10n(VolumeBars(rows: rows, live: live)));
  await tester.pumpAndSettle();
}

LiveSegmentsPainter _segments(WidgetTester tester, [int row = 0]) =>
    tester
            .widget<CustomPaint>(
              find
                  .descendant(
                    of: find.byKey(const Key('volume-live-segments')).at(row),
                    matching: find.byType(CustomPaint),
                  )
                  .first,
            )
            .painter!
        as LiveSegmentsPainter;

double _doneFill(WidgetTester tester, [int row = 0]) => tester
    .widget<FractionallySizedBox>(find.byType(FractionallySizedBox).at(row))
    .widthFactor!;

String _count(WidgetTester tester, [int row = 0]) => tester
    .widget<Text>(find.byKey(const Key('volume-count')).at(row))
    .textSpan!
    .toPlainText();

void main() {
  testWidgets('each bar fills against its OWN target, not the global max', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        home: const Scaffold(
          body: VolumeBars(
            rows: [
              (muscle: 'quads', sets: 8, target: 16), // 50% of its own target
              (muscle: 'back', sets: 14, target: 14), // 100%
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final factors = tester
        .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .map((w) => w.widthFactor)
        .toList();
    expect(factors[0], closeTo(0.5, 0.001));
    expect(factors[1], closeTo(1.0, 0.001));
  });

  testWidgets('over-target clamps to a full bar', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        home: const Scaffold(
          body: VolumeBars(rows: [(muscle: 'chest', sets: 20, target: 12)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final f = tester
        .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .widthFactor;
    expect(f, 1.0);
  });

  testWidgets('zero target does not divide by zero (empty bar)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        home: const Scaffold(
          body: VolumeBars(rows: [(muscle: 'x', sets: 5, target: 0)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final f = tester
        .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .widthFactor;
    expect(f, 0.0);
  });

  testWidgets('the target tick sits at the right end of the track', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, accents[0]),
        home: const Scaffold(
          body: VolumeBars(rows: [(muscle: 'chest', sets: 11, target: 12)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final track = tester.getRect(find.byKey(const Key('volume-track')));
    final tick = tester.getRect(find.byKey(const Key('volume-target-tick')));
    expect(tick.center.dx, closeTo(track.right, 1.0));
    expect(tick.height, greaterThan(track.height)); // overhangs the track
  });

  group('live mode', () {
    testWidgets('draws done, this-workout and planned segments in order', (
      tester,
    ) async {
      await _pumpLive(
        tester,
        [(muscle: 'chest', sets: 6, target: 12)],
        [(live: 3, pending: 3)],
      );
      expect(_doneFill(tester), closeTo(0.5, 0.001));
      final p = _segments(tester);
      expect(p.liveEnd, closeTo(0.75, 0.001));
      expect(p.plannedEnd, closeTo(1.0, 0.001));
      expect(find.byKey(const Key('volume-live-legend')), findsOneWidget);
      // Under target: the muted fill, its translucent tail the same colour.
      final tokens = Theme.of(
        tester.element(find.byType(VolumeBars)),
      ).extension<WorkoutTokens>()!;
      expect(p.color, tokens.lineStrong);
    });

    testWidgets('count reads done+live/target → planned', (tester) async {
      await _pumpLive(
        tester,
        [
          (muscle: 'chest', sets: 8, target: 12),
          (muscle: 'back', sets: 4, target: 10),
          (muscle: 'quads', sets: 5, target: 9),
          (muscle: 'calves', sets: 2, target: 6),
        ],
        [
          (live: 3, pending: 3),
          (live: 0, pending: 0),
          (live: 0, pending: 2),
          (live: 4, pending: 0),
        ],
      );
      expect(_count(tester, 0), '8+3/12 \u2192 14');
      // No live part keeps today's format.
      expect(_count(tester, 1), '4/10');
      expect(_count(tester, 2), '5/9 \u2192 7');
      expect(_count(tester, 3), '2+4/6');
      expect(VolumeBars.countParts(8, 12, live: 3, pending: 3), (
        count: '8+3/12',
        planned: '14',
      ));
      expect(VolumeBars.countParts(8, 12), (count: '8/12', planned: null));
    });

    testWidgets('segments clip at the track end', (tester) async {
      await _pumpLive(
        tester,
        [(muscle: 'chest', sets: 10, target: 12)],
        [(live: 4, pending: 5)],
      );
      expect(_doneFill(tester), closeTo(10 / 12, 0.001));
      final p = _segments(tester);
      expect(p.liveEnd, 1.0);
      expect(p.plannedEnd, 1.0);
      final track = tester.getRect(find.byKey(const Key('volume-track')));
      final paint = tester.getRect(
        find
            .descendant(
              of: find.byKey(const Key('volume-live-segments')),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      expect(paint.right, lessThanOrEqualTo(track.right));
    });

    testWidgets('over target follows done + live, not planned', (tester) async {
      await _pumpLive(
        tester,
        [
          (muscle: 'chest', sets: 9, target: 12),
          (muscle: 'back', sets: 9, target: 12),
        ],
        [(live: 3, pending: 0), (live: 2, pending: 5)],
      );
      final tokens = Theme.of(
        tester.element(find.byType(VolumeBars)),
      ).extension<WorkoutTokens>()!;
      expect(_segments(tester, 0).color, tokens.accentText);
      expect(_segments(tester, 1).color, tokens.lineStrong);
    });

    testWidgets('each row speaks done, this workout and planned counts', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpLive(
        tester,
        [(muscle: 'Chest', sets: 8, target: 12)],
        [(live: 3, pending: 3)],
      );
      expect(
        find.bySemanticsLabel(
          'Chest: 8 sets done this week, 3 this workout, 14 planned, '
          'target 12',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('reduced motion lands the segments at once', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        wrapL10n(
          const VolumeBars(
            rows: [(muscle: 'chest', sets: 6, target: 12)],
            live: [(live: 3, pending: 3)],
          ),
        ),
      );
      await tester.pump();
      expect(_segments(tester).liveEnd, closeTo(0.75, 0.001));
    });

    testWidgets('the done fill keeps its state when live mode starts', (
      tester,
    ) async {
      const rows = [(muscle: 'chest', sets: 6, target: 12)];
      await tester.pumpWidget(wrapL10n(const VolumeBars(rows: rows)));
      await tester.pumpAndSettle();
      final fill = tester.state(find.byKey(const Key('volume-done-fill')));
      await tester.pumpWidget(
        wrapL10n(const VolumeBars(rows: rows, live: [(live: 1, pending: 2)])),
      );
      await tester.pump();
      expect(tester.state(find.byKey(const Key('volume-done-fill'))), fill);
      await tester.pumpAndSettle();
      expect(_segments(tester).plannedEnd, closeTo(0.75, 0.001));
    });
  });
}
