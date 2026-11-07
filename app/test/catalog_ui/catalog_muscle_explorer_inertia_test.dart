import 'dart:math' as math;

import 'package:alkion/data/body_workload.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import 'catalog_muscle_explorer_test.dart';

// The explorer's documented inertia constants.
const tau = .325;
const rate = .009;
const maxFling = 1500.0;
const maxZoomRate = 2.5; // log-scale per second

/// A one-finger orbit at [step] per 10 ms (100 × [step] px/s) after crossing
/// slop, released at the last move's time stamp.
Future<TestGesture> flick(
  WidgetTester tester,
  Offset step, {
  int moves = 8,
  bool release = true,
}) async {
  final finger = await tester.createGesture();
  await finger.down(tester.getCenter(diagram));
  var ms = 10;
  await finger.moveBy(step * 3, timeStamp: Duration(milliseconds: ms));
  for (var i = 0; i < moves; i++) {
    ms += 10;
    await finger.moveBy(step, timeStamp: Duration(milliseconds: ms));
  }
  await tester.pump();
  if (release) await finger.up(timeStamp: Duration(milliseconds: ms));
  return finger;
}

/// Two fingers 30 px either side of the canvas centre; each 10 ms step
/// multiplies their spread by [growth] and moves both by [step]. One finger
/// lifts at the last move's time stamp, which leaves two-finger mode; the
/// other lifts too unless [releaseBoth] is false. Pumps the frame that would
/// start a coast, and returns the second finger.
Future<TestGesture> pinch(
  WidgetTester tester, {
  double growth = 1,
  Offset step = Offset.zero,
  int moves = 8,
  bool releaseBoth = true,
}) async {
  final centre = tester.getCenter(diagram);
  final a = await tester.createGesture();
  final b = await tester.createGesture();
  await a.down(centre - const Offset(30, 0));
  await b.down(centre + const Offset(30, 0));
  var spread = 30.0, focal = centre, time = Duration.zero;
  for (var i = 0; i < moves; i++) {
    time += const Duration(milliseconds: 10);
    spread *= growth;
    focal += step;
    await a.moveTo(focal - Offset(spread, 0), timeStamp: time);
    await b.moveTo(focal + Offset(spread, 0), timeStamp: time);
  }
  await tester.pump();
  await a.up(timeStamp: time);
  if (releaseBoth) await b.up(timeStamp: time);
  await tester.pump(); // a coast's first tick has zero elapsed time
  return b;
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('a release coasts with exponential decay and stops by itself', (
    tester,
  ) async {
    final controller = await pumpExplorer(tester);
    await flick(tester, const Offset(10, 0)); // 1000 px/s
    final released = controller.yaw;
    await tester.pump(); // the coast's first tick has zero elapsed time
    expect(controller.yaw, released);
    final samples = <double>[];
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      samples.add(controller.yaw);
    }
    // Each 100 ms coasts less than the one before: smooth decay.
    for (var i = 1; i < samples.length; i++) {
      final before = samples[i - 1] - (i > 1 ? samples[i - 2] : released);
      expect(samples[i] - samples[i - 1], lessThan(before));
    }
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'Ticker stops');
    // Total coast is rate × τ: 1000 px/s × .009 rad/px × .325 s.
    expect(controller.yaw - released, closeTo(1000 * rate * tau, .15));
    // Velocity estimation leaves only float noise on the unused axis.
    expect(controller.pitch, closeTo(0, 1e-9));
    expect(controller.requests, isEmpty, reason: 'Coasting never picks');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a flick is capped, and a slow release does not coast', (
    tester,
  ) async {
    final controller = await pumpExplorer(tester);
    await flick(tester, const Offset(60, 0)); // 6000 px/s
    final released = controller.yaw;
    await tester.pumpAndSettle();
    final coast = (controller.yaw - released) % (math.pi * 2);
    expect(coast, closeTo(maxFling * rate * tau, .1));
    // 30 px/s is below the fling threshold.
    final finger = await tester.createGesture();
    await finger.down(tester.getCenter(diagram));
    await finger.moveBy(
      const Offset(25, 0),
      timeStamp: const Duration(seconds: 1),
    );
    for (var i = 1; i <= 6; i++) {
      await finger.moveBy(
        const Offset(3, 0),
        timeStamp: Duration(milliseconds: 1000 + i * 100),
      );
    }
    await tester.pump();
    final held = controller.yaw;
    await finger.up(timeStamp: const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.yaw, held);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pitch eases into the 45 degree bound and never passes it', (
    tester,
  ) async {
    final controller = await pumpExplorer(tester);
    await flick(tester, const Offset(0, 12)); // 1200 px/s downward
    final steps = <double>[];
    var last = controller.pitch;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        controller.pitch,
        lessThanOrEqualTo(CharacterBodyController.maxPitch),
      );
      steps.add(controller.pitch - last);
      last = controller.pitch;
    }
    // Arrives with vanishing speed rather than stopping hard at the bound.
    for (var i = 1; i < steps.length; i++) {
      expect(steps[i], lessThanOrEqualTo(steps[i - 1] + 1e-12));
    }
    expect(steps.last, lessThan(1e-3));
    await tester.pumpAndSettle();
    expect(controller.pitch, closeTo(CharacterBodyController.maxPitch, .01));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a touch stops the coast without selecting; the next tap picks', (
    tester,
  ) async {
    final controller = await pumpExplorer(tester);
    await flick(tester, const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(diagram);
    final stopped = controller.yaw;
    expect(
      controller.requests,
      isEmpty,
      reason: 'The stopping touch only stops',
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.yaw, stopped);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(diagram);
    expect(controller.requests, hasLength(1));
    controller.requests.single.result.complete(WorkloadMuscle.chest);
    await tester.pumpAndSettle();
    expect(body(tester).selectedRegion, WorkloadMuscle.chest);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a pick pending when the body starts coasting cannot select', (
    tester,
  ) async {
    final controller = await pumpExplorer(tester);
    await tester.tap(diagram);
    final pending = controller.requests.single.result;
    await flick(tester, const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 100));
    pending.complete(WorkloadMuscle.quads);
    await tester.pump(const Duration(milliseconds: 100));
    expect(body(tester).selectedRegion, isNull);
    await tester.pumpAndSettle();
    expect(body(tester).selectedRegion, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, command) in <(String, Future<void> Function(WidgetTester))>[
    ('Front', (t) => t.tap(find.byKey(const Key('catalog-body-front')))),
    ('Back', (t) => t.tap(find.byKey(const Key('catalog-body-back')))),
    ('Reset', (t) => t.tap(find.byKey(const Key('catalog-body-reset')))),
  ]) {
    testWidgets('$name cancels the coast and holds its view', (tester) async {
      final controller = await pumpExplorer(tester);
      await flick(tester, const Offset(10, -5));
      await tester.pump(const Duration(milliseconds: 80));
      await command(tester);
      await tester.pump();
      final view = (controller.yaw, controller.pitch);
      expect(view.$2, 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect((controller.yaw, controller.pitch), view);
      // Button ink may still animate; the view stays held throughout.
      await tester.pumpAndSettle();
      expect((controller.yaw, controller.pitch), view);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('choosing abductors from the list turns to the side and stops', (
    tester,
  ) async {
    final controller = await pumpExplorer(tester);
    await openList(tester);
    await revealArtwork(tester);
    await flick(tester, const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.ensureVisible(muscle('abductors'));
    await tester.tap(muscle('abductors'));
    await tester.pump();
    expect((controller.yaw, controller.pitch), (math.pi / 2, 0.0));
    await tester.pump(const Duration(milliseconds: 600));
    expect((controller.yaw, controller.pitch), (math.pi / 2, 0.0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion never coasts and never starts the ticker', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final controller = await pumpExplorer(tester);
    await flick(tester, const Offset(10, 0));
    final released = controller.yaw;
    expect(released, greaterThan(0), reason: 'Direct dragging still works');
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.yaw, released);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gesture input applies once per frame, summed', (tester) async {
    final controller = await pumpExplorer(tester);
    var changes = 0;
    controller.addListener(() => changes++);
    final finger = await tester.startGesture(tester.getCenter(diagram));
    await finger.moveBy(const Offset(0, 30)); // slop: begins (one pause)
    await tester.pump();
    changes = 0;
    for (var i = 0; i < 10; i++) {
      await finger.moveBy(const Offset(3, 2));
    }
    expect(changes, 0, reason: 'Nothing applies between frames');
    await tester.pump();
    expect(changes, 1);
    expect(controller.yaw, closeTo(30 * rate, 1e-9));
    expect(controller.pitch, closeTo(20 * rate, 1e-9));
    await finger.up();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a pinch release coasts zoom at its rate; the last finger flings no orbit',
    (tester) async {
      final controller = await pumpExplorer(tester);
      final finger = await pinch(tester, growth: 1.015, releaseBoth: false);
      final released = controller.zoom;
      expect(released, closeTo(math.pow(1.015, 8), 1e-9));
      // The last finger jitters within slop, fast, and lifts: no orbit fling.
      await finger.moveBy(
        const Offset(7, 0),
        timeStamp: const Duration(milliseconds: 90),
      );
      await finger.up(timeStamp: const Duration(milliseconds: 90));
      final steps = <double>[];
      var last = controller.zoom;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        steps.add(controller.zoom - last);
        last = controller.zoom;
      }
      expect(steps.first, greaterThan(0), reason: 'Zoom keeps going');
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], lessThan(steps[i - 1]), reason: 'Smooth decay');
      }
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'Ticker stops');
      // Total log travel is rate × τ, at ln(1.015) / 10 ms.
      expect(
        controller.zoom,
        closeTo(released * math.exp(math.log(1.015) / .01 * tau), .005),
      );
      // Centred: zoom about the focal point keeps the pan; no orbit at all.
      expect(controller.pan.dx, closeTo(0, 1e-9));
      expect(controller.pan.dy, closeTo(0, 1e-9));
      expect((controller.yaw, controller.pitch), (0.0, 0.0));
      expect(controller.requests, isEmpty, reason: 'Coasting never picks');
      // A fast pinch is capped at the documented zoom rate.
      controller.setViewport(1, Offset.zero);
      await pinch(tester, growth: 1.05, moves: 4);
      final fast = controller.zoom;
      await tester.pumpAndSettle();
      expect(
        controller.zoom,
        closeTo(fast * math.exp(maxZoomRate * tau), .005),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (name, from, growth, bound) in [
    ('3x', 2.0, 1.05, 3.0),
    ('1x', 1.6, 1 / 1.05, 1.0),
  ]) {
    testWidgets('a pinch coast eases into $name without overshoot', (
      tester,
    ) async {
      final controller = await pumpExplorer(tester);
      controller.setViewport(from, Offset.zero);
      await pinch(tester, growth: growth, moves: 4);
      final steps = <double>[], zooms = <double>[];
      var last = controller.zoom;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.zoom, inInclusiveRange(1.0, 3.0));
        steps.add((controller.zoom - last).abs());
        zooms.add(controller.zoom);
        expect(
          (controller.zoom - bound).abs(),
          lessThanOrEqualTo((last - bound).abs() + 1e-12),
          reason: 'Monotone toward the bound, never past it',
        );
        last = controller.zoom;
      }
      // Decelerates all the way; it rests on the bound with a final
      // sub-pixel landing step, not a stop at speed.
      final landing = zooms.indexWhere((zoom) => (zoom - bound).abs() < 1e-9);
      expect(landing, greaterThan(10), reason: 'It rests on the bound');
      for (var i = 1; i < landing; i++) {
        expect(steps[i], lessThanOrEqualTo(steps[i - 1] + 1e-12));
      }
      expect(steps[landing - 1], lessThan(1e-3), reason: 'Arrives slowly');
      expect(steps[landing], lessThan(1e-3));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpAndSettle();
      expect(controller.zoom, closeTo(bound, 1e-9));
      if (bound == 1) expect(controller.pan, Offset.zero);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'a two-finger pan release coasts, then eases into the pan bound',
    (tester) async {
      final controller = await pumpExplorer(tester);
      final width = tester.getSize(diagram).width;
      controller.setViewport(3, Offset.zero);
      await pinch(tester, step: const Offset(6, 0)); // 600 px/s
      final released = controller.pan.dx;
      final steps = <double>[];
      var last = released;
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        steps.add(controller.pan.dx - last);
        last = controller.pan.dx;
      }
      expect(steps.first, greaterThan(0));
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], lessThan(steps[i - 1]));
      }
      await tester.pumpAndSettle();
      // Total travel is velocity × τ; zoom and orbit are untouched.
      expect(
        controller.pan.dx,
        closeTo(released + 600 * tau / width, 3 / width),
      );
      expect(controller.pan.dy, closeTo(0, 1e-6));
      expect(controller.zoom, 3);
      expect((controller.yaw, controller.pitch), (0.0, 0.0));
      // At 1.5× the pan bound is a quarter width: a fast pan eases into it.
      controller.setViewport(1.5, Offset.zero);
      // 48 px directly, about halfway to the bound at a quarter width (95 px).
      await pinch(tester, step: const Offset(12, 0), moves: 4); // 1200 px/s
      final pans = <double>[controller.pan.dx];
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.pan.dx, lessThanOrEqualTo(.25));
        pans.add(controller.pan.dx);
      }
      // Decelerating into the bound, not clamped at speed: the step that
      // reaches it, and the one before, are sub-pixel.
      final landing = pans.indexWhere((pan) => (pan - .25).abs() < 1e-9);
      expect(landing, greaterThan(10));
      for (var i = 2; i < landing; i++) {
        expect(pans[i] - pans[i - 1], lessThan(pans[i - 1] - pans[i - 2]));
      }
      expect((pans[landing] - pans[landing - 1]) * width, lessThan(.5));
      expect((pans[landing - 1] - pans[landing - 2]) * width, lessThan(.5));
      await tester.pumpAndSettle();
      expect(controller.pan.dx, closeTo(.25, 1e-9));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a touch stops a two-finger coast without selecting; the next tap picks',
    (tester) async {
      final controller = await pumpExplorer(tester);
      await pinch(tester, growth: 1.02);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(diagram);
      final stopped = (controller.zoom, controller.pan);
      expect(stopped.$1, greaterThan(math.pow(1.02, 8)));
      expect(controller.requests, isEmpty, reason: 'The touch only stops');
      await tester.pump(const Duration(milliseconds: 500));
      expect((controller.zoom, controller.pan), stopped);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.tap(diagram);
      expect(controller.requests, hasLength(1));
      controller.requests.single.result.complete(WorkloadMuscle.chest);
      await tester.pumpAndSettle();
      expect(body(tester).selectedRegion, WorkloadMuscle.chest);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an orbit or a re-landing finger takes over from a coast without a jump',
    (tester) async {
      final controller = await pumpExplorer(tester);
      final finger = await pinch(tester, growth: 1.02, releaseBoth: false);
      await tester.pump(const Duration(milliseconds: 40));
      final reached = controller.zoom;
      expect(reached, greaterThan(math.pow(1.02, 8)), reason: 'It coasts');
      // Past slop the finger left orbits; the coast stops where it is.
      await finger.moveBy(const Offset(30, 0));
      await finger.moveBy(const Offset(10, 0));
      await tester.pump();
      expect(controller.zoom, reached);
      expect(controller.yaw, closeTo(10 * rate, 1e-9));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.zoom, reached);
      await finger.up();
      await tester.pumpAndSettle();
      // A finger landing during a coast re-bases from wherever it reached.
      final held = await pinch(tester, growth: 1.02, releaseBoth: false);
      await tester.pump(const Duration(milliseconds: 40));
      final coasting = (controller.zoom, controller.pan);
      final again = await tester.startGesture(
        tester.getCenter(diagram) + const Offset(0, 40),
      );
      await tester.pump();
      expect((controller.zoom, controller.pan), coasting);
      await tester.pump(const Duration(milliseconds: 300));
      expect((controller.zoom, controller.pan), coasting);
      await again.up();
      await held.up();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Reset and the zoom buttons cancel a two-finger coast; hiding stops it',
    (tester) async {
      final controller = await pumpExplorer(tester);
      await reportReady(tester);
      await pinch(tester, growth: 1.02);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(zoomIn);
      await tester.pump();
      final stepped = controller.zoom;
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.zoom, stepped, reason: 'The step is not overwritten');
      await tester.pumpAndSettle();
      controller.setViewport(1, Offset.zero);
      await pinch(tester, growth: 1.02);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('catalog-body-reset')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect((controller.zoom, controller.pan), (1.0, Offset.zero));
      await tester.pumpAndSettle();
      // A covering route hides the canvas: the coast stops for good.
      await pinch(tester, growth: 1.02);
      await tester.pump(const Duration(milliseconds: 50));
      final navigator = Navigator.of(tester.element(diagram));
      navigator.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await tester.pump();
      final hidden = controller.zoom;
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(controller.zoom, hidden);
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.zoom, hidden);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reduced motion: pinch and pan releases do not coast', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final controller = await pumpExplorer(tester);
    await pinch(tester, growth: 1.02, step: const Offset(6, 0));
    final released = (controller.zoom, controller.pan);
    expect(released.$1, greaterThan(1), reason: 'Direct pinching still works');
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
    expect((controller.zoom, controller.pan), released);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'leaving the foreground mid-coast stops orbit and two-finger coasts in place',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final controller = await pumpExplorer(tester);
      Future<void> background() async {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump();
      }

      Future<void> resume() async {
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        // A long background: a running coast would jump to its end here.
        await tester.pump(const Duration(seconds: 5));
      }

      // One-finger orbit coast.
      await flick(tester, const Offset(10, -4));
      await tester.pump(const Duration(milliseconds: 60));
      final coasting = (controller.yaw, controller.pitch);
      await tester.pump(const Duration(milliseconds: 20));
      final held = (controller.yaw, controller.pitch);
      expect(held, isNot(coasting), reason: 'The coast is running');
      await background();
      expect((controller.yaw, controller.pitch), held);
      await tester.pump(const Duration(seconds: 2));
      await resume();
      expect((controller.yaw, controller.pitch), held);
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'Ticker off');
      expect(controller.requests, isEmpty);

      // Two-finger pinch and pan coast.
      await pinch(tester, growth: 1.02, step: const Offset(6, 0));
      await tester.pump(const Duration(milliseconds: 60));
      final pinched = (controller.zoom, controller.pan);
      await tester.pump(const Duration(milliseconds: 20));
      final viewport = (controller.zoom, controller.pan);
      expect(viewport, isNot(pinched), reason: 'The coast is running');
      await background();
      expect((controller.zoom, controller.pan), viewport);
      await resume();
      expect((controller.zoom, controller.pan), viewport);
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'Ticker off');
      expect(controller.requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing the explorer mid-coast disposes the ticker cleanly', (
    tester,
  ) async {
    await pumpExplorer(tester);
    await flick(tester, const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
