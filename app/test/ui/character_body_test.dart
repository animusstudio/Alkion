import 'dart:math' as math;

import 'package:alkion/data/body_workload.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native controls normalize yaw and pause manual movement', () {
    final controller = CharacterBodyController();
    expect(controller.paused, isTrue);
    controller.resume();
    expect(controller.paused, isFalse);
    controller.rotateBy(-math.pi / 2);
    expect(controller.yaw, closeTo(math.pi * 1.5, 1e-10));
    expect(controller.paused, isTrue);
    controller.back();
    expect(controller.yaw, math.pi);
    controller.front();
    expect(controller.yaw, 0);
    controller.rotateBy(double.nan);
    expect(controller.yaw, 0);
    controller.dispose();
  });

  test(
    'manual turns wrap in both directions and absolute controls reset them',
    () {
      final controller = CharacterBodyController()..resume();
      for (var i = 0; i < 120; i++) {
        controller.rotateBy(-.01);
      }
      expect(controller.yaw, closeTo(math.pi * 2 - 1.2, 1e-10));
      expect(controller.paused, isTrue);
      controller.back();
      controller.rotateBy(math.pi * 4 + .2);
      expect(controller.yaw, closeTo(math.pi + .2, 1e-10));
      controller.front();
      controller.rotateBy(-.2);
      expect(controller.yaw, closeTo(math.pi * 2 - .2, 1e-10));
      controller.dispose();
    },
  );

  test(
    'old yaw acknowledgments cannot cross pause or repeated turn values',
    () {
      final controller = CharacterBodyController()..resume(); // revision 1
      controller.pause(); // revision 2
      controller.rotateBy(.1);
      controller.rotateBy(-.1); // revision 4, same command/turn as autoplay
      void acknowledge(int revision, double yaw, {int command = 0}) =>
          controller.acknowledgeRenderedYaw(
            yaw: yaw,
            command: command,
            turn: 0.0,
            revision: revision,
          );
      acknowledge(1, .8);
      acknowledge(2, .9);
      expect(controller.yaw, 0);
      acknowledge(4, .6);
      expect(controller.yaw, .6);
      controller.resume(); // revision 5
      acknowledge(4, .7);
      expect(controller.yaw, .6);
      acknowledge(5, .8);
      expect(controller.yaw, .8);
      controller.front(); // revision 6, absolute command 1
      acknowledge(5, .9);
      expect(controller.yaw, 0);
      acknowledge(6, 0, command: 1);
      expect(controller.yaw, 0);
      acknowledge(6, double.nan, command: 1);
      expect(controller.yaw, 0);
      controller.dispose();
    },
  );

  testWidgets(
    'non-Android host preserves fallback regardless of theme target',
    (tester) async {
      final controller = CharacterBodyController();
      final statuses = <CharacterBodyStatus>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 128,
            height: 212,
            child: CharacterBody(
              style: CharacterBodyStyle.female,
              scores: const <WorkloadMuscle, double>{},
              neutral: Colors.white,
              accent: Colors.orange,
              background: Colors.black,
              brightness: Brightness.dark,
              visible: true,
              reducedMotion: true,
              compact: true,
              controller: controller,
              onStatus: statuses.add,
              fallback: const Text('Counts remain available'),
            ),
          ),
        ),
      );
      expect(find.text('Counts remain available'), findsOneWidget);
      expect(statuses, [CharacterBodyStatus.unavailable]);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    variant: TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.linux,
      TargetPlatform.android,
    }),
  );
}
