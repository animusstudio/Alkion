import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:alkion/catalog_ui/catalog_muscle_explorer.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// A 412×640 dp phone shows the full layout (a canvas of 380×312 dp); at
/// 320 dp the canvas, label and strip stack in a scrolling page.
void explorerPhone(WidgetTester tester, {double width = 412}) {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

CharacterBody body(WidgetTester tester) =>
    tester.widget<CharacterBody>(find.byType(CharacterBody));
Finder get diagram => find.byKey(const Key('catalog-body-diagram'));
Finder muscle(String key) => find.byKey(ValueKey('catalog-muscle-$key'));
bool chipSelected(WidgetTester tester, String key) =>
    tester.widget<CatalogMuscleChip>(muscle(key)).selected;

/// A point outside the canvas where a drag scrolls: the stacked page just
/// below the canvas, or the strip.
Offset outsideCanvas(WidgetTester tester) => pageScroll.evaluate().isNotEmpty
    ? tester.getRect(diagram).bottomCenter + const Offset(0, 16)
    : tester.getCenter(strip);
Finder get pageScroll =>
    find.byKey(const Key('catalog-muscle-explorer-scroll'));
Finder get strip => find.byKey(const Key('catalog-muscle-strip'));

/// How far a chip's centre lies from the strip's centre.
double offCentre(WidgetTester tester, String key) =>
    tester.getCenter(muscle(key)).dx - tester.getCenter(strip).dx;
Finder get zoomIn => find.byKey(const Key('catalog-body-zoom-in'));
Finder get zoomOut => find.byKey(const Key('catalog-body-zoom-out'));

/// The view's own scrollable: the first in the tree below it, so the
/// stacked page's, not the strip's within it.
ScrollPosition scrollOf(WidgetTester tester, Finder view) => tester
    .state<ScrollableState>(
      find.descendant(of: view, matching: find.byType(Scrollable)).first,
    )
    .position;

/// What scrolls outside the canvas: the stacked page, or the strip.
ScrollPosition explorerScroll(WidgetTester tester) =>
    scrollOf(tester, pageScroll.evaluate().isNotEmpty ? pageScroll : strip);

/// The explorer's own status; zoom appears with ready artwork. The host has no
/// WebView, so tests report ready through the canvas's status callback.
Future<void> reportReady(WidgetTester tester) async {
  body(tester).onStatus!(CharacterBodyStatus.ready);
  await tester.pumpAndSettle();
}

Future<PendingBodyController> pumpExplorer(
  WidgetTester tester, {
  String? selected,
  double width = 412,
}) async {
  explorerPhone(tester, width: width);
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

/// Stacked, scrolls the page back to the canvas; in the full layout it never
/// leaves the screen.
Future<void> revealArtwork(WidgetTester tester) async {
  if (pageScroll.evaluate().isEmpty) return;
  scrollOf(tester, pageScroll).jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> tapChip(WidgetTester tester, String key) async {
  await tester.ensureVisible(muscle(key));
  await tester.tap(muscle(key));
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
        // The body skeleton sweeps while the artwork loads, so time is pumped
        // rather than settled until the native ready status below.
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          find.byKey(const Key('character-body-loading-silhouette')),
          findsOneWidget,
        );
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
      expect(chipSelected(tester, 'chest'), isTrue);
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
    'chip selection highlights every region and stays available without artwork',
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
        await tapChip(tester, group.key);
        await tester.pump();
        expect(chipSelected(tester, group.key), isTrue);
        expect(
          groups.where((g) => chipSelected(tester, g.key)),
          hasLength(1),
          reason: 'One chip is selected',
        );
        expect(
          tester.getSize(muscle(group.key)).height,
          greaterThanOrEqualTo(48),
        );
        expect(body(tester).selectedRegion, WorkloadMuscle.fromKey(group.key));
      }
      await tapChip(tester, 'core');
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
        expect(chipSelected(tester, region.name), isTrue);
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
    'a chip choice turns to the view its group faces; canvas taps keep the view',
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
      // The same table as the opening view: posterior groups face back, the
      // lateral abductor field holds the side, every other group the front.
      for (final (group, yaw) in [
        ('chest', 0.0),
        ('hamstrings', math.pi),
        ('adductors', 0.0),
        ('triceps', math.pi),
        ('core', 0.0),
        ('abductors', math.pi / 2),
        ('quads', 0.0),
        ('calves', math.pi),
      ]) {
        // Tilt first: the choice levels the camera as Front and Back do.
        controller.orbitBy(.3, .2);
        await tapChip(tester, group);
        await tester.pumpAndSettle();
        expect((controller.yaw, controller.pitch), (yaw, 0.0), reason: group);
        expect(controller.paused, isTrue);
        expect(body(tester).selectedRegion, WorkloadMuscle.fromKey(group));
      }
      await tapChip(tester, 'abductors');
      await tester.pumpAndSettle();
      // A tap on the field from the side returns and keeps abductors.
      await revealArtwork(tester);
      await tester.tap(diagram);
      controller.requests.last.result.complete(WorkloadMuscle.abductors);
      await tester.pumpAndSettle();
      expect(body(tester).selectedRegion, WorkloadMuscle.abductors);
      expect(controller.yaw, math.pi / 2);
      // A tap never turns the body: abductors or a posterior group picked
      // from the front keep the front.
      await tester.tap(find.byKey(const Key('catalog-body-front')));
      await tester.pumpAndSettle();
      for (final region in [WorkloadMuscle.abductors, WorkloadMuscle.glutes]) {
        await tester.tap(diagram);
        controller.requests.last.result.complete(region);
        await tester.pumpAndSettle();
        expect(body(tester).selectedRegion, region);
        expect(controller.yaw, 0, reason: region.name);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new taps, chip choices, turn, retry and hiding discard older picks',
    (tester) async {
      // Stacked, so scrolling the page can hide the canvas.
      explorerPhone(tester, width: 320);
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
        'chip',
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
          case 'chip':
            await tapChip(tester, 'biceps');
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
            await tester.dragFrom(outsideCanvas(tester), const Offset(0, -500));
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

  for (final width in [412.0, 320.0]) {
    testWidgets(
      'one-finger drag orbits both axes, clamps pitch and owns the canvas above a scrolling strip or page at $width dp',
      (tester) async {
        final controller = await pumpExplorer(tester, width: width);
        // Drawn artwork: failed artwork stacks a 120 dp canvas that leaves
        // the short page nothing to scroll.
        await reportReady(tester);
        final scroll = explorerScroll(tester);
        expect(scroll.maxScrollExtent, greaterThan(40));
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
        expect(scroll.pixels, 0, reason: 'The canvas owns its drags');
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
        // A drag outside the canvas still scrolls: the stacked page
        // vertically, or the strip sideways.
        final stacked = pageScroll.evaluate().isNotEmpty;
        expect(stacked, width == 320);
        await tester.dragFrom(
          outsideCanvas(tester),
          stacked ? const Offset(0, -200) : const Offset(-200, 0),
        );
        await tester.pumpAndSettle();
        expect(scroll.pixels, greaterThan(40));
        expect((controller.yaw, controller.pitch), view);
        expect(controller.requests, isEmpty);
        // Front and a chip choice of abductors (the side view) level the camera.
        await revealArtwork(tester);
        await tester.tap(find.byKey(const Key('catalog-body-front')));
        await tester.pump();
        expect((controller.yaw, controller.pitch), (0.0, 0.0));
        await tester.drag(diagram, const Offset(0, 120));
        await tester.pump();
        expect(controller.pitch, greaterThan(0));
        await tapChip(tester, 'abductors');
        await tester.pumpAndSettle();
        expect((controller.yaw, controller.pitch), (math.pi / 2, 0.0));
        expect(body(tester).selectedRegion, WorkloadMuscle.abductors);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a second finger after an orbit pinches around its focal point and pans without jumps',
    (tester) async {
      final controller = await pumpExplorer(tester);
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
      // The finger left after a pinch holds the view within slop, so the end
      // of a pinch never jump-rotates the body.
      await first.moveBy(const Offset(6, -6));
      await tester.pump();
      expect((controller.yaw, controller.pitch), (yaw, 0.0));
      // Past slop it re-bases there, then turns continuously. Zoomed, its
      // vertical movement pans instead of tilting.
      await first.moveBy(const Offset(20, 0));
      await tester.pump();
      expect((controller.yaw, controller.pitch), (yaw, 0.0));
      expect((controller.zoom, controller.pan), viewport);
      await first.moveBy(const Offset(20, 10));
      await tester.pump();
      expect(controller.yaw, closeTo(yaw + 20 * .009, 1e-9));
      expect(controller.pitch, 0.0);
      expect(controller.zoom, viewport.$1);
      expect(controller.pan.dx, viewport.$2.dx);
      expect(
        controller.pan.dy,
        closeTo(viewport.$2.dy + 10 / size.height, 1e-9),
      );
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
    'layout sweep: 320/360/412 dp, 1x/2x text, both themes, four locales',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = discoveryState();
      addTearDown(state.dispose);
      for (final size in [
        const Size(320, 640),
        const Size(360, 760),
        const Size(412, 900),
      ]) {
        tester.view.physicalSize = size;
        for (final scale in [1.0, 2.0]) {
          for (final brightness in Brightness.values) {
            for (final locale in ['en', 'it', 'de', 'es']) {
              final where = '$size $scale $brightness $locale';
              // The full layout from 360×760 at normal text; small phones
              // and large text on mid-size ones stack.
              final full =
                  size.width == 412 || (size.width == 360 && scale == 1);
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
                        selected: 'core',
                      ),
                    ),
                  ),
                  locale: locale,
                  brightness: brightness,
                ),
              );
              await tester.pumpAndSettle();
              await reportReady(tester);
              expect(tester.takeException(), isNull, reason: where);
              expect(pageScroll, full ? findsNothing : findsOneWidget);
              final canvas = tester.getRect(diagram);
              final stripRect = tester.getRect(strip);
              final show = tester.getRect(
                find.byKey(const Key('catalog-muscle-show-exercises')),
              );
              // The canvas spans the sheet inside its 16 dp insets.
              expect(canvas.left, closeTo(16, .5), reason: where);
              expect(canvas.width, closeTo(size.width - 32, .5), reason: where);
              // The strip is always there, below the canvas and label, and
              // every chip is built: no disclosure.
              expect(find.byType(CatalogMuscleChip), findsNWidgets(14));
              expect(stripRect.top, greaterThan(canvas.bottom), reason: where);
              expect(stripRect.width, size.width, reason: where);
              if (full) {
                // Nothing but the strip scrolls: it ends above the button.
                expect(stripRect.bottom, lessThanOrEqualTo(show.top));
                expect(show.top - stripRect.bottom, lessThanOrEqualTo(12.5));
                expect(canvas.height, greaterThanOrEqualTo(300), reason: where);
              }
              final controls = [
                for (final key in ['front', 'back', 'reset'])
                  tester.getRect(find.byKey(Key('catalog-body-$key'))),
              ];
              for (final control in controls) {
                expect(control.bottom, lessThanOrEqualTo(canvas.top));
                expect(control.left, greaterThanOrEqualTo(canvas.left - .5));
                expect(control.right, lessThanOrEqualTo(canvas.right + .5));
              }
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
              for (final chip in find.byType(CatalogMuscleChip).evaluate()) {
                final size = (chip.renderObject! as RenderBox).size;
                expect(size.height, greaterThanOrEqualTo(48), reason: where);
              }
              // Every chip label fits its chip on one line: no ellipsis, no
              // clipping, no wrap.
              for (final text
                  in find
                      .descendant(
                        of: find.byType(CatalogMuscleChip),
                        matching: find.byType(RichText),
                      )
                      .evaluate()) {
                final paragraph = text.renderObject! as RenderParagraph;
                final label = paragraph.text.toPlainText();
                expect(paragraph.didExceedMaxLines, isFalse, reason: label);
                expect(
                  paragraph.getMaxIntrinsicWidth(double.infinity),
                  lessThanOrEqualTo(paragraph.size.width + .01),
                  reason: '$where: $label',
                );
              }
              // The opening selection sits at the strip's centre.
              expect(offCentre(tester, 'core').abs(), lessThan(.5));
              expectNoSplitWords(
                tester,
                within: find.byType(CatalogMuscleExplorer),
                where: where,
              );
              await tester.tap(find.byKey(const Key('catalog-muscle-info')));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: where);
              await tapChip(tester, 'calves');
              await tester.pumpAndSettle();
              expect(body(tester).selectedRegion, WorkloadMuscle.calves);
              expect(offCentre(tester, 'calves').abs(), lessThan(.5));
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
    'the full layout: the canvas fills the width and the height down to the label and strip',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = discoveryState();
      addTearDown(state.dispose);
      for (final (size, art) in [
        // The A024's 411×911 dp and the 412×900 reference phone.
        (const Size(411, 911), const Size(379, 567.1)),
        (const Size(412, 900), const Size(380, 556.8)),
        (const Size(360, 760), const Size(328, 425.2)),
        (const Size(412, 640), const Size(380, 312.4)),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          discoveryApp(
            CatalogMuscleExplorer(
              key: ValueKey(size),
              index: state.index('en'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await reportReady(tester);
        expect(pageScroll, findsNothing, reason: '$size');
        final canvas = tester.getRect(diagram);
        expect(canvas.size.width, closeTo(art.width, .1), reason: '$size');
        expect(canvas.size.height, closeTo(art.height, .1), reason: '$size');
        final drawn = tester.getSize(find.byType(CharacterBody));
        expect(drawn.width, closeTo(canvas.width, 1e-6));
        expect(drawn.height, closeTo(canvas.height, 1e-6));
        final label = tester.getRect(find.text('Select muscle'));
        final stripRect = tester.getRect(strip);
        final show = tester.getRect(
          find.byKey(const Key('catalog-muscle-show-exercises')),
        );
        // Controls, canvas, label, strip and the pinned button, in order and
        // tight: the canvas takes the rest of the height.
        expect(label.top - canvas.bottom, inInclusiveRange(8, 9));
        expect(stripRect.top, greaterThanOrEqualTo(label.bottom));
        expect(stripRect.top - label.bottom, lessThan(12));
        expect(show.top - stripRect.bottom, closeTo(12, .5));
        // The strip scrolls on its own; the canvas holds still.
        final scroll = scrollOf(tester, strip);
        expect(scroll.maxScrollExtent, greaterThan(500), reason: '$size');
        await tester.drag(strip, const Offset(-300, 0));
        await tester.pumpAndSettle();
        expect(scroll.pixels, greaterThan(0));
        expect(tester.getRect(diagram), canvas);
        expect(body(tester).visible, isTrue);
        // A vertical drag on the strip moves nothing.
        final pixels = scroll.pixels;
        await tester.drag(strip, const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(scroll.pixels, pixels);
        expect(tester.getRect(diagram), canvas);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the info notes cover the canvas in the full layout and follow the strip when stacked',
    (tester) async {
      final controller = await pumpExplorer(tester);
      await tester.tap(find.byKey(const Key('catalog-muscle-info')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const Key('catalog-muscle-info-panel'));
      expect(tester.getRect(panel), tester.getRect(diagram));
      // The panel takes the canvas's touches: no pick, no orbit.
      await tester.tap(panel);
      await tester.drag(panel, const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(controller.requests, isEmpty);
      expect(controller.yaw, 0);
      await tester.tap(find.byKey(const Key('catalog-muscle-info')));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      await tester.pumpWidget(const SizedBox());

      await pumpExplorer(tester, width: 320);
      await tester.tap(find.byKey(const Key('catalog-muscle-info')));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      final notes = tester.getRect(find.textContaining('Tap a muscle'));
      expect(notes.top, greaterThan(tester.getRect(strip).bottom));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'while the notes cover the canvas, its fallback and zoom buttons leave semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpExplorer(tester);
      await reportReady(tester);
      Iterable<SemanticsNode> tooltip(String text) =>
          find.semantics.byPredicate((node) => node.tooltip == text).evaluate();
      Iterable<SemanticsNode> named(String text) =>
          find.semantics.byLabel(text).evaluate();
      expect(tooltip('Zoom in'), hasLength(1));
      expect(tooltip('Zoom out'), hasLength(1));
      final info = find.byKey(const Key('catalog-muscle-info'));
      await tester.tap(info);
      await tester.pumpAndSettle();
      expect(tooltip('Zoom in'), isEmpty);
      expect(tooltip('Zoom out'), isEmpty);
      // Failed artwork speaks its fallback, except under the notes.
      body(tester).onStatus!(CharacterBodyStatus.error);
      await tester.pumpAndSettle();
      expect(named('Artwork unavailable'), isEmpty);
      expect(find.semantics.byLabel(RegExp('^Tap a muscle')), findsOne);
      await tester.tap(info);
      await tester.pumpAndSettle();
      expect(named('Artwork unavailable'), hasLength(1));
      body(tester).onStatus!(CharacterBodyStatus.ready);
      await tester.pumpAndSettle();
      expect(tooltip('Zoom in'), hasLength(1));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (width, scale) in [(320.0, 1.0), (320.0, 2.0), (412.0, 2.0)]) {
    testWidgets(
      'at $width dp and ${scale}x text a taller canvas stacks above the strip',
      (tester) async {
        explorerPhone(tester, width: width);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final state = discoveryState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          discoveryApp(CatalogMuscleExplorer(index: state.index('en'))),
        );
        await tester.pumpAndSettle();
        await reportReady(tester);
        expect(pageScroll, findsOneWidget);
        final canvas = tester.getRect(diagram);
        // 55% of the sheet's 94% of the screen, never below the old 300 dp,
        // leaving 64 dp of the page below a full-width canvas.
        final page = tester.getRect(pageScroll).height;
        final height = math.min(math.max(300, 640 * .94 * .55), page - 64);
        expect(canvas.height, closeTo(height, .5));
        expect(canvas.width, closeTo(width - 32, .5));
        expect(tester.getRect(strip).top, greaterThan(canvas.bottom));
        // The chips follow on the same page, without a disclosure.
        await tapChip(tester, 'triceps');
        await tester.pumpAndSettle();
        expect(chipSelected(tester, 'triceps'), isTrue);
        expect(body(tester).selectedRegion, WorkloadMuscle.triceps);
        expect(offCentre(tester, 'triceps').abs(), lessThan(.5));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a chip choice selects, centres its chip and turns; re-choosing keeps the view',
    (tester) async {
      final controller = await pumpExplorer(tester);
      expect(offCentre(tester, 'abductors').abs(), lessThan(.5));
      await tapChip(tester, 'hamstrings');
      await tester.pumpAndSettle();
      expect(chipSelected(tester, 'hamstrings'), isTrue);
      expect(body(tester).selectedRegion, WorkloadMuscle.hamstrings);
      expect(offCentre(tester, 'hamstrings').abs(), lessThan(.5));
      expect(controller.yaw, math.pi);
      expect(find.text('Show exercises · Hamstrings'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a canvas pick centres its chip without turning; stacked, the page holds',
    (tester) async {
      final controller = await pumpExplorer(tester);
      final scroll = scrollOf(tester, strip);
      for (final region in [
        WorkloadMuscle.triceps,
        WorkloadMuscle.shoulders,
        WorkloadMuscle.abductors,
        WorkloadMuscle.calves,
      ]) {
        await tester.tap(diagram);
        controller.requests.last.result.complete(region);
        await tester.pumpAndSettle();
        expect(chipSelected(tester, region.name), isTrue);
        expect(offCentre(tester, region.name).abs(), lessThan(.5));
        expect(controller.yaw, 0, reason: 'A pick never turns the body');
      }
      expect(scroll.pixels, greaterThan(0));
      // A chip choice selects on the canvas.
      await tapChip(tester, 'quads');
      await tester.pump();
      expect(body(tester).selectedRegion, WorkloadMuscle.quads);
      expect(chipSelected(tester, 'calves'), isFalse);
      await tester.pumpWidget(const SizedBox());

      // Opening on a group further along starts with its chip centred.
      await pumpExplorer(tester, selected: 'triceps');
      expect(offCentre(tester, 'triceps').abs(), lessThan(.5));
      expect(chipSelected(tester, 'triceps'), isTrue);
      await tester.pumpWidget(const SizedBox());

      // Stacked, the strip moves and the page keeps the canvas under the
      // finger.
      final stacked = await pumpExplorer(tester, width: 320);
      final page = scrollOf(tester, pageScroll);
      await tester.tap(diagram);
      stacked.requests.last.result.complete(WorkloadMuscle.triceps);
      await tester.pumpAndSettle();
      expect(page.pixels, 0);
      expect(chipSelected(tester, 'triceps'), isTrue);
      expect(offCentre(tester, 'triceps').abs(), lessThan(.5));
      expect(find.text('Show exercises · Triceps'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a fling or a slow release settles a chip at the centre without selecting',
    (tester) async {
      final controller = await pumpExplorer(tester, selected: 'chest');
      final scroll = scrollOf(tester, strip);
      final keys = [
        for (final chip in find.byType(CatalogMuscleChip).evaluate())
          ((chip.widget.key! as ValueKey<String>).value).substring(
            'catalog-muscle-'.length,
          ),
      ];
      String centred() => keys.reduce(
        (a, b) =>
            offCentre(tester, a).abs() <= offCentre(tester, b).abs() ? a : b,
      );
      expect(centred(), 'chest');
      for (final (offset, speed) in [
        (const Offset(-150, 0), 1500.0),
        (const Offset(-60, 0), 3000.0),
        (const Offset(200, 0), 800.0),
      ]) {
        final before = scroll.pixels;
        await tester.fling(strip, offset, speed);
        await tester.pumpAndSettle();
        final key = centred();
        expect(offCentre(tester, key).abs(), lessThan(.5), reason: '$offset');
        expect(
          scroll.pixels,
          offset.dx < 0 ? greaterThan(before) : lessThan(before),
        );
      }
      // A slow drag released between two chips settles on the nearer one.
      final gesture = await tester.startGesture(tester.getCenter(strip));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-7, 0));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(offCentre(tester, centred()).abs(), lessThan(.5));
      // Scrolling only browses: the selection and view stay.
      expect(chipSelected(tester, 'chest'), isTrue);
      expect(body(tester).selectedRegion, WorkloadMuscle.chest);
      expect(controller.yaw, 0);
      expect(controller.requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a fling into either end settles the end chip at the centre', (
    tester,
  ) async {
    await pumpExplorer(tester, selected: 'core');
    final scroll = scrollOf(tester, strip);
    await tester.fling(strip, const Offset(-600, 0), 4000);
    await tester.pumpAndSettle();
    expect(scroll.pixels, scroll.maxScrollExtent);
    expect(offCentre(tester, 'unclassified').abs(), lessThan(.5));
    await tester.fling(strip, const Offset(600, 0), 4000);
    await tester.pumpAndSettle();
    expect(scroll.pixels, scroll.minScrollExtent);
    expect(offCentre(tester, 'abductors').abs(), lessThan(.5));
    expect(chipSelected(tester, 'core'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a drag held still and released without velocity settles a chip at the centre',
    (tester) async {
      await pumpExplorer(tester, selected: 'chest');
      final scroll = scrollOf(tester, strip);
      final start = scroll.pixels;
      final gesture = await tester.startGesture(tester.getCenter(strip));
      await gesture.moveBy(const Offset(-20, 0));
      await gesture.moveBy(const Offset(-55, 0));
      await tester.pump(const Duration(milliseconds: 16));
      // Held still: the release carries no velocity.
      await tester.pump(const Duration(milliseconds: 600));
      expect(scroll.pixels, isNot(start));
      await gesture.up();
      await tester.pumpAndSettle();
      final centres = [
        for (final chip in find.byType(CatalogMuscleChip).evaluate())
          ((chip.renderObject! as RenderBox).localToGlobal(Offset.zero).dx +
                  (chip.renderObject! as RenderBox).size.width / 2) -
              tester.getCenter(strip).dx,
      ];
      expect(centres.map((c) => c.abs()).reduce(math.min), lessThan(.5));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'assistive scrolling and showing a chip on screen settle a chip at the centre',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpExplorer(tester, selected: 'chest');
      double nearest() => [
        for (final chip in find.byType(CatalogMuscleChip).evaluate())
          (chip.renderObject! as RenderBox)
                  .localToGlobal(
                    (chip.renderObject! as RenderBox).size.center(Offset.zero),
                  )
                  .dx -
              tester.getCenter(strip).dx,
      ].map((c) => c.abs()).reduce(math.min);
      final scroll = scrollOf(tester, strip);
      // Focus moving to a chip off screen shows it, then the strip settles.
      final opening = scroll.pixels;
      final far = tester.getSemantics(muscle('unclassified'));
      far.owner!.performAction(far.id, SemanticsAction.showOnScreen);
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(opening));
      expect(nearest(), lessThan(.5));
      // The strip's own scroll actions move it by part of its width.
      for (final action in [
        SemanticsAction.scrollRight,
        SemanticsAction.scrollLeft,
      ]) {
        // The strip is the only horizontal scroller.
        final node = find.semantics.byAction(action).evaluate().single;
        final before = scroll.pixels;
        node.owner!.performAction(node.id, action);
        await tester.pumpAndSettle();
        expect(scroll.pixels, isNot(before), reason: '$action');
        expect(nearest(), lessThan(.5), reason: '$action');
      }
      expect(chipSelected(tester, 'chest'), isTrue);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'text size and locale changes while open measure the chips again and keep the selection centred',
    (tester) async {
      explorerPhone(tester);
      final state = discoveryState();
      addTearDown(state.dispose);
      final controller = PendingBodyController();
      addTearDown(controller.dispose);
      Future<void> show(String locale, double scale) async {
        await tester.pumpWidget(
          discoveryApp(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: CatalogMuscleExplorer(
                  index: state.index(locale),
                  selected: 'hamstrings',
                  controller: controller,
                ),
              ),
            ),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
      }

      void expectFitted(String where) {
        for (final text
            in find
                .descendant(
                  of: find.byType(CatalogMuscleChip),
                  matching: find.byType(RichText),
                )
                .evaluate()) {
          final paragraph = text.renderObject! as RenderParagraph;
          expect(
            paragraph.getMaxIntrinsicWidth(double.infinity),
            lessThanOrEqualTo(paragraph.size.width + .01),
            reason: '$where: ${paragraph.text.toPlainText()}',
          );
        }
        expect(offCentre(tester, 'hamstrings').abs(), lessThan(.5));
      }

      await show('en', 1);
      final state0 = tester.state(find.byType(CatalogMuscleExplorer));
      final en = tester.getSize(muscle('hamstrings'));
      expectFitted('en');
      await show('es', 1);
      expect(tester.state(find.byType(CatalogMuscleExplorer)), same(state0));
      final es = tester.getSize(muscle('hamstrings'));
      expect(es.width, greaterThan(en.width), reason: 'Isquiotibiales');
      expect(find.text('Isquiotibiales'), findsWidgets);
      expectFitted('es');
      await show('es', 1.5);
      final larger = tester.getSize(muscle('hamstrings'));
      expect(larger.width, greaterThan(es.width));
      expect(larger.height, greaterThanOrEqualTo(48));
      expectFitted('es 1.5x');
      expect(tester.state(find.byType(CatalogMuscleExplorer)), same(state0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(800, 360), const Size(640, 360)]) {
    testWidgets(
      'a short ${size.width.toInt()}×${size.height.toInt()} landscape viewport stacks with a canvas the page can scroll past',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        await reportReady(tester);
        expect(tester.takeException(), isNull);
        // The full layout's canvas would be under 300 dp: it stacks.
        expect(pageScroll, findsOneWidget);
        final page = tester.getRect(pageScroll);
        final canvas = tester.getRect(diagram);
        // Square, as tall as the old canvas or the whole page allows, with
        // margins beside it that scroll the page.
        expect(canvas.height, closeTo(math.min(300, page.height), .5));
        expect(canvas.width, closeTo(canvas.height, .5));
        expect(canvas.left - page.left, greaterThanOrEqualTo(48));
        expect(tester.getRect(strip).top, greaterThan(canvas.bottom));
        final scroll = scrollOf(tester, pageScroll);
        await tester.dragFrom(
          Offset(page.left + 24, canvas.center.dy),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        expect(scroll.pixels, greaterThan(0));
        await tapChip(tester, 'calves');
        await tester.pumpAndSettle();
        expect(body(tester).selectedRegion, WorkloadMuscle.calves);
        expect(offCentre(tester, 'calves').abs(), lessThan(.5));
        // Scrolled back, the canvas still orbits and picks.
        await revealArtwork(tester);
        await tester.drag(diagram, const Offset(60, 0));
        await tester.pumpAndSettle();
        expect(controller.yaw, greaterThan(math.pi));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'phones are uncapped; from a 600 dp sheet the canvas stays within 170,000 dp², narrowing first',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final state = discoveryState();
      addTearDown(state.dispose);
      for (final (size, scale, capped) in [
        (const Size(412, 915), 1.0, false),
        (const Size(412, 915), 2.0, false),
        (const Size(599, 1000), 1.0, false),
        (const Size(640, 1200), 1.0, true),
        (const Size(1024, 1366), 1.0, true),
        (const Size(600, 1000), 2.0, true),
      ]) {
        final where = '$size ${scale}x';
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpWidget(
          discoveryApp(
            CatalogMuscleExplorer(
              key: ValueKey(where),
              index: state.index('en'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await reportReady(tester);
        expect(tester.takeException(), isNull, reason: where);
        final canvas = tester.getSize(diagram);
        if (capped) {
          expect(
            canvas.width * canvas.height,
            lessThanOrEqualTo(170000 + 1),
            reason: where,
          );
          expect(canvas.height, greaterThan(canvas.width), reason: where);
        } else {
          expect(canvas.width, size.width - 32, reason: where);
        }
        expect(canvas.height, greaterThanOrEqualTo(300), reason: where);
        // The drawn surface is what the picks measure.
        expect(tester.getSize(find.byType(CharacterBody)), canvas);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'choosing the selected chip again keeps the view the person turned to',
    (tester) async {
      final controller = await pumpExplorer(tester);
      await tapChip(tester, 'hamstrings');
      await tester.pumpAndSettle();
      expect(controller.yaw, math.pi);
      controller.orbitBy(.4, .2);
      final turned = (controller.yaw, controller.pitch);
      await tapChip(tester, 'hamstrings');
      await tester.pumpAndSettle();
      expect((controller.yaw, controller.pitch), turned);
      expect(chipSelected(tester, 'hamstrings'), isTrue);
      expect(offCentre(tester, 'hamstrings').abs(), lessThan(.5));
      // A different chip still turns to its own view.
      await tapChip(tester, 'chest');
      await tester.pumpAndSettle();
      expect((controller.yaw, controller.pitch), (0.0, 0.0));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'each muscle chip is one selectable button node with its label; the strip adds no label',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpExplorer(tester, selected: 'chest');
      for (final (key, label, selected) in [
        ('chest', 'Chest', true),
        ('biceps', 'Biceps', false),
        ('unclassified', 'Unclassified', false),
      ]) {
        await tester.ensureVisible(muscle(key));
        await tester.pumpAndSettle();
        final node = tester.getSemantics(muscle(key));
        final data = node.getSemanticsData();
        expect(data.label, label);
        expect(data.flagsCollection.isButton, isTrue, reason: label);
        expect(
          data.flagsCollection.isSelected,
          selected ? Tristate.isTrue : Tristate.isFalse,
          reason: label,
        );
        expect(data.hasAction(SemanticsAction.tap), isTrue, reason: label);
        expect(node.childrenCount, 0, reason: 'Glyph and label merge');
        // No other node over the chip carries its label or takes its tap.
        final chip = tester.getRect(muscle(key));
        bool over(SemanticsNode other) => chip.contains(
          MatrixUtils.transformRect(_globalTransform(other), other.rect).center,
        );
        final taps = find.semantics
            .byAction(SemanticsAction.tap)
            .evaluate()
            .where(over);
        expect(taps, [node], reason: label);
        final named = find.semantics.byLabel(label).evaluate().where(over);
        expect(named, [node], reason: label);
      }
      // The strip itself is a plain scrolling container.
      final stripNode = tester.getSemantics(strip);
      expect(stripNode.getSemanticsData().label, isEmpty);
      expect(find.text('Muscle list'), findsNothing);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'switching layouts keeps the canvas surface, view, selection and centred chip',
    (tester) async {
      final controller = await pumpExplorer(tester, selected: 'back');
      final element = tester.element(find.byType(CharacterBody));
      controller.zoomBy(.5);
      await tester.pump();
      expect(pageScroll, findsNothing);
      tester.view.physicalSize = const Size(320, 640);
      await tester.pumpAndSettle();
      expect(pageScroll, findsOneWidget);
      expect(
        tester.element(find.byType(CharacterBody)),
        same(element),
        reason: 'The native surface moves rather than restarting',
      );
      expect((controller.yaw, controller.zoom), (math.pi, 1.5));
      expect(chipSelected(tester, 'back'), isTrue);
      expect(offCentre(tester, 'back').abs(), lessThan(.5));
      tester.view.physicalSize = const Size(412, 640);
      await tester.pumpAndSettle();
      expect(pageScroll, findsNothing);
      expect(tester.element(find.byType(CharacterBody)), same(element));
      expect(body(tester).visible, isTrue);
      expect(offCentre(tester, 'back').abs(), lessThan(.5));
      await tester.pumpWidget(const SizedBox());
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

Matrix4 _globalTransform(SemanticsNode node) {
  final transform = Matrix4.identity();
  for (SemanticsNode? n = node; n != null; n = n.parent) {
    if (n.transform != null) transform.multiply(n.transform!);
  }
  return transform;
}
