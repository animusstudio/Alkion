import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/widgets/volume_bars.dart';

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
}
