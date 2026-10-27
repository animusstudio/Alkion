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
