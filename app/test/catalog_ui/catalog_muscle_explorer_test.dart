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

/// A 412 dp phone shows the canvas beside the list; at 320 dp they stack.
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
bool rowSelected(WidgetTester tester, String key) =>
    tester.widget<CatalogMuscleRow>(muscle(key)).selected;

/// A point outside the canvas where a vertical drag scrolls: the stacked
/// page just below the canvas, or the list column beside it.
Offset outsideCanvas(WidgetTester tester) => pageScroll.evaluate().isNotEmpty
    ? tester.getRect(diagram).bottomCenter + const Offset(0, 16)
    : tester.getCenter(listScroll);
Finder get pageScroll =>
    find.byKey(const Key('catalog-muscle-explorer-scroll'));
Finder get listScroll => find.byKey(const Key('catalog-muscle-list-scroll'));
Finder get zoomIn => find.byKey(const Key('catalog-body-zoom-in'));
Finder get zoomOut => find.byKey(const Key('catalog-body-zoom-out'));

ScrollPosition scrollOf(WidgetTester tester, Finder view) => tester
    .state<ScrollableState>(
      find.descendant(of: view, matching: find.byType(Scrollable)),
    )
    .position;

/// What scrolls beside the canvas: the stacked page, or the list column.
ScrollPosition explorerScroll(WidgetTester tester) => scrollOf(
  tester,
  pageScroll.evaluate().isNotEmpty ? pageScroll : listScroll,
);

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

/// Stacked, scrolls the page back to the canvas; beside the list it never
/// leaves the screen.
Future<void> revealArtwork(WidgetTester tester) async {
  if (pageScroll.evaluate().isEmpty) return;
  scrollOf(tester, pageScroll).jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> tapRow(WidgetTester tester, String key) async {
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
      expect(rowSelected(tester, 'chest'), isTrue);
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
        await tapRow(tester, group.key);
        await tester.pump();
        expect(rowSelected(tester, group.key), isTrue);
        expect(
          groups.where((g) => rowSelected(tester, g.key)),
          hasLength(1),
          reason: 'One row is selected',
        );
        expect(
          tester.getSize(muscle(group.key)).height,
          greaterThanOrEqualTo(48),
        );
        expect(body(tester).selectedRegion, WorkloadMuscle.fromKey(group.key));
      }
      await tapRow(tester, 'core');
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
        expect(rowSelected(tester, region.name), isTrue);
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
    'a list choice turns to the view its group faces; canvas taps keep the view',
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
        await tapRow(tester, group);
        await tester.pumpAndSettle();
        expect((controller.yaw, controller.pitch), (yaw, 0.0), reason: group);
        expect(controller.paused, isTrue);
        expect(body(tester).selectedRegion, WorkloadMuscle.fromKey(group));
      }
      await tapRow(tester, 'abductors');
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
    'new taps, list choices, turn, retry and hiding discard older picks',
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
            await tapRow(tester, 'biceps');
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
      'one-finger drag orbits both axes, clamps pitch and owns the canvas beside a scrolling list at $width dp',
      (tester) async {
        final controller = await pumpExplorer(tester, width: width);
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
        await tester.dragFrom(outsideCanvas(tester), const Offset(0, -200));
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
        await tapRow(tester, 'abductors');
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
    'layout sweep: 320/412dp, 1x/2x text, both themes, four locales',
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
              final columns = width == 412 && scale == 1;
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
              final canvas = tester.getRect(diagram);
              final list = tester.getRect(
                find.byKey(const Key('catalog-muscle-list')),
              );
              // The list is always there: no disclosure, every row built.
              expect(
                find.byKey(const Key('catalog-muscle-list-link')),
                findsNothing,
              );
              expect(find.byType(CatalogMuscleRow), findsNWidgets(14));
              if (columns) {
                expect(pageScroll, findsNothing, reason: where);
                expect(list.left, greaterThan(canvas.right), reason: where);
                expect(list.top, lessThan(canvas.center.dy), reason: where);
              } else {
                expect(listScroll, findsNothing, reason: where);
                expect(list.top, greaterThan(canvas.bottom), reason: where);
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
              for (final row in find.byType(CatalogMuscleRow).evaluate()) {
                final size = (row.renderObject! as RenderBox).size;
                expect(size.height, greaterThanOrEqualTo(48), reason: where);
              }
              if (columns) {
                // Beside the canvas, every label fits without an ellipsis.
                for (final text
                    in find
                        .descendant(
                          of: find.byType(CatalogMuscleRow),
                          matching: find.byType(RichText),
                        )
                        .evaluate()) {
                  final paragraph = text.renderObject! as RenderParagraph;
                  expect(
                    paragraph.didExceedMaxLines,
                    isFalse,
                    reason: '$where: ${paragraph.text.toPlainText()}',
                  );
                }
              }
              expectNoSplitWords(
                tester,
                within: find.byType(CatalogMuscleExplorer),
                where: where,
              );
              await tester.tap(find.byKey(const Key('catalog-muscle-info')));
              await tester.pumpAndSettle();
              await tapRow(tester, 'calves');
              await tester.pumpAndSettle();
              expect(body(tester).selectedRegion, WorkloadMuscle.calves);
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

  testWidgets('from 360 dp the canvas fills the sheet height beside the list', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = discoveryState();
    addTearDown(state.dispose);
    for (final size in [const Size(412, 900), const Size(360, 640)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        discoveryApp(
          CatalogMuscleExplorer(key: ValueKey(size), index: state.index('en')),
        ),
      );
      await tester.pumpAndSettle();
      await reportReady(tester);
      final canvas = tester.getRect(diagram);
      final list = tester.getRect(listScroll);
      final show = tester.getRect(
        find.byKey(const Key('catalog-muscle-show-exercises')),
      );
      // About 55% of the 16 dp-inset width, less the 12 dp gap.
      expect(
        canvas.width,
        closeTo((size.width - 44) * .55, 1),
        reason: '$size',
      );
      expect(canvas.left, 16);
      expect(list.left, closeTo(canvas.right + 12, 1));
      expect(list.right, closeTo(size.width - 16, 1));
      // Only the selected-muscle label lies between canvas and the button.
      final label = tester.getRect(find.text('Select muscle'));
      expect(label.top, greaterThanOrEqualTo(canvas.bottom));
      expect(show.top - canvas.bottom, lessThan(label.height + 40));
      expect(list.bottom, lessThanOrEqualTo(show.top));
      expect(canvas.height, greaterThan(size.height * .55), reason: '$size');
      // The list scrolls on its own; the canvas holds still.
      final scroll = scrollOf(tester, listScroll);
      expect(scroll.maxScrollExtent, greaterThan(0), reason: '$size');
      await tester.dragFrom(
        tester.getCenter(listScroll),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(0));
      expect(tester.getRect(diagram), canvas);
      expect(body(tester).visible, isTrue);
    }
    // Just below 360 dp the two stack.
    tester.view.physicalSize = const Size(359, 640);
    await tester.pumpAndSettle();
    expect(listScroll, findsNothing);
    expect(pageScroll, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (width, scale) in [(320.0, 1.0), (320.0, 2.0), (412.0, 2.0)]) {
    testWidgets(
      'at $width dp and ${scale}x text a taller canvas stacks above the inline list',
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
        expect(listScroll, findsNothing);
        final canvas = tester.getRect(diagram);
        // 55% of the sheet's 94% of the screen, never below the old 300 dp,
        // leaving 64 dp of the page below a full-width canvas; past the area
        // cap it narrows, centred.
        final page = tester.getRect(pageScroll).height;
        final height = math.min(math.max(300, 640 * .94 * .55), page - 64);
        expect(canvas.height, closeTo(height, .5));
        expect(
          canvas.width,
          closeTo(math.min(width - 32, 125000 / height), .5),
        );
        expect(canvas.center.dx, closeTo(width / 2, .5));
        expect(
          tester.getRect(find.byKey(const Key('catalog-muscle-list'))).top,
          greaterThan(canvas.bottom),
        );
        // The rows follow on the same page, without a disclosure.
        await tapRow(tester, 'triceps');
        await tester.pumpAndSettle();
        expect(rowSelected(tester, 'triceps'), isTrue);
        expect(body(tester).selectedRegion, WorkloadMuscle.triceps);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a canvas pick scrolls the list column to its row; stacked, the page holds',
    (tester) async {
      final controller = await pumpExplorer(tester);
      final scroll = scrollOf(tester, listScroll);
      Rect viewport() => tester.getRect(listScroll);
      bool rowInView(String key) {
        final row = tester.getRect(muscle(key));
        return row.top >= viewport().top - .5 &&
            row.bottom <= viewport().bottom + .5;
      }

      expect(rowInView('triceps'), isFalse, reason: 'Below the fold at 640');
      await tester.tap(diagram);
      controller.requests.last.result.complete(WorkloadMuscle.triceps);
      await tester.pumpAndSettle();
      expect(rowSelected(tester, 'triceps'), isTrue);
      expect(rowInView('triceps'), isTrue);
      expect(scroll.pixels, greaterThan(0));
      expect(controller.yaw, 0, reason: 'A pick never turns the body');
      // A row already in view does not move the list.
      final offset = scroll.pixels;
      await tester.tap(diagram);
      controller.requests.last.result.complete(WorkloadMuscle.shoulders);
      await tester.pumpAndSettle();
      expect(rowInView('shoulders'), isTrue);
      expect(scroll.pixels, offset);
      // And back up for one above it.
      await tester.tap(diagram);
      controller.requests.last.result.complete(WorkloadMuscle.abductors);
      await tester.pumpAndSettle();
      expect(rowSelected(tester, 'abductors'), isTrue);
      expect(rowInView('abductors'), isTrue);
      // A list choice selects on the canvas.
      await tapRow(tester, 'calves');
      await tester.pump();
      expect(body(tester).selectedRegion, WorkloadMuscle.calves);
      expect(rowSelected(tester, 'abductors'), isFalse);
      await tester.pumpWidget(const SizedBox());

      // Opening on a group further down starts with its row in view.
      await pumpExplorer(tester, selected: 'triceps');
      expect(rowInView('triceps'), isTrue);
      expect(rowSelected(tester, 'triceps'), isTrue);
      await tester.pumpWidget(const SizedBox());

      // Stacked, scrolling to the row would move the canvas from the finger.
      final stacked = await pumpExplorer(tester, width: 320);
      final page = scrollOf(tester, pageScroll);
      await tester.tap(diagram);
      stacked.requests.last.result.complete(WorkloadMuscle.triceps);
      await tester.pumpAndSettle();
      expect(page.pixels, 0);
      expect(rowSelected(tester, 'triceps'), isTrue);
      expect(find.text('Show exercises · Triceps'), findsOneWidget);
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
        // Beside the list the canvas would be under 300 dp: it stacks.
        expect(listScroll, findsNothing);
        final page = tester.getRect(pageScroll);
        final canvas = tester.getRect(diagram);
        // Square, as tall as the old canvas or the whole page allows, with
        // margins beside it that scroll the page.
        expect(canvas.height, closeTo(math.min(300, page.height), .5));
        expect(canvas.width, closeTo(canvas.height, .5));
        expect(canvas.left - page.left, greaterThanOrEqualTo(48));
        expect(
          canvas.width * canvas.height,
          lessThanOrEqualTo(125000 + 1),
          reason: 'Within the area cap',
        );
        final scroll = scrollOf(tester, pageScroll);
        await tester.dragFrom(
          Offset(page.left + 24, canvas.center.dy),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        expect(scroll.pixels, greaterThan(0));
        await tapRow(tester, 'calves');
        await tester.pumpAndSettle();
        expect(body(tester).selectedRegion, WorkloadMuscle.calves);
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
    'on tall and wide screens the canvas stays within the old area, narrowing before it shortens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final state = discoveryState();
      addTearDown(state.dispose);
      for (final (size, scale, columns) in [
        (const Size(412, 915), 1.0, true),
        (const Size(412, 915), 2.0, false),
        (const Size(640, 1200), 1.0, true),
        (const Size(1024, 1366), 1.0, true),
        (const Size(600, 1000), 2.0, false),
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
        expect(listScroll, columns ? findsOneWidget : findsNothing);
        final canvas = tester.getSize(diagram);
        expect(
          canvas.width * canvas.height,
          lessThanOrEqualTo(125000 + 1),
          reason: where,
        );
        expect(canvas.height, greaterThanOrEqualTo(300), reason: where);
        expect(canvas.height, greaterThan(canvas.width), reason: where);
        if (!columns) {
          expect(canvas.height, lessThanOrEqualTo(420), reason: where);
        }
        // The drawn surface is what the picks measure.
        expect(tester.getSize(find.byType(CharacterBody)), canvas);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'choosing the selected row again keeps the view the person turned to',
    (tester) async {
      final controller = await pumpExplorer(tester);
      await tapRow(tester, 'hamstrings');
      await tester.pumpAndSettle();
      expect(controller.yaw, math.pi);
      controller.orbitBy(.4, .2);
      final turned = (controller.yaw, controller.pitch);
      await tapRow(tester, 'hamstrings');
      await tester.pumpAndSettle();
      expect((controller.yaw, controller.pitch), turned);
      expect(rowSelected(tester, 'hamstrings'), isTrue);
      // A different row still turns to its own view.
      await tapRow(tester, 'chest');
      await tester.pumpAndSettle();
      expect((controller.yaw, controller.pitch), (0.0, 0.0));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('each muscle row is one selectable button node with its label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpExplorer(tester, selected: 'chest');
    for (final (key, label, selected) in [
      ('chest', 'Chest', true),
      ('biceps', 'Biceps', false),
      ('unclassified', 'Unclassified', false),
    ]) {
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
      // No other node over the row carries its label or takes its tap.
      final row = tester.getRect(muscle(key));
      bool over(SemanticsNode other) => row.contains(
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
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'switching layouts keeps the canvas surface, view and selection',
    (tester) async {
      final controller = await pumpExplorer(tester, selected: 'back');
      final element = tester.element(find.byType(CharacterBody));
      controller.zoomBy(.5);
      await tester.pump();
      tester.view.physicalSize = const Size(320, 640);
      await tester.pumpAndSettle();
      expect(pageScroll, findsOneWidget);
      expect(
        tester.element(find.byType(CharacterBody)),
        same(element),
        reason: 'The native surface moves rather than restarting',
      );
      expect((controller.yaw, controller.zoom), (math.pi, 1.5));
      expect(rowSelected(tester, 'back'), isTrue);
      tester.view.physicalSize = const Size(412, 640);
      await tester.pumpAndSettle();
      expect(listScroll, findsOneWidget);
      expect(tester.element(find.byType(CharacterBody)), same(element));
      expect(body(tester).visible, isTrue);
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
