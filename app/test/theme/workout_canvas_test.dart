import 'package:alkion/theme/tokens.dart';
import 'package:alkion/theme/workout_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget canvas({
  Brightness brightness = Brightness.dark,
  bool reducedMotion = false,
  bool ticking = true,
  Widget child = const SizedBox(width: 48, height: 48),
}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reducedMotion),
  child: Theme(
    data: ThemeData(
      extensions: [
        brightness == Brightness.dark
            ? WorkoutTokens.dark(accents[0])
            : WorkoutTokens.light(accents[0]),
      ],
    ),
    child: TickerMode(
      enabled: ticking,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: WorkoutCanvas(child: child)),
      ),
    ),
  ),
);

double opacity(WidgetTester tester) => tester
    .renderObject<RenderAnimatedOpacity>(find.byType(FadeTransition))
    .opacity
    .value;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('$brightness: quiet fade loops over unchanged square dots', (
      tester,
    ) async {
      await tester.pumpWidget(canvas(brightness: brightness));
      final tokens = brightness == Brightness.dark
          ? WorkoutTokens.dark(accents[0])
          : WorkoutTokens.light(accents[0]);
      final painter = tester
          .widget<CustomPaint>(find.byType(CustomPaint))
          .painter!;
      void paint(Canvas target) => painter.paint(target, const Size(48, 48));
      expect(paint, paintsExactlyCountTimes(#drawRect, 4));
      expect(
        paint,
        paints
          ..rect(rect: const Rect.fromLTWH(0, 0, 1.5, 1.5), color: tokens.grid)
          ..rect(rect: const Rect.fromLTWH(24, 0, 1.5, 1.5), color: tokens.grid)
          ..rect(rect: const Rect.fromLTWH(0, 24, 1.5, 1.5), color: tokens.grid)
          ..rect(
            rect: const Rect.fromLTWH(24, 24, 1.5, 1.5),
            color: tokens.grid,
          ),
      );
      expect(
        tester.widget<ColoredBox>(find.byType(ColoredBox)).color,
        tokens.bg,
      );
      expect(opacity(tester), closeTo(0.25, 0.001));
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), closeTo(0.325, 0.002));
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), closeTo(0.4, 0.001));
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), closeTo(0.325, 0.002));
      await tester.pump(const Duration(seconds: 4));
      expect(opacity(tester), closeTo(0.25, 0.001));
      expect(
        tester.widget<CustomPaint>(find.byType(CustomPaint)).painter,
        same(painter),
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'initial and changing reduced motion stay static and dispose safely',
    (tester) async {
      await tester.pumpWidget(canvas(reducedMotion: true));
      expect(opacity(tester), 0.25);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(canvas());
      await tester.pump(const Duration(seconds: 4));
      final phase = opacity(tester);
      await tester.pumpWidget(canvas(reducedMotion: true));
      expect(opacity(tester), 0.25);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 20));
      expect(opacity(tester), 0.25);
      await tester.pumpWidget(canvas());
      expect(opacity(tester), closeTo(phase, 0.001));
      await tester.pump(const Duration(seconds: 1));
      expect(opacity(tester), greaterThan(phase));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lifecycle and TickerMode pause without losing the fading-out phase',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(canvas());
      await tester.pump(const Duration(seconds: 10));
      final phase = opacity(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pump(const Duration(seconds: 20));
        expect(opacity(tester), phase);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(opacity(tester), closeTo(phase, 0.001));
      await tester.pump(const Duration(seconds: 1));
      expect(opacity(tester), lessThan(phase));

      await tester.pumpWidget(canvas(ticking: false));
      final mutedPhase = opacity(tester);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 20));
      expect(opacity(tester), mutedPhase);
      await tester.pumpWidget(canvas());
      expect(opacity(tester), closeTo(mutedPhase, 0.001));
      await tester.pump(const Duration(seconds: 1));
      expect(opacity(tester), lessThan(mutedPhase));
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ambient frames preserve foreground build, paint, input and semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var builds = 0;
      var paints = 0;
      var taps = 0;
      await tester.pumpWidget(
        canvas(
          child: Builder(
            builder: (_) {
              builds++;
              return Semantics(
                label: 'Foreground action',
                button: true,
                child: GestureDetector(
                  onTap: () => taps++,
                  child: CustomPaint(
                    painter: _ForegroundPainter(() => paints++),
                    size: const Size(48, 48),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final initialBuilds = builds;
      final initialPaints = paints;
      final initialSemantics = tester
          .getSemantics(find.byType(WorkoutCanvas))
          .toStringDeep();
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(builds, initialBuilds);
      expect(paints, initialPaints);
      expect(
        tester.getSemantics(find.byType(WorkoutCanvas)).toStringDeep(),
        initialSemantics,
      );
      expect(find.bySemanticsLabel('Foreground action'), findsOneWidget);
      await tester.tap(find.byType(GestureDetector));
      expect(taps, 1);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}

class _ForegroundPainter extends CustomPainter {
  const _ForegroundPainter(this.onPaint);
  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_ForegroundPainter oldDelegate) => false;
}
