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

  testWidgets('a pinch release does not coast', (tester) async {
    final controller = await pumpExplorer(tester);
    final centre = tester.getCenter(diagram);
    final a = await tester.startGesture(centre - const Offset(30, 0));
    final b = await tester.startGesture(centre + const Offset(30, 0));
    await b.moveBy(
      const Offset(40, 0),
      timeStamp: const Duration(milliseconds: 10),
    );
    await tester.pump();
    await a.up(timeStamp: const Duration(milliseconds: 10));
    await b.up(timeStamp: const Duration(milliseconds: 10));
    await tester.pump();
    final view = (controller.yaw, controller.pitch, controller.zoom);
    await tester.pump(const Duration(milliseconds: 400));
    expect((controller.yaw, controller.pitch, controller.zoom), view);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

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
