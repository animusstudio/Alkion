import 'dart:async';
import 'dart:math' as math;

import 'package:alkion/data/body_workload.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  test(
    'viewport zoom and pan stay finite, bounded and notify exact revisions',
    () {
      final controller = CharacterBodyController();
      var changes = 0;
      controller.addListener(() => changes++);
      controller.setViewport(9, const Offset(4, -4));
      expect(controller.zoom, 3);
      expect(controller.pan, const Offset(1, -1));
      controller.setViewport(3, const Offset(1, -1));
      expect(changes, 1);
      controller.setViewport(double.nan, Offset.zero);
      controller.setViewport(2, const Offset(double.infinity, 0));
      expect(changes, 1);
      controller.zoomBy(-99);
      expect(controller.zoom, 1);
      expect(controller.pan, Offset.zero);
      controller.setViewport(2, const Offset(.2, -.3));
      controller.back();
      controller.resetView();
      expect(controller.zoom, 1);
      expect(controller.pan, Offset.zero);
      expect(controller.yaw, 0);
      expect(controller.paused, isTrue);
      controller.dispose();
    },
  );

  test('orbit pitch clamps to 45 degrees and every held view levels it', () {
    final controller = CharacterBodyController();
    var changes = 0;
    controller.addListener(() => changes++);
    expect(CharacterBodyController.maxPitch, math.pi / 4);
    expect(controller.pitch, 0);
    controller.orbitBy(.2, .3);
    expect(controller.yaw, closeTo(.2, 1e-12));
    expect(controller.pitch, closeTo(.3, 1e-12));
    expect(controller.paused, isTrue);
    expect(changes, 1);
    controller.orbitBy(0, 9);
    expect(controller.pitch, math.pi / 4);
    // Held at the bound: further tilt is no change and no revision.
    controller.orbitBy(0, .1);
    expect(changes, 2);
    controller.orbitBy(0, -99);
    expect(controller.pitch, -math.pi / 4);
    controller.orbitBy(double.nan, .1);
    controller.orbitBy(.1, double.infinity);
    expect(controller.pitch, -math.pi / 4);
    expect(controller.yaw, closeTo(.2, 1e-12));
    // A turn at the pitch bound still turns.
    controller.orbitBy(.1, -.1);
    expect(controller.yaw, closeTo(.3, 1e-12));
    expect(controller.pitch, -math.pi / 4);
    for (final view in <VoidCallback>[
      controller.front,
      controller.back,
      controller.side,
      controller.resetView,
    ]) {
      controller.orbitBy(0, .4 - controller.pitch);
      expect(controller.pitch, closeTo(.4, 1e-12));
      view();
      expect(controller.pitch, 0);
    }
    controller.side();
    expect(controller.yaw, math.pi / 2);
    // rotateBy keeps its pitch and its pause-on-any-finite-turn behavior.
    controller.orbitBy(0, .2);
    controller.resume();
    controller.rotateBy(0);
    expect(controller.paused, isTrue);
    expect(controller.pitch, closeTo(.2, 1e-12));
    controller.dispose();
  });

  test('unbound picks and invalid surface coordinates are ignored', () async {
    final controller = CharacterBodyController();
    expect(
      await controller.pick(const Offset(1, 1), const Size(100, 100)),
      isNull,
    );
    for (final offset in [
      const Offset(-1, 0),
      const Offset(100, 0),
      const Offset(0, 100),
      const Offset(double.nan, 0),
    ]) {
      expect(await controller.pick(offset, const Size(100, 100)), isNull);
    }
    controller.dispose();
  });

  testWidgets('picks require exact current native frame and opt-in lifecycle', (
    tester,
  ) async {
    CharacterBody.debugForceAndroid = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      CharacterBody.debugForceAndroid = false;
      debugDefaultTargetPlatformOverride = null;
    });
    final messenger = tester.binding.defaultBinaryMessenger;
    int? view;
    final views = <int>[];
    Map<Object?, Object?>? display;
    Map<Object?, Object?>? request;
    Completer<Map<String, Object?>>? reply;
    String channelName() => 'dev.animusstudio.alkion/character-body/$view';
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        view = (call.arguments as Map)['id'] as int;
        views.add(view!);
        messenger.setMockMethodCallHandler(MethodChannel(channelName()), (
          call,
        ) async {
          if (call.method == 'display') {
            display = Map.of(call.arguments as Map);
            return null;
          }
          if (call.method == 'pick') {
            request = Map.of(call.arguments as Map);
            reply = Completer<Map<String, Object?>>();
            return reply!.future;
          }
          return null;
        });
      }
      if (call.method == 'resize') {
        return {
          'width': (call.arguments as Map)['width'],
          'height': (call.arguments as Map)['height'],
        };
      }
      return call.method == 'create' ? 1 : null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      for (final id in views) {
        messenger.setMockMethodCallHandler(
          MethodChannel('dev.animusstudio.alkion/character-body/$id'),
          null,
        );
      }
    });
    final controller = CharacterBodyController();
    var visible = true;
    var enabled = true;
    var style = CharacterBodyStyle.male;
    var surfaceWidth = 128.0;
    Widget body() => MaterialApp(
      home: Center(
        child: SizedBox(
          width: surfaceWidth,
          height: 212,
          child: CharacterBody(
            style: style,
            scores: const {},
            neutral: Colors.white,
            accent: Colors.orange,
            background: Colors.black,
            brightness: Brightness.dark,
            visible: visible,
            reducedMotion: true,
            compact: true,
            controller: controller,
            pickingEnabled: enabled,
          ),
        ),
      ),
    );
    Future<void> report({int frame = 1, int version = 5}) async {
      final generation = (display!['interaction'] as Map)['generation'];
      final completer = Completer<void>();
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channelName(),
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('status', {
            'version': version,
            'status': 'ready',
            'generation': generation,
            'frame': frame,
            'load': 1,
            'layout': 1,
          }),
        ),
        (_) => completer.complete(),
      );
      await completer.future;
      await tester.pump();
    }

    Future<WorkloadMuscle?> startPick() {
      return controller.pick(const Offset(64, 106), const Size(128, 212));
    }

    void complete({String? region = 'chest', int? frame}) {
      reply!.complete({
        for (final key in ['id', 'generation', 'frame', 'load', 'layout'])
          key: request![key],
        'region': region,
        if (frame != null) 'frame': frame,
      });
    }

    await tester.pumpWidget(body());
    await tester.pump();
    expect(await startPick(), isNull);
    // Protocol v3/v4 statuses never admit picking.
    for (final old in [3, 4]) {
      await report(version: old);
      expect(await startPick(), isNull);
    }
    expect(display!['version'], 5);
    expect(display!['view'], {'zoom': 1.0, 'x': 0.0, 'y': 0.0, 'pitch': 0.0});
    controller.orbitBy(0, .3);
    await tester.pump();
    expect((display!['view'] as Map)['pitch'], .3);
    controller.front();
    await tester.pump();
    expect((display!['view'] as Map)['pitch'], 0.0);
    await report();
    var result = startPick();
    await tester.pump();
    expect(request!['version'], 5);
    expect(request!['x'], .5);
    expect(request!['y'], .5);
    complete();
    expect(await result, WorkloadMuscle.chest);
    for (final region in [WorkloadMuscle.adductors, WorkloadMuscle.abductors]) {
      result = startPick();
      await tester.pump();
      complete(region: region.name);
      expect(await result, region);
    }
    result = startPick();
    await tester.pump();
    complete(region: 'alien');
    expect(await result, isNull);
    result = startPick();
    await tester.pump();
    complete(region: null);
    expect(await result, isNull);
    result = startPick();
    await tester.pump();
    complete(frame: 0);
    expect(await result, isNull);
    result = startPick();
    await tester.pump();
    await report(frame: 2);
    complete();
    expect(await result, isNull);
    // One in-flight request plus one replaceable latest tap; intermediate
    // futures resolve null without crossing the native bridge.
    result = startPick();
    await tester.pump();
    final firstId = request!['id'];
    final skipped = startPick();
    final latest = startPick();
    expect(await skipped, isNull);
    expect(request!['id'], firstId);
    complete();
    expect(await result, isNull);
    await tester.pump();
    expect(request!['id'], (firstId as int) + 1);
    complete(region: 'back');
    expect(await latest, WorkloadMuscle.back);
    for (final transition in <VoidCallback>[
      () => controller.rotateBy(.1),
      () => controller.orbitBy(0, -.2),
      () => controller.back(),
      () => controller.zoomBy(.5),
      () => controller.setViewport(2, const Offset(.25, -.25)),
      () => controller.resetView(),
      () => controller.retry(),
      () => surfaceWidth = 150,
      () => visible = false,
      () => style = CharacterBodyStyle.female,
      () => enabled = false,
    ]) {
      visible = true;
      enabled = true;
      surfaceWidth = 128;
      await tester.pumpWidget(body());
      await tester.pump();
      await report();
      result = startPick();
      await tester.pump();
      transition();
      await tester.pumpWidget(body());
      await tester.pump();
      complete();
      expect(await result, isNull);
    }
    visible = true;
    enabled = true;
    await tester.pumpWidget(body());
    await tester.pump();
    await report();
    result = startPick();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    complete();
    expect(await result, isNull);
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'displays pipeline once per frame without awaiting acks, two in flight at most',
    (tester) async {
      CharacterBody.debugForceAndroid = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger = tester.binding.defaultBinaryMessenger;
      final displays = <Map<Object?, Object?>>[];
      final replies = <Completer<void>>[];
      final channels = <String>[];
      addTearDown(() {
        CharacterBody.debugForceAndroid = false;
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final name =
              'dev.animusstudio.alkion/character-body/${(call.arguments as Map)['id']}';
          channels.add(name);
          // Acknowledgements are held until the test releases them.
          messenger.setMockMethodCallHandler(MethodChannel(name), (call) {
            if (call.method != 'display') return Future.value();
            displays.add(Map.of(call.arguments as Map));
            final reply = Completer<void>();
            replies.add(reply);
            return reply.future;
          });
          return 1;
        }
        if (call.method == 'resize') {
          return {
            'width': (call.arguments as Map)['width'],
            'height': (call.arguments as Map)['height'],
          };
        }
        return null;
      });
      final controller = CharacterBodyController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 128,
              height: 212,
              child: CharacterBody(
                style: CharacterBodyStyle.male,
                scores: const {},
                neutral: Colors.white,
                accent: Colors.orange,
                background: Colors.black,
                brightness: Brightness.dark,
                visible: true,
                reducedMotion: true,
                compact: true,
                controller: controller,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(displays, hasLength(1));
      // 120 changes inside one frame leave as one message with the latest
      // state, while the first acknowledgement is still outstanding.
      for (var i = 0; i < 120; i++) {
        controller.orbitBy(.01, 0);
      }
      await tester.pump();
      expect(displays, hasLength(2));
      expect(displays.last['turn'] as double, closeTo(1.2, 1e-9));
      expect(replies.first.isCompleted, isFalse);
      // Two unacknowledged messages hold further sends: no storm, no queue.
      controller.orbitBy(0, .2);
      await tester.pump();
      controller.orbitBy(0, .1);
      await tester.pump();
      expect(displays, hasLength(2));
      // One acknowledgement frees a slot for only the latest state.
      replies.first.complete();
      await tester.pump();
      await tester.pump();
      expect(displays, hasLength(3));
      expect(
        (displays.last['view'] as Map)['pitch'] as double,
        closeTo(.3, 1e-9),
      );
      for (final reply in replies) {
        if (!reply.isCompleted) reply.complete();
      }
      await tester.pump();
      await tester.pump();
      expect(displays, hasLength(3), reason: 'Idle frames send nothing');
      // A pause leaves without waiting for a frame.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.value();
      expect(displays, hasLength(4));
      expect(displays.last['visible'], isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (final reply in replies) {
        if (!reply.isCompleted) reply.complete();
      }
      await tester.pumpWidget(const SizedBox());
      for (final reply in replies) {
        if (!reply.isCompleted) reply.complete();
      }
      debugDefaultTargetPlatformOverride = null;
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
