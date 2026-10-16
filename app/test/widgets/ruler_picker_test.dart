import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/ruler_picker.dart';

import '../support/l10n_harness.dart';

void main() {
  group('RulerScale', () {
    test('an on-grid anchor starts the tape at min', () {
      final s = RulerScale(anchor: 100, step: 2.5, min: 0, max: 500);
      expect(s.valueAt(0), 0);
      expect(s.indexOf(100), 40);
      expect(s.valueAt(41), 102.5);
      expect(s.count, 201);
    });

    test('an off-grid anchor shifts the whole tape so it is exact', () {
      final s = RulerScale(anchor: 101, step: 2.5, min: 0, max: 500);
      final i = s.indexOf(101);
      expect(s.valueAt(i), 101);
      expect(s.valueAt(i + 1), 103.5);
      expect(s.valueAt(i - 1), 98.5);
      expect(s.valueAt(0), 1);
    });

    test('indexOf clamps to the ends and the tape grows to fit the anchor', () {
      final s = RulerScale(anchor: 620, step: 5, min: 0, max: 500);
      expect(s.valueAt(s.indexOf(620)), 620);
      expect(s.indexOf(-50), 0);
      expect(s.indexOf(10000), s.count - 1);
    });

    test('fractional steps do not drift', () {
      final s = RulerScale(anchor: 40, step: 1.25, min: 0, max: 500);
      expect(s.valueAt(s.indexOf(40) + 3), 43.75);
    });
  });

  group('RulerPicker', () {
    late List<double> changes;
    late int taps;
    setUp(() {
      changes = [];
      taps = 0;
    });

    Widget ruler({double value = 100, double step = 2.5}) => wrapL10n(
      Center(
        child: SizedBox(
          width: 320,
          child: RulerPicker(
            value: value,
            step: step,
            max: 500,
            format: (v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v',
            semanticLabel: 'Weight',
            onChanged: changes.add,
            onTapValue: () => taps++,
          ),
        ),
      ),
    );

    RulerPickerState state(WidgetTester tester) =>
        tester.state<RulerPickerState>(find.byType(RulerPicker));

    testWidgets('swiping left moves up the tape and snaps onto a value', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      await tester.timedDrag(
        find.byType(RulerPicker),
        const Offset(-3 * RulerPicker.defaultItemExtent, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(changes, [102.5, 105, 107.5]);
      expect(state(tester).position, 107.5); // snapped onto a mark
    });

    testWidgets('swiping right moves down the tape', (tester) async {
      await tester.pumpWidget(ruler());
      await tester.timedDrag(
        find.byType(RulerPicker),
        const Offset(3 * RulerPicker.defaultItemExtent, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(changes.last, 92.5);
    });

    testWidgets('a drag past the end stops at the lowest value', (
      tester,
    ) async {
      await tester.pumpWidget(ruler(value: 5));
      await tester.timedDrag(
        find.byType(RulerPicker),
        const Offset(10 * RulerPicker.defaultItemExtent, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(changes, [2.5, 0]);
      expect(state(tester).position, 0);
    });

    testWidgets('a fling travels several values and lands exactly on one', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      await tester.fling(find.byType(RulerPicker), const Offset(-150, 0), 3000);
      await tester.pumpAndSettle();
      expect(
        changes.length,
        greaterThan(4),
        reason: 'the glide should carry on past the drag',
      );
      for (var i = 1; i < changes.length; i++) {
        expect(
          changes[i] - changes[i - 1],
          2.5,
          reason: 'each value is reported once, in order',
        );
      }
      final pos = state(tester).position;
      expect(pos, changes.last);
      expect(
        (pos - 100) / 2.5,
        closeTo(((pos - 100) / 2.5).roundToDouble(), 1e-9),
      );
    });

    testWidgets('settleAll stops a glide on the last reported value', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      await tester.fling(find.byType(RulerPicker), const Offset(-150, 0), 3000);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final shown = changes.last;
      final reported = changes.length;
      RulerPicker.settleAll();
      await tester.pumpAndSettle();
      expect(
        changes.length,
        reported,
        reason: 'nothing reported after settling',
      );
      expect(state(tester).position, shown);
    });

    testWidgets(
      'a handed-in value off the two-decimal grid is not echoed back',
      (tester) async {
        await tester.pumpWidget(ruler());
        await tester.pumpWidget(
          ruler(value: 3 * 1.1, step: 1.1),
        ); // 3.3000000000000003
        await tester.pumpAndSettle();
        expect(changes, isEmpty);
      },
    );

    testWidgets('a non-positive step does not crash the tape', (tester) async {
      await tester.pumpWidget(ruler(step: 0));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an external value change re-centres without reporting it back',
      (tester) async {
        await tester.pumpWidget(ruler());
        await tester.pumpWidget(ruler(value: 105));
        await tester.pumpAndSettle();
        expect(state(tester).position, 105);
        await tester.pumpWidget(ruler(value: 121)); // off the old grid
        await tester.pumpAndSettle();
        expect(changes, isEmpty);
        expect(state(tester).position, 121);
        // The tape moves in steps from the handed-in value.
        await tester.timedDrag(
          find.byType(RulerPicker),
          const Offset(-RulerPicker.defaultItemExtent, 0),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        expect(changes, [123.5]);
      },
    );

    testWidgets('a handed-in value a hundredth off is taken, not swallowed', (
      tester,
    ) async {
      await tester.pumpWidget(ruler(value: 60, step: 0.5));
      await tester.pumpWidget(ruler(value: 60.01, step: 0.5));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(state(tester).position, 60.01);
      await tester.timedDrag(
        find.byType(RulerPicker),
        const Offset(-RulerPicker.defaultItemExtent, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(changes, [60.51]);
    });

    testWidgets('tapping the centre value asks for typed entry', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      await tester.tap(find.byKey(const Key('ruler-centre')));
      expect(taps, 1);
    });

    testWidgets(
      'it is a slider for screen readers, with increase and decrease',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(ruler());
        final node = tester.getSemantics(find.bySemanticsLabel('Weight'));
        expect(node.flagsCollection.isSlider, isTrue);
        expect(node.value, '100');
        node.owner!.performAction(node.id, SemanticsAction.increase);
        await tester.pumpAndSettle();
        expect(changes.last, 102.5);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        expect(
          taps,
          1,
          reason: 'typed entry must be reachable with a screen reader',
        );
        handle.dispose();
      },
    );

    // The ruler is 200 wide, centred in a 400-wide black frame. Nothing may
    // be painted in the 100px margins on either side.
    Future<int> strayPixels(WidgetTester tester, Key frame) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(frame),
      );
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      var stray = 0;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (x >= 100 && x < 300) continue;
          final o = (y * image.width + x) * 4;
          if (bytes.getUint8(o) +
                  bytes.getUint8(o + 1) +
                  bytes.getUint8(o + 2) >
              0) {
            stray++;
          }
        }
      }
      return stray;
    }

    Widget framed(Key frame, {required double value}) => wrapL10n(
      Center(
        child: RepaintBoundary(
          key: frame,
          child: Container(
            color: Colors.black,
            width: 400,
            alignment: Alignment.center,
            child: SizedBox(
              width: 200,
              child: RulerPicker(
                value: value,
                step: 1,
                fineStep: 0.25,
                max: 500,
                format: (v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets(
      'the tape paints nothing outside its own box, coarse and zoomed',
      (tester) async {
        const frame = Key('frame');
        await tester.pumpWidget(framed(frame, value: 100));
        await tester.pumpAndSettle();
        expect(await strayPixels(tester, frame), 0, reason: 'coarse');

        await tester.pumpWidget(framed(frame, value: 100.25)); // rests zoomed
        await tester.pumpAndSettle();
        expect(state(tester).zoom, 1);
        expect(await strayPixels(tester, frame), 0, reason: 'zoomed');
      },
    );
  });

  group('RulerPicker zoom', () {
    late List<double> changes;
    late int taps;
    setUp(() {
      changes = [];
      taps = 0;
    });

    String fmt(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    // The app's display rules: kg up to two decimals, lb whole pounds.
    String kg(double v) =>
        v.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
    String lb(double v) => v.round().toString();

    Widget bare({
      double value = 100,
      double step = 1,
      double? fineStep = 0.25,
      String Function(double)? format,
    }) => RulerPicker(
      value: value,
      step: step,
      fineStep: fineStep,
      max: 500,
      format: format ?? fmt,
      semanticLabel: 'Weight',
      onChanged: changes.add,
      onTapValue: () => taps++,
    );

    Widget ruler({
      double value = 100,
      double step = 1,
      double? fineStep = 0.25,
      String Function(double)? format,
    }) => wrapL10n(
      Center(
        child: SizedBox(
          width: 320,
          child: bare(
            value: value,
            step: step,
            fineStep: fineStep,
            format: format,
          ),
        ),
      ),
    );

    Future<void> fastDrag(WidgetTester tester, double dx) async {
      await tester.timedDrag(
        find.byType(RulerPicker),
        Offset(dx, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
    }

    RulerPickerState state(WidgetTester tester) =>
        tester.state<RulerPickerState>(find.byType(RulerPicker));
    bool whole(double v) => v == v.roundToDouble();
    bool quarter(double v) => (v * 4) == (v * 4).roundToDouble();

    /// Drags [steps] moves of [dx] each, one every 16 ms of the fake clock,
    /// continuing [gesture] from [from].
    Future<Duration> slide(
      WidgetTester tester,
      TestGesture gesture,
      Duration from, {
      required int steps,
      required double dx,
    }) async {
      var t = from;
      for (var i = 0; i < steps; i++) {
        t += const Duration(milliseconds: 16);
        await gesture.moveBy(Offset(dx, 0), timeStamp: t);
        await tester.pump(const Duration(milliseconds: 16));
      }
      return t;
    }

    testWidgets('a fast swipe moves in coarse steps only', (tester) async {
      await tester.pumpWidget(ruler());
      await tester.timedDrag(
        find.byType(RulerPicker),
        const Offset(-300, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(changes, isNotEmpty);
      expect(changes.every(whole), isTrue, reason: '$changes');
      expect(state(tester).zoom, 0);
      expect(state(tester).position, changes.last);
    });

    testWidgets('a slow drag zooms in and lands on a fine value', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      await tester.timedDrag(
        find.byType(RulerPicker),
        const Offset(-150, 0),
        const Duration(seconds: 2),
      );
      await tester.pumpAndSettle();
      final last = changes.last;
      expect(quarter(last), isTrue, reason: '$changes');
      expect(whole(last), isFalse, reason: '$changes');
      expect(state(tester).position, last);
      expect(state(tester).zoom, 1, reason: 'a fractional value rests zoomed');
    });

    testWidgets('a hold then a small move steps by the fine step', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RulerPicker)),
      );
      await tester.pump(kHoldDwell + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 200)); // zoom animation
      expect(state(tester).zoom, 1);
      // Past the touch slop, then exactly one fine slot.
      await gesture.moveBy(
        const Offset(-kTouchSlop - 2, 0),
        timeStamp: const Duration(milliseconds: 600),
      );
      await gesture.moveBy(
        const Offset(-kFineExtent, 0),
        timeStamp: const Duration(milliseconds: 1400),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up(timeStamp: const Duration(milliseconds: 2400));
      await tester.pumpAndSettle();
      expect(changes, [100.25]);
      expect(state(tester).zoom, 1);
    });

    testWidgets('a hold released in place zooms back out without reporting', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RulerPicker)),
      );
      await tester.pump(kHoldDwell + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(state(tester).zoom, 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(state(tester).zoom, 0);
    });

    testWidgets('a zoomed drag that lands on a whole value rests coarse', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RulerPicker)),
      );
      await tester.pump(kHoldDwell + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(
        const Offset(-kTouchSlop - 2, 0),
        timeStamp: const Duration(milliseconds: 600),
      );
      await gesture.moveBy(
        const Offset(-4 * kFineExtent, 0),
        timeStamp: const Duration(milliseconds: 3000),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up(timeStamp: const Duration(milliseconds: 4000));
      await tester.pumpAndSettle();
      expect(changes, [100.25, 100.5, 100.75, 101]);
      expect(state(tester).zoom, 0);
    });

    testWidgets(
      'a zoom entered during a touch holds at any speed until the finger lifts',
      (tester) async {
        await tester.pumpWidget(ruler());
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(RulerPicker)),
        );
        // ~94 dp/s: slow enough to zoom in.
        var t = await slide(
          tester,
          gesture,
          Duration.zero,
          steps: 40,
          dx: -1.5,
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(state(tester).zoom, 1);
        // ~310 dp/s, then ~1250 dp/s: still zoomed while the finger is down.
        t = await slide(tester, gesture, t, steps: 12, dx: -5);
        t = await slide(tester, gesture, t, steps: 6, dx: -20);
        await tester.pump(const Duration(milliseconds: 200));
        expect(state(tester).zoom, 1);
        await gesture.up(timeStamp: t);
        await tester.pumpAndSettle();
        // Released zoomed, so it lands on the fine grid.
        expect(changes.last % 0.25, 0, reason: '$changes');
      },
    );

    testWidgets(
      'a fractional value rests zoomed; a fast drag from it lands on the coarse grid',
      (tester) async {
        await tester.pumpWidget(ruler(value: 60.25));
        expect(state(tester).zoom, 1);
        await fastDrag(tester, -300);
        // Nothing behind the direction of travel when the grid switches.
        expect(changes, [61, 62, 63, 64, 65, 66, 67]);
        expect(state(tester).position, changes.last);
        expect(state(tester).zoom, 0);
      },
    );

    testWidgets(
      'an on-grid value rests coarse, and handed-in values set the zoom',
      (tester) async {
        await tester.pumpWidget(ruler(value: 60));
        expect(state(tester).zoom, 0);
        await tester.pumpWidget(ruler(value: 60.5));
        await tester.pumpAndSettle();
        expect(state(tester).zoom, 1);
        expect(state(tester).position, 60.5);
        await tester.pumpWidget(ruler(value: 61));
        await tester.pumpAndSettle();
        expect(state(tester).zoom, 0);
        expect(changes, isEmpty);
      },
    );

    testWidgets('a value off both grids keeps its own fine grid', (
      tester,
    ) async {
      await tester.pumpWidget(ruler(value: 60.3));
      expect(state(tester).zoom, 1);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RulerPicker)),
      );
      await gesture.moveBy(
        const Offset(-kTouchSlop - 2, 0),
        timeStamp: const Duration(milliseconds: 100),
      );
      await gesture.moveBy(
        const Offset(-kFineExtent, 0),
        timeStamp: const Duration(milliseconds: 1100),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up(timeStamp: const Duration(milliseconds: 2100));
      await tester.pumpAndSettle();
      expect(changes, [60.55]);
    });

    testWidgets('screen-reader steps are fine while resting zoomed', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(ruler(value: 60.25));
      final node = tester.getSemantics(find.bySemanticsLabel('Weight'));
      expect(node.increasedValue, '60.5');
      expect(node.decreasedValue, '60');
      node.owner!.performAction(node.id, SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(changes, [60.5]);
      handle.dispose();
    });

    testWidgets('settleAll during a zoom rests on the last value at its zoom', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RulerPicker)),
      );
      await tester.pump(kHoldDwell + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        state(tester).zoom,
        allOf(greaterThan(0.5), lessThan(1.0)),
        reason: 'mid-zoom',
      );
      RulerPicker.settleAll();
      expect(state(tester).zoom, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        state(tester).zoom,
        0,
        reason: 'the zoom must not resume after settling',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
    });

    testWidgets('no zoom without a fine step', (tester) async {
      await tester.pumpWidget(ruler(fineStep: null));
      await tester.timedDrag(
        find.byType(RulerPicker),
        const Offset(-150, 0),
        const Duration(seconds: 2),
      );
      await tester.pumpAndSettle();
      expect(state(tester).zoom, 0);
      expect(changes, [101, 102]);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RulerPicker)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(state(tester).zoom, 0);
      await gesture.up();
    });

    testWidgets(
      'under reduced motion the zoom and glide jump without animating',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures.allOn;
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpWidget(ruler());
        await tester.timedDrag(
          find.byType(RulerPicker),
          const Offset(-150, 0),
          const Duration(seconds: 2),
        );
        await tester.pump();
        expect(state(tester).zoom, 1);
        expect(state(tester).position, changes.last);
        await tester.fling(
          find.byType(RulerPicker),
          const Offset(-150, 0),
          3000,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(state(tester).zoom, 0);
        expect(state(tester).position, changes.last);
        expect(whole(changes.last), isTrue, reason: '$changes');
      },
    );

    testWidgets(
      'a value just off a step keeps its own reading and rests zoomed',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(ruler(value: 4.99, format: kg));
        expect(state(tester).zoom, 1);
        expect(state(tester).position, 4.99);
        expect(
          tester.getSemantics(find.bySemanticsLabel('Weight')).value,
          '4.99',
        );
        handle.dispose();
        await fastDrag(tester, -300);
        expect(changes.first, 5);
      },
    );

    testWidgets('a value just off a step drags down to the step below', (
      tester,
    ) async {
      await tester.pumpWidget(ruler(value: 4.99, format: kg));
      await fastDrag(tester, 300);
      expect(changes.first, 4);
    });

    testWidgets('a converted value that reads as a step rests coarse on it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        ruler(value: 220.46, step: 5, fineStep: 1, format: lb),
      ); // 100 kg
      expect(state(tester).zoom, 0);
      expect(
        state(tester).position,
        220,
        reason: 'the 220 mark sits under the centre',
      );
      expect(tester.getSemantics(find.bySemanticsLabel('Weight')).value, '220');
      handle.dispose();
      await fastDrag(tester, -300);
      expect(changes.first, 225);
    });

    testWidgets(
      'a converted value that reads as a step drags down to the step below',
      (tester) async {
        await tester.pumpWidget(
          ruler(value: 220.46, step: 5, fineStep: 1, format: lb),
        );
        await fastDrag(tester, 300);
        expect(changes.first, 215);
      },
    );

    testWidgets(
      'a tap mid-glide rests on the value shown and opens typed entry',
      (tester) async {
        await tester.pumpWidget(ruler(value: 60.25));
        await tester.fling(
          find.byType(RulerPicker),
          const Offset(-150, 0),
          3000,
        );
        await tester.pump(const Duration(milliseconds: 16));
        final reported = changes.length;
        final shown = changes.isEmpty ? 60.25 : changes.last;
        await tester.tap(find.byKey(const Key('ruler-centre')));
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(
          changes.length,
          reported,
          reason: 'nothing reported after the tap: $changes',
        );
        expect(state(tester).position, shown);
      },
    );

    testWidgets(
      'a page scroll that starts on the tape neither zooms nor moves it',
      (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          wrapL10n(
            SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  const SizedBox(height: 100),
                  SizedBox(width: 320, child: bare()),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(RulerPicker)),
        );
        var t = Duration.zero;
        for (var i = 0; i < 8; i++) {
          t += const Duration(milliseconds: 16);
          await gesture.moveBy(const Offset(1.5, -6), timeStamp: t);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pump(
          const Duration(milliseconds: 400),
        ); // a pause, finger down
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          state(tester).zoom,
          0,
          reason: 'a held page scroll must not zoom the tape',
        );
        await gesture.moveBy(
          const Offset(0, -20),
          timeStamp: t + const Duration(milliseconds: 420),
        );
        await gesture.up(timeStamp: t + const Duration(milliseconds: 440));
        await tester.pumpAndSettle();
        expect(scroll.offset, greaterThan(0), reason: 'the page scrolled');
        expect(state(tester).zoom, 0);
        expect(changes, isEmpty);
      },
    );

    testWidgets('a handed-in value mid-drag takes over the tape', (
      tester,
    ) async {
      await tester.pumpWidget(ruler());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RulerPicker)),
      );
      await gesture.moveBy(
        const Offset(-kTouchSlop - 2, 0),
        timeStamp: const Duration(milliseconds: 16),
      );
      await gesture.moveBy(
        const Offset(-72, 0),
        timeStamp: const Duration(milliseconds: 32),
      );
      await tester.pump();
      expect(changes, [101]);
      await tester.pumpWidget(ruler(value: 80.5));
      await gesture.moveBy(
        const Offset(-72, 0),
        timeStamp: const Duration(milliseconds: 48),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up(timeStamp: const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(changes, [101], reason: 'nothing reported after the hand-in');
      expect(state(tester).position, 80.5);
      expect(state(tester).zoom, 1, reason: '80.5 rests zoomed');
    });

    for (final v in [4.99, 60.01]) {
      testWidgets('a resting $v kg paints its own label at the centre', (
        tester,
      ) async {
        await tester.pumpWidget(ruler(value: v, format: kg));
        await tester.pump();
        expect(state(tester).zoom, 1);
        expect(state(tester).centreLabels, [kg(v)]);
      });
    }

    testWidgets(
      'settling mid-glide re-fits a fine grid a handed-in value shifted',
      (tester) async {
        await tester.pumpWidget(ruler(value: 60.3, format: kg));
        await tester.fling(
          find.byType(RulerPicker),
          const Offset(-150, 0),
          3000,
        );
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        RulerPicker.settleAll();
        await tester.pumpAndSettle();
        final settled = changes.last;
        expect(whole(settled), isTrue, reason: '$changes');
        expect(state(tester).zoom, 0);
        // One fine slot after a hold lands on the plain quarter grid, not on
        // the old 60.3-anchored one.
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(RulerPicker)),
        );
        await tester.pump(kHoldDwell + const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.moveBy(
          const Offset(-kTouchSlop - 2, 0),
          timeStamp: const Duration(milliseconds: 600),
        );
        await gesture.moveBy(
          const Offset(-kFineExtent, 0),
          timeStamp: const Duration(milliseconds: 1400),
        );
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.up(timeStamp: const Duration(milliseconds: 2400));
        await tester.pumpAndSettle();
        expect(changes.last, settled + 0.25);
      },
    );
  });
}
