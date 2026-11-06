import 'package:alkion/catalog_ui/catalog_muscle_explorer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every callback of one recognizer mounted inside a vertical list,
/// so arena competition with the ancestor scroll is real.
class _Log {
  final events = <String>[];
  final orbits = <Offset>[];
  final starts = <Offset>[];
  final transforms = <(double, Offset)>[];
  final taps = <Offset>[];

  Offset get orbit => orbits.fold(Offset.zero, (sum, delta) => sum + delta);
}

final _canvas = find.byKey(const Key('canvas'));
final _outside = find.byKey(const Key('outside'));

Future<(_Log, ScrollController)> _pump(WidgetTester tester) async {
  final log = _Log();
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: ListView(
        controller: scroll,
        children: [
          const SizedBox(key: Key('outside'), height: 120),
          SizedBox(
            height: 300,
            child: RawGestureDetector(
              key: const Key('canvas'),
              behavior: HitTestBehavior.opaque,
              gestures: {
                BodyManipulationGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      BodyManipulationGestureRecognizer
                    >(BodyManipulationGestureRecognizer.new, (recognizer) {
                      recognizer
                        ..onDown = (() => log.events.add('down'))
                        ..onStart = (() => log.events.add('start'))
                        ..onOrbit = log.orbits.add
                        ..onTransformStart = log.starts.add
                        ..onTransform = ((scale, focal) {
                          log.transforms.add((scale, focal));
                        })
                        ..onTap = log.taps.add
                        ..onEnd = (() => log.events.add('end'));
                    }),
              },
            ),
          ),
          const SizedBox(height: 2000),
        ],
      ),
    ),
  );
  return (log, scroll);
}

void main() {
  testWidgets('a tap below slop resolves as a tap at its release position', (
    tester,
  ) async {
    final (log, scroll) = await _pump(tester);
    final origin = tester.getTopLeft(_canvas);
    final finger = await tester.startGesture(origin + const Offset(50, 60));
    await finger.moveBy(const Offset(kTouchSlop - 1, 0));
    await finger.up();
    expect(log.events, ['down']);
    expect(log.taps, [const Offset(50 + kTouchSlop - 1, 60)]);
    expect(log.orbits, isEmpty);
    expect(scroll.offset, 0);
  });

  testWidgets(
    'one finger wins against the ancestor scroll in both axes; outside still scrolls',
    (tester) async {
      final (log, scroll) = await _pump(tester);
      final centre = tester.getCenter(_canvas);
      final finger = await tester.startGesture(centre);
      // The slop-crossing move only begins; later movement is applied exactly.
      await finger.moveBy(const Offset(0, -30));
      await finger.moveBy(const Offset(0, -40));
      await finger.moveBy(const Offset(25, -5));
      await finger.up();
      await tester.pumpAndSettle();
      expect(log.events, ['down', 'start', 'end']);
      expect(log.orbit, const Offset(25, -45));
      expect(log.taps, isEmpty, reason: 'A drag release is never a tap');
      expect(scroll.offset, 0);
      await tester.drag(_outside, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(50));
      expect(log.events, ['down', 'start', 'end']);
    },
  );

  testWidgets(
    'a second finger after slop, a third, and lifting them re-base without jumps',
    (tester) async {
      final (log, scroll) = await _pump(tester);
      final origin = tester.getTopLeft(_canvas);
      final first = await tester.createGesture(pointer: 1);
      await first.down(origin + const Offset(100, 100));
      await first.moveBy(const Offset(30, 0)); // past slop
      await first.moveBy(const Offset(10, 0)); // orbits 10
      expect(log.orbit, const Offset(10, 0));
      final second = await tester.createGesture(pointer: 2);
      await second.down(origin + const Offset(220, 100));
      expect(log.starts, [const Offset(180, 100)]);
      expect(log.transforms, isEmpty, reason: 'Landing is not movement');
      await second.moveBy(const Offset(40, 0));
      // Span 40 → 60 around focal 180 → 200.
      expect(log.transforms.last.$1, closeTo(1.5, 1e-12));
      expect(log.transforms.last.$2, const Offset(200, 100));
      final third = await tester.createGesture(pointer: 3);
      await third.down(origin + const Offset(200, 160));
      expect(log.starts, hasLength(2), reason: 'A third finger re-bases');
      final transforms = log.transforms.length;
      await third.up();
      expect(log.starts, hasLength(3), reason: 'Lifting one of three re-bases');
      expect(log.transforms, hasLength(transforms));
      await first.moveBy(const Offset(0, 12));
      await second.moveBy(const Offset(0, 12));
      expect(log.transforms.last.$1, closeTo(1, 1e-12));
      expect(log.transforms.last.$2, const Offset(200, 112));
      await second.up();
      // The remaining finger orbits from where it is, not from the base.
      await first.moveBy(const Offset(-7, 3));
      expect(log.orbit, const Offset(3, 3));
      expect(log.starts, hasLength(3), reason: 'One finger never transforms');
      await first.up();
      await tester.pumpAndSettle();
      expect(log.events, ['down', 'start', 'end']);
      expect(log.taps, isEmpty);
      expect(scroll.offset, 0);
    },
  );

  testWidgets(
    'two fingers before any movement pinch at once; neither release taps',
    (tester) async {
      final (log, _) = await _pump(tester);
      final centre = tester.getCenter(_canvas);
      final a = await tester.startGesture(centre - const Offset(20, 0));
      final b = await tester.startGesture(centre + const Offset(20, 0));
      expect(log.events, ['down', 'start']);
      await b.moveBy(const Offset(20, 0));
      expect(log.transforms.single.$1, closeTo(1.5, 1e-12));
      await a.up();
      await b.up();
      expect(log.events, ['down', 'start', 'end']);
      expect(log.taps, isEmpty);
    },
  );

  testWidgets('a cancelled touch ends without a tap', (tester) async {
    final (log, _) = await _pump(tester);
    final finger = await tester.startGesture(tester.getCenter(_canvas));
    await finger.cancel();
    expect(log.events, ['down', 'end']);
    expect(log.taps, isEmpty);
    // The next touch starts a fresh sequence.
    await tester.tap(_canvas);
    expect(log.events, ['down', 'end', 'down']);
    expect(log.taps, hasLength(1));
  });
}
