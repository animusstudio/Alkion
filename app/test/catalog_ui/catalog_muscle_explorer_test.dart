import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:alkion/catalog_ui/catalog_muscle_explorer.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import 'catalog_discovery_picker_test.dart';

/// Keeps the actual CharacterBody and gesture surface in the tree, controlling
/// only the asynchronous native result. No screen-space muscle approximation.
class PendingBodyController extends CharacterBodyController {
  final requests =
      <({Offset position, Size size, Completer<WorkloadMuscle?> result})>[];
  @override
  Future<WorkloadMuscle?> pick(Offset position, Size surfaceSize) {
    final result = Completer<WorkloadMuscle?>();
    requests.add((position: position, size: surfaceSize, result: result));
    return result.future;
  }
}

class ArtworkSettings extends SettingsService {
  String artworkStyle = 'female';
  @override
  String get bodyStyle => artworkStyle;

  void changeArtworkStyle(String value) {
    artworkStyle = value;
    notifyListeners();
  }
}

void explorerPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

CharacterBody body(WidgetTester tester) =>
    tester.widget<CharacterBody>(find.byType(CharacterBody));
Finder get diagram => find.byKey(const Key('catalog-body-diagram'));
Finder muscle(String key) => find.byKey(ValueKey('catalog-muscle-$key'));

/// Page content outside the canvas: a vertical drag there scrolls the sheet.
Finder get outsideCanvas => find.byKey(const Key('catalog-muscle-list-link'));
Finder get zoomIn => find.byKey(const Key('catalog-body-zoom-in'));
Finder get zoomOut => find.byKey(const Key('catalog-body-zoom-out'));

ScrollPosition explorerScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('catalog-muscle-explorer-scroll')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

/// The explorer's own status; zoom appears with ready artwork. The host has no
/// WebView, so tests report ready through the canvas's status callback.
Future<void> reportReady(WidgetTester tester) async {
  body(tester).onStatus!(CharacterBodyStatus.ready);
  await tester.pumpAndSettle();
}

Future<PendingBodyController> pumpExplorer(
  WidgetTester tester, {
  String? selected,
}) async {
  explorerPhone(tester);
  final state = discoveryState();
  addTearDown(state.dispose);
  final controller = PendingBodyController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    discoveryApp(
      CatalogMuscleExplorer(
        index: state.index('en'),
        selected: selected,
        controller: controller,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> revealArtwork(WidgetTester tester) async {
  final scroll = find.descendant(
    of: find.byKey(const Key('catalog-muscle-explorer-scroll')),
    matching: find.byType(Scrollable),
  );
  tester.state<ScrollableState>(scroll).position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> openList(WidgetTester tester) async {
  if (muscle('chest').evaluate().isNotEmpty) return;
  final link = find.byKey(const Key('catalog-muscle-list-link'));
  await tester.ensureVisible(link);
  await tester.tap(link);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(preloadAppFonts);

  for (final workloadSheet in [false, true]) {
    testWidgets(
      'Android ${workloadSheet ? 'workload' : 'explorer'} sheet entrance admits loading without an earlier native status',
      (tester) async {
        explorerPhone(tester);
        CharacterBody.debugForceAndroid = true;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final messenger = tester.binding.defaultBinaryMessenger;
        final displays = <Map<Object?, Object?>>[];
        final channels = <String>[];
        addTearDown(() {
          CharacterBody.debugForceAndroid = false;
          debugDefaultTargetPlatformOverride = null;
          messenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          );
          for (final name in channels) {
            messenger.setMockMethodCallHandler(MethodChannel(name), null);
          }
        });
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
          call,
        ) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['id'] as int;
            final name = 'dev.animusstudio.alkion/character-body/$id';
            channels.add(name);
            messenger.setMockMethodCallHandler(MethodChannel(name), (
              call,
            ) async {
              if (call.method == 'display') {
                displays.add(Map.of(call.arguments as Map));
              }
              return null;
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
        final state = discoveryState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          discoveryApp(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => workloadSheet
                    ? showBodyWorkloadSheet(
                        context,
                        workload: () => calculateWorkoutWorkload(
                          mode: WorkoutWorkloadMode.planned,
                          exercises: const [],
                        ),
                      )
                    : showCatalogMuscleExplorer(
                        context,
                        index: state.index('en'),
                      ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(displays, isNotEmpty);
        expect(
          displays.last['visible'],
          isTrue,
          reason:
              'Loading waits for viewport admission; admission cannot wait for a load status',
        );
        expect(displays.last['paused'], !workloadSheet);
        if (!workloadSheet) {
          expect((displays.last['interaction'] as Map)['enabled'], isTrue);
        }
        final reply = Completer<void>();
        messenger.handlePlatformMessage(
          channels.last,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('status', {
              'version': 5,
              'status': 'ready',
              'generation':
                  (displays.last['interaction'] as Map?)?['generation'] ?? 0,
              'frame': 1,
              'load': 1,
              'layout': 1,
            }),
          ),
          (_) => reply.complete(),
        );
        await reply.future;
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('character-body-loading-silhouette')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'native result controls selection with exact surface-local coordinates',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final controller = PendingBodyController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        discoveryApp(
          CatalogMuscleExplorer(
            index: state.index('en'),
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(body(tester).pickingEnabled, isTrue);
      expect(body(tester).scores, isEmpty);
      expect(controller.paused, isTrue);
      final rect = tester.getRect(diagram);
      // Deliberately outside the old chest anchor: only the renderer decides.
      final local = Offset(rect.width * .08, rect.height * .9);
      await tester.tapAt(rect.topLeft + local);
      expect(controller.requests, hasLength(1));
      expect(controller.requests.single.position.dx, closeTo(local.dx, .001));
      expect(controller.requests.single.position.dy, closeTo(local.dy, .001));
      expect(
        controller.requests.single.size,
        tester.getSize(find.byType(CharacterBody)),
      );
      controller.requests.single.result.complete(WorkloadMuscle.chest);
      await tester.pumpAndSettle();
      expect(body(tester).selectedRegion, WorkloadMuscle.chest);
      await openList(tester);
      expect(tester.widget<ChoiceChip>(muscle('chest')).selected, isTrue);
      expect(find.text('Show exercises · Chest'), findsOneWidget);
      await revealArtwork(tester);
      await tester.tap(diagram);
      controller.requests.last.result.complete(null);
      await tester.pump();
      expect(body(tester).selectedRegion, WorkloadMuscle.chest);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'list selection highlights every region and stays available without artwork',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        discoveryApp(
          CatalogMuscleExplorer(
            index: state.index('en'),
            selected: 'hamstrings',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(body(tester).controller.yaw, math.pi);
      expect(body(tester).controller.paused, isTrue);
      expect(body(tester).selectedRegion, WorkloadMuscle.hamstrings);
      expect(find.byKey(const Key('catalog-body-fallback')), findsOneWidget);
      expect(find.byKey(const Key('catalog-body-retry')), findsOneWidget);
      await openList(tester);
      final groups = state
          .index('en')
          .browseGroups
          .where((g) => g.kind == 'muscle');
      // All thirteen display regions are explorer targets.
      expect(
        groups.map((g) => WorkloadMuscle.fromKey(g.key)).toSet(),
        WorkloadMuscle.values.toSet(),
      );
      for (final group in groups) {
        final chip = muscle(group.key);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pump();
        expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
        expect(body(tester).selectedRegion, WorkloadMuscle.fromKey(group.key));
      }
      await tester.ensureVisible(muscle('core'));
      await tester.tap(muscle('core'));
      await tester.pump();
      expect(body(tester).selectedRegion, WorkloadMuscle.core);
      final data = tester.getSemantics(muscle('core')).getSemanticsData();
      expect(data.flagsCollection.isSelected, Tristate.isTrue);
      expect(find.text('Show exercises · Core'), findsOneWidget);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'taps on the five hip, trunk and forearm groups select and highlight them',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final controller = PendingBodyController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        discoveryApp(
          CatalogMuscleExplorer(
            index: state.index('en'),
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (region, label) in [
        (WorkloadMuscle.glutes, 'Glutes'),
        (WorkloadMuscle.core, 'Core'),
        (WorkloadMuscle.forearms, 'Forearms'),
        (WorkloadMuscle.adductors, 'Adductors'),
        (WorkloadMuscle.abductors, 'Abductors'),
      ]) {
        await revealArtwork(tester);
        await tester.tap(diagram);
        controller.requests.last.result.complete(region);
        await tester.pumpAndSettle();
        expect(body(tester).selectedRegion, region);
        expect(find.text('Show exercises · $label'), findsOneWidget);
        await openList(tester);
        expect(tester.widget<ChoiceChip>(muscle(region.name)).selected, isTrue);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (group, yaw) in [
    ('chest', 0.0),
    ('core', 0.0),
    ('forearms', 0.0),
    ('adductors', 0.0),
    ('abductors', math.pi / 2),
    ('glutes', math.pi),
    ('hamstrings', math.pi),
  ]) {
    testWidgets('$group opens on its facing view', (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        discoveryApp(
          CatalogMuscleExplorer(index: state.index('en'), selected: group),
        ),
      );
      await tester.pumpAndSettle();
      expect(body(tester).controller.yaw, yaw);
      expect(body(tester).selectedRegion, WorkloadMuscle.fromKey(group));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'only a list choice of abductors turns to the side; taps there keep it',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final controller = PendingBodyController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        discoveryApp(
          CatalogMuscleExplorer(
            index: state.index('en'),
            selected: 'glutes',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.yaw, math.pi);
      await openList(tester);
      for (final group in ['chest', 'adductors', 'core', 'quads']) {
        await tester.ensureVisible(muscle(group));
        await tester.tap(muscle(group));
        await tester.pump();
        expect(controller.yaw, math.pi, reason: group);
      }
      await tester.ensureVisible(muscle('abductors'));
      await tester.tap(muscle('abductors'));
      await tester.pumpAndSettle();
      expect(controller.yaw, math.pi / 2);
      expect(controller.paused, isTrue);
      expect(body(tester).selectedRegion, WorkloadMuscle.abductors);
      // A tap on the field from the side still returns and keeps abductors.
      await revealArtwork(tester);
      await tester.tap(diagram);
      controller.requests.last.result.complete(WorkloadMuscle.abductors);
      await tester.pumpAndSettle();
      expect(body(tester).selectedRegion, WorkloadMuscle.abductors);
      expect(controller.yaw, math.pi / 2);
      // A tap that lands on abductors from the front does not turn the body.
      await tester.tap(find.byKey(const Key('catalog-body-front')));
      await tester.pumpAndSettle();
      await tester.tap(diagram);
      controller.requests.last.result.complete(WorkloadMuscle.abductors);
      await tester.pumpAndSettle();
      expect(controller.yaw, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new taps, list choices, turn, retry and hiding discard older picks',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final controller = PendingBodyController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        discoveryApp(
          CatalogMuscleExplorer(
            index: state.index('en'),
            selected: 'chest',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(diagram);
      await tester.tap(diagram);
      controller.requests.last.result.complete(WorkloadMuscle.biceps);
      await tester.pump();
      controller.requests.first.result.complete(WorkloadMuscle.triceps);
      await tester.pump();
      expect(body(tester).selectedRegion, WorkloadMuscle.biceps);
      for (final action in [
        'list',
        'turn',
        'zoom',
        'pan',
        'reset',
        'retry',
        'hide',
      ]) {
        await revealArtwork(tester);
        await tester.tap(diagram);
        final pending = controller.requests.last.result;
        switch (action) {
          case 'list':
            await openList(tester);
            await tester.ensureVisible(muscle('biceps'));
            await tester.tap(muscle('biceps'));
          case 'turn':
            await tester.tap(find.byKey(const Key('catalog-body-back')));
          case 'zoom':
            controller.zoomBy(.5);
          case 'pan':
            controller.setViewport(2, const Offset(.2, -.2));
          case 'reset':
            controller.resetView();
          case 'retry':
            await tester.tap(find.byKey(const Key('catalog-body-retry')));
          case 'hide':
            await tester.drag(outsideCanvas, const Offset(0, -500));
        }
        await tester.pumpAndSettle();
        pending.complete(WorkloadMuscle.hamstrings);
        await tester.pump();
        expect(
          body(tester).selectedRegion,
          WorkloadMuscle.biceps,
          reason: action,
        );
      }
      await revealArtwork(tester);
      await tester.tap(diagram);
      final pending = controller.requests.last.result;
      await tester.pumpWidget(const SizedBox());
      pending.complete(WorkloadMuscle.triceps);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending picks cannot cross style, layout, status or pointer cancellation',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final controller = PendingBodyController();
      addTearDown(controller.dispose);
      final settings = ArtworkSettings();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsService>.value(
          value: settings,
          child: discoveryApp(
            CatalogMuscleExplorer(
              index: state.index('en'),
              selected: 'chest',
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final action in ['style', 'layout', 'status', 'cancel']) {
        await revealArtwork(tester);
        await tester.tap(diagram);
        final pending = controller.requests.last.result;
        switch (action) {
          case 'style':
            settings.changeArtworkStyle('male');
          case 'layout':
            tester.view.physicalSize = const Size(320, 640);
          case 'status':
            body(tester).onStatus!(CharacterBodyStatus.error);
          case 'cancel':
            final gesture = await tester.startGesture(
              tester.getCenter(diagram),
            );
            await tester.pump(const Duration(milliseconds: 150));
            await gesture.cancel();
        }
        await tester.pumpAndSettle();
        pending.complete(WorkloadMuscle.triceps);
        await tester.pumpAndSettle();
        expect(
          body(tester).selectedRegion,
          WorkloadMuscle.chest,
          reason: action,
        );
      }
      expect(body(tester).style, CharacterBodyStyle.male);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'one-finger drag orbits both axes, clamps pitch and owns the canvas in the scrolling sheet',
    (tester) async {
      final controller = await pumpExplorer(tester);
      await openList(tester);
      await revealArtwork(tester);
      final scroll = explorerScroll(tester);
      expect(scroll.maxScrollExtent, greaterThan(200));
      final centre = tester.getCenter(diagram);
      // Upward on the canvas: tilts the camera down, never scrolls the page.
      var finger = await tester.startGesture(centre, pointer: 1);
      await finger.moveBy(const Offset(0, -30)); // past slop: begins only
      await tester.pump();
      expect(
        controller.pitch,
        0,
        reason: 'Movement before slop is not applied',
      );
      await finger.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(controller.pitch, closeTo(-20 * .009, 1e-9));
      expect(controller.yaw, 0);
      for (var i = 0; i < 10; i++) {
        await finger.moveBy(const Offset(0, -20));
      }
      await tester.pump();
      expect(controller.pitch, -CharacterBodyController.maxPitch);
      await finger.up();
      await tester.pumpAndSettle();
      expect(scroll.pixels, 0, reason: 'The canvas owns vertical drags');
      expect(body(tester).visible, isTrue);
      // Downward clamps at +45°; sideways turns at the accepted rate.
      finger = await tester.startGesture(centre, pointer: 2);
      await finger.moveBy(const Offset(0, 30));
      for (var i = 0; i < 12; i++) {
        await finger.moveBy(const Offset(0, 20));
      }
      await tester.pump();
      expect(controller.pitch, CharacterBodyController.maxPitch);
      await finger.moveBy(const Offset(40, -10));
      await tester.pump();
      expect(controller.yaw, closeTo(40 * .009, 1e-9));
      expect(
        controller.pitch,
        closeTo(CharacterBodyController.maxPitch - 10 * .009, 1e-9),
      );
      await finger.up();
      await tester.pumpAndSettle();
      expect(scroll.pixels, 0);
      expect(controller.paused, isTrue);
      expect(
        controller.requests,
        isEmpty,
        reason: 'A drag release never picks',
      );
      final view = (controller.yaw, controller.pitch);
      // The same vertical drag outside the canvas still scrolls the page.
      await tester.drag(outsideCanvas, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(100));
      expect((controller.yaw, controller.pitch), view);
      expect(controller.requests, isEmpty);
      // Front and a list choice of abductors (the side view) level the camera.
      await revealArtwork(tester);
      await tester.tap(find.byKey(const Key('catalog-body-front')));
      await tester.pump();
      expect((controller.yaw, controller.pitch), (0.0, 0.0));
      await tester.drag(diagram, const Offset(0, 120));
      await tester.pump();
      expect(controller.pitch, greaterThan(0));
      await tester.ensureVisible(muscle('abductors'));
      await tester.tap(muscle('abductors'));
      await tester.pumpAndSettle();
      expect((controller.yaw, controller.pitch), (math.pi / 2, 0.0));
      expect(body(tester).selectedRegion, WorkloadMuscle.abductors);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a second finger after an orbit pinches around its focal point and pans without jumps',
    (tester) async {
      final controller = await pumpExplorer(tester);
      await openList(tester);
      await revealArtwork(tester);
      final scroll = explorerScroll(tester);
      final centre = tester.getCenter(diagram);
      final size = tester.getSize(diagram);
      // The first finger moves past slop and orbits BEFORE the second lands,
      // the order a real hand produces and injected input never covered.
      final first = await tester.createGesture(pointer: 1);
      await first.down(centre - const Offset(40, 0));
      await first.moveBy(const Offset(30, 0));
      await first.moveBy(const Offset(10, 0));
      await tester.pump();
      final yaw = controller.yaw;
      expect(yaw, closeTo(10 * .009, 1e-9));
      final second = await tester.createGesture(pointer: 2);
      await second.down(centre + const Offset(40, 0));
      await tester.pump();
      expect(
        (controller.yaw, controller.pitch, controller.zoom, controller.pan),
        (yaw, 0.0, 1.0, Offset.zero),
        reason: 'A landing finger re-bases without a jump',
      );
      // Span 20 → 40 around a focal point 20 → 40 px right of centre: the
      // artwork point under the old focal point stays under the new one.
      await second.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(controller.zoom, closeTo(2, 1e-9));
      expect(controller.pan.dx, closeTo(0, 1e-9));
      // Off-centre focal point: span 40 → 60 moves the focal point from 40 to 20
      // px right of centre. Artwork point (40 - 0) / 2 = 20 under the old focal
      // point now sits under the new one: pan = 20 - 20 * 3 = -40 px.
      await first.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(controller.zoom, closeTo(3, 1e-9));
      expect(controller.pan.dx, closeTo(-40 / size.width, 1e-9));
      final zoomed = controller.pan;
      // Two fingers moving together pan; orbit stays where it was.
      await first.moveBy(const Offset(0, 30));
      await second.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(controller.zoom, 3);
      expect(controller.pan.dy, closeTo(30 / size.height, 1e-9));
      expect(controller.pan.dx, closeTo(zoomed.dx, 1e-9));
      expect((controller.yaw, controller.pitch), (yaw, 0.0));
      // Lifting one finger re-bases too; the other resumes orbiting from it.
      final viewport = (controller.zoom, controller.pan);
      await second.up();
      await tester.pump();
      expect((controller.zoom, controller.pan), viewport);
      expect((controller.yaw, controller.pitch), (yaw, 0.0));
      await first.moveBy(const Offset(20, 10));
      await tester.pump();
      expect(controller.yaw, closeTo(yaw + 20 * .009, 1e-9));
      expect(controller.pitch, closeTo(10 * .009, 1e-9));
      expect((controller.zoom, controller.pan), viewport);
      await first.up();
      await tester.pumpAndSettle();
      expect(scroll.pixels, 0, reason: 'The page never scrolled');
      expect(
        controller.requests,
        isEmpty,
        reason: 'Pinch release is never a pick',
      );
      // Pinching in stops at 1×, where pan returns to the centre.
      final a = await tester.startGesture(centre - const Offset(60, 0));
      final b = await tester.startGesture(centre + const Offset(60, 0));
      await b.moveBy(const Offset(-110, 0));
      await tester.pump();
      expect((controller.zoom, controller.pan), (1.0, Offset.zero));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(controller.requests, isEmpty);
      // A tap still selects after orbit, zoom and pan.
      await tester.tap(diagram);
      expect(controller.requests, hasLength(1));
      controller.requests.single.result.complete(WorkloadMuscle.chest);
      await tester.pumpAndSettle();
      expect(body(tester).selectedRegion, WorkloadMuscle.chest);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a tap within slop picks, a cancelled touch does not, and a second finger turns a tap into a pinch',
    (tester) async {
      final controller = await pumpExplorer(tester);
      final centre = tester.getCenter(diagram);
      final finger = await tester.startGesture(centre);
      await finger.moveBy(const Offset(6, -6));
      await finger.up();
      await tester.pump();
      expect(controller.requests, hasLength(1));
      expect(
        controller.requests.single.position,
        centre + const Offset(6, -6) - tester.getTopLeft(diagram),
      );
      expect((controller.yaw, controller.pitch), (0.0, 0.0));
      final cancelled = await tester.startGesture(centre);
      await cancelled.cancel();
      await tester.pump();
      expect(controller.requests, hasLength(1));
      final a = await tester.startGesture(centre, pointer: 7);
      final b = await tester.startGesture(centre + const Offset(30, 0));
      await b.up();
      await a.up();
      await tester.pump();
      expect(controller.requests, hasLength(1), reason: 'No pick after two');
      // The earlier tap's pick is now stale and cannot select.
      controller.requests.single.result.complete(WorkloadMuscle.quads);
      await tester.pumpAndSettle();
      expect(body(tester).selectedRegion, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'zoom overlay sits inside the canvas bottom-right, works, bounds and never picks',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final controller = await pumpExplorer(tester);
      expect(zoomIn, findsNothing, reason: 'Zoom appears with drawn artwork');
      await reportReady(tester);
      final canvas = tester.getRect(diagram);
      final inRect = tester.getRect(zoomIn), outRect = tester.getRect(zoomOut);
      for (final rect in [inRect, outRect]) {
        expect(canvas.contains(rect.topLeft), isTrue);
        expect(
          canvas.contains(rect.bottomRight - const Offset(.1, .1)),
          isTrue,
        );
        expect(rect.shortestSide, greaterThanOrEqualTo(48));
      }
      expect(canvas.right - inRect.right, lessThanOrEqualTo(8));
      expect(canvas.bottom - inRect.bottom, lessThanOrEqualTo(8));
      expect(outRect.right, lessThanOrEqualTo(inRect.left));
      for (final key in ['front', 'back', 'reset']) {
        final rect = tester.getRect(find.byKey(Key('catalog-body-$key')));
        expect(rect.bottom, lessThanOrEqualTo(canvas.top), reason: key);
      }
      expect(
        tester.getSemantics(zoomOut),
        isSemantics(
          tooltip: 'Zoom out',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      // A disabled button absorbs the tap: nothing beneath is picked.
      await tester.tap(zoomOut, warnIfMissed: false);
      await tester.pump();
      expect(controller.zoom, 1);
      for (var i = 0; i < 4; i++) {
        await tester.tap(zoomIn);
        await tester.pump();
      }
      expect(controller.zoom, 3);
      expect(tester.widget<IconButton>(zoomIn).onPressed, isNull);
      expect(
        tester.getSemantics(zoomIn),
        isSemantics(
          tooltip: 'Zoom in',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      await tester.tap(zoomOut);
      await tester.pump();
      expect(controller.zoom, 2.5);
      expect(
        tester.getSemantics(zoomOut),
        isSemantics(
          tooltip: 'Zoom out',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(controller.requests, isEmpty, reason: 'Overlay taps never pick');
      // A drag starting on a button is the button's, never an orbit.
      await tester.drag(zoomOut, const Offset(-60, -60));
      await tester.pump();
      expect((controller.yaw, controller.pitch), (0.0, 0.0));
      await tester.tap(find.byKey(const Key('catalog-body-reset')));
      await tester.pump();
      expect(controller.zoom, 1);
      expect(controller.pan, Offset.zero);
      expect(controller.requests, isEmpty);
      // Failed artwork drops the overlay; Retry stays in the row.
      body(tester).onStatus!(CharacterBodyStatus.error);
      await tester.pumpAndSettle();
      expect(zoomIn, findsNothing);
      expect(find.byKey(const Key('catalog-body-retry')), findsOneWidget);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'zoom overlay layout sweep: 320/412dp, 1x/2x text, both themes, four locales',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = discoveryState();
      addTearDown(state.dispose);
      for (final width in [320.0, 412.0]) {
        tester.view.physicalSize = Size(width, 640);
        for (final scale in [1.0, 2.0]) {
          for (final brightness in Brightness.values) {
            for (final locale in ['en', 'it', 'de', 'es']) {
              final where = '$width $scale $brightness $locale';
              await tester.pumpWidget(
                discoveryApp(
                  Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: CatalogMuscleExplorer(
                        key: ValueKey(where),
                        index: state.index(locale),
                      ),
                    ),
                  ),
                  locale: locale,
                  brightness: brightness,
                ),
              );
              await tester.pumpAndSettle();
              await reportReady(tester);
              final canvas = tester.getRect(diagram);
              final controls = [
                for (final key in ['front', 'back', 'reset'])
                  tester.getRect(find.byKey(Key('catalog-body-$key'))),
              ];
              for (final button in [zoomIn, zoomOut]) {
                final rect = tester.getRect(button);
                expect(rect.shortestSide, greaterThanOrEqualTo(48));
                expect(
                  canvas.intersect(rect).size,
                  rect.size,
                  reason: '$where: inside the canvas',
                );
                expect(rect.center.dx, greaterThan(canvas.center.dx));
                expect(rect.center.dy, greaterThan(canvas.center.dy));
                for (final control in controls) {
                  expect(rect.overlaps(control), isFalse, reason: where);
                }
              }
              expect(tester.takeException(), isNull, reason: where);
              await tester.tap(find.byKey(const Key('catalog-muscle-info')));
              await tester.pumpAndSettle();
              expectNoSplitWords(
                tester,
                within: find.byType(CatalogMuscleExplorer),
                where: where,
              );
              expect(tester.takeException(), isNull, reason: where);
            }
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'compact disclosures retain readable controls at narrow large text in all locales',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = discoveryState();
      addTearDown(state.dispose);
      for (final width in [320.0, 412.0]) {
        tester.view.physicalSize = Size(width, 640);
        for (final locale in ['en', 'it', 'de', 'es']) {
          for (final brightness in Brightness.values) {
            await tester.pumpWidget(
              discoveryApp(
                Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(2)),
                    child: CatalogMuscleExplorer(
                      key: ValueKey((width, locale, brightness)),
                      index: state.index(locale),
                      selected: 'core',
                    ),
                  ),
                ),
                locale: locale,
                brightness: brightness,
              ),
            );
            await tester.pumpAndSettle();
            expect(
              muscle('core'),
              findsNothing,
              reason: 'Full list starts behind its disclosure',
            );
            await tester.tap(find.byKey(const Key('catalog-muscle-info')));
            await tester.pumpAndSettle();
            await openList(tester);
            await tester.ensureVisible(muscle('core'));
            await tester.tap(muscle('core'));
            await tester.pumpAndSettle();
            expect(body(tester).selectedRegion, WorkloadMuscle.core);
            expect(
              tester.takeException(),
              isNull,
              reason: '$width $locale $brightness',
            );
            await tester.pumpWidget(const SizedBox());
          }
        }
      }
    },
  );

  testWidgets(
    'sheet carries artwork preference and reduced motion without autoplay',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final settings = ArtworkSettings();
      addTearDown(settings.dispose);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      String? result;
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsService>.value(
          value: settings,
          child: discoveryApp(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showCatalogMuscleExplorer(
                  context,
                  index: state.index('en'),
                  selected: 'back',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(body(tester).style, CharacterBodyStyle.female);
      expect(body(tester).reducedMotion, isTrue);
      expect(body(tester).controller.paused, isTrue);
      expect(body(tester).controller.yaw, math.pi);
      await tester.tap(find.byTooltip('Done'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await openList(tester);
      await tester.ensureVisible(
        find.byKey(const Key('catalog-muscle-unclassified')),
      );
      await tester.tap(find.byKey(const Key('catalog-muscle-unclassified')));
      await tester.pumpAndSettle();
      expect(result, 'unclassified');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
