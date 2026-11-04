import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:alkion/catalog_ui/catalog_muscle_explorer.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/app_fonts.dart';
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

Future<void> revealArtwork(WidgetTester tester) async {
  final scroll = find.descendant(
    of: find.byKey(const Key('catalog-muscle-explorer-scroll')),
    matching: find.byType(Scrollable),
  );
  tester.state<ScrollableState>(scroll).position.jumpTo(0);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(preloadAppFonts);

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
      expect(tester.widget<ChoiceChip>(muscle('chest')).selected, isTrue);
      expect(find.text('Show exercises · Chest'), findsOneWidget);
      await tester.tapAt(rect.center);
      controller.requests.last.result.complete(null);
      await tester.pump();
      expect(body(tester).selectedRegion, WorkloadMuscle.chest);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'list-only selection clears mapped highlight and stays available without artwork',
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
      await tester.tap(find.byKey(const Key('catalog-muscle-list-link')));
      await tester.pumpAndSettle();
      for (final group
          in state.index('en').browseGroups.where((g) => g.kind == 'muscle')) {
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
      expect(body(tester).selectedRegion, isNull);
      final data = tester.getSemantics(muscle('core')).getSemanticsData();
      expect(data.flagsCollection.isSelected, Tristate.isTrue);
      expect(find.text('Show exercises · Core'), findsOneWidget);
      semantics.dispose();
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
      for (final action in ['list', 'turn', 'retry', 'hide']) {
        await revealArtwork(tester);
        await tester.tap(diagram);
        final pending = controller.requests.last.result;
        switch (action) {
          case 'list':
            await tester.tap(find.byKey(const Key('catalog-muscle-list-link')));
            await tester.pumpAndSettle();
            await tester.ensureVisible(muscle('biceps'));
            await tester.tap(muscle('biceps'));
          case 'turn':
            await tester.tap(find.byKey(const Key('catalog-body-back')));
          case 'retry':
            await tester.tap(find.byKey(const Key('catalog-body-retry')));
          case 'hide':
            await tester.drag(diagram, const Offset(0, -500));
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
    'horizontal drag rotates without picking; vertical drag scrolls without picking',
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
      await tester.drag(diagram, const Offset(90, 0));
      await tester.pump();
      expect(controller.yaw, greaterThan(0));
      expect(controller.paused, isTrue);
      expect(controller.requests, isEmpty);
      final yaw = controller.yaw;
      await tester.drag(diagram, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(controller.yaw, yaw);
      expect(controller.requests, isEmpty);
      expect(body(tester).visible, isFalse);
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
