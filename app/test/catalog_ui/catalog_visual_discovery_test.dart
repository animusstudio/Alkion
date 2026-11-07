import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/catalog_ui/catalog_muscle_explorer.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import 'catalog_discovery_picker_test.dart';
import 'catalog_muscle_explorer_test.dart' show PendingBodyController;

Future<void> captureCatalog(WidgetTester tester, String name) async {
  final directory = Platform.environment['ALKION_CATALOG_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('catalog-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void phone(WidgetTester tester, double width, double scale) {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets(
    'body and chips use the same reviewed target group without enabling secondary',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      final controller = PendingBodyController();
      addTearDown(controller.dispose);
      String? result;
      await tester.pumpWidget(
        discoveryApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => CatalogMuscleExplorer(
                      index: state.index('en'),
                      controller: controller,
                    ),
                  ),
              child: const Text('Explore'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Explore'));
      await tester.pumpAndSettle();
      final diagram = find.byKey(const Key('catalog-body-diagram'));
      await tester.tap(diagram);
      controller.requests.single.result.complete(WorkloadMuscle.chest);
      await tester.pumpAndSettle();
      expect(
        tester.widget<CharacterBody>(find.byType(CharacterBody)).selectedRegion,
        WorkloadMuscle.chest,
      );
      expect(
        tester
            .widget<CatalogMuscleChip>(
              find.byKey(const Key('catalog-muscle-chest')),
            )
            .selected,
        isTrue,
      );
      expect(find.text('Show exercises · Chest'), findsOneWidget);
      await tester.tap(find.byKey(const Key('catalog-body-back')));
      await tester.pump();
      // Turning the view never changes the chosen group.
      expect(find.text('Show exercises · Chest'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('catalog-muscle-triceps')),
      );
      await tester.tap(find.byKey(const Key('catalog-muscle-triceps')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('catalog-muscle-show-exercises')));
      await tester.pumpAndSettle();
      expect(result, 'triceps');
      await tester.pumpWidget(
        discoveryApp(CatalogPicker(state: state, multiple: true)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('catalog-browse-muscles')));
      await tester.pumpAndSettle();
      await selectMuscle(tester, 'triceps');
      await openChoice(tester, state, fixtureId(103));
      expect(find.text('Add selected · 1'), findsOneWidget);
      expect(choice(fixtureId(15)), findsNothing);
      expect(find.text('Secondary muscles only'), findsNothing);
      final selectedRow = choice(fixtureId(103));
      await tester.tap(
        find.descendant(of: selectedRow, matching: find.byTooltip('Add again')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 2'), findsOneWidget);
      expect(find.text('Details'), findsNothing); // Repeat opens no dialog.
      await tester.tap(selectedRow);
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 1'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final locale in ['en', 'it', 'de', 'es']) {
    for (final width in [320.0, 412.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final brightness in Brightness.values) {
          testWidgets(
            'body explorer $locale $width $scale ${brightness.name}',
            (tester) async {
              phone(tester, width, scale);
              final state = discoveryState();
              addTearDown(state.dispose);
              final semantics = tester.ensureSemantics();

              await tester.pumpWidget(
                RepaintBoundary(
                  key: const Key('catalog-capture'),
                  child: discoveryApp(
                    CatalogMuscleExplorer(
                      index: state.index(locale),
                      selected: 'chest',
                    ),
                    locale: locale,
                    brightness: brightness,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expectNoSplitWords(tester);
              final show = find.byKey(
                const Key('catalog-muscle-show-exercises'),
              );
              expect(show.hitTestable(), findsOneWidget);
              expect(tester.getSize(show).height, greaterThanOrEqualTo(48));
              if (locale == 'en' && width == 412 && scale == 1) {
                await captureCatalog(
                  tester,
                  'explorer-unavailable-front-${brightness.name}',
                );
                await tester.tap(find.byKey(const Key('catalog-body-back')));
                await tester.pumpAndSettle();
                await captureCatalog(
                  tester,
                  'explorer-unavailable-back-${brightness.name}',
                );
              }
              // Exercise caller-owned loading/error UI on the host fallback;
              // actual WebGL surface qualification is a separate native check.
              for (final status in [
                CharacterBodyStatus.loading,
                CharacterBodyStatus.error,
              ]) {
                tester
                    .widget<CharacterBody>(find.byType(CharacterBody))
                    .onStatus!(status);
                await tester.pumpAndSettle();
                expect(show.hitTestable(), findsOneWidget);
                expect(tester.takeException(), isNull);
                expectNoSplitWords(tester);
                if (locale == 'en' && width == 412 && scale == 1) {
                  await captureCatalog(
                    tester,
                    'explorer-${status.name}-${brightness.name}',
                  );
                }
              }
              final chip = find.byKey(const Key('catalog-muscle-biceps'));
              await tester.ensureVisible(chip);
              await tester.tap(chip);
              await tester.pumpAndSettle();
              expect(tester.widget<CatalogMuscleChip>(chip).selected, isTrue);
              expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
              expect(tester.takeException(), isNull);
              expectNoSplitWords(tester);
              if (locale == 'de' &&
                  width == 320 &&
                  scale == 2 &&
                  brightness == Brightness.light) {
                await captureCatalog(tester, 'body-strip-de-320-2x-light');
              }
              semantics.dispose();
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('catalog composition ${brightness.name}', (tester) async {
      phone(tester, 412, 1);
      final state = discoveryState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('catalog-capture'),
          child: discoveryApp(
            CatalogPicker(state: state, multiple: true),
            brightness: brightness,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await captureCatalog(tester, 'catalog-${brightness.name}');
      await groupQuery(tester, 'Biceps', 'biceps');
      await openChoice(tester, state, fixtureId(10));
      await revealTop(tester);
      await captureCatalog(tester, 'catalog-selected-${brightness.name}');
      final row = choice(fixtureId(10));
      await tester.ensureVisible(row);
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Details')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Target muscles'), findsWidgets);
      expect(find.text('Biceps'), findsWidgets);
      expect(find.text('Dumbbells'), findsWidgets);
      await captureCatalog(tester, 'catalog-details-${brightness.name}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('selected row preserves complete words and actions at 320dp 2x', (
    tester,
  ) async {
    phone(tester, 320, 2);
    var repeats = 0;
    var removals = 0;
    var details = 0;
    const rowKey = Key('selected-extreme-row');
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('catalog-capture'),
        child: discoveryApp(
          Center(
            child: CatalogPickerRow(
              key: rowKey,
              label: 'Synthetic neutral dumbbell curl',
              subtitle: 'Dumbbells · Neutral grip · Bench support',
              equipment: 'dumbbell',
              equipmentLabel: 'Dumbbells',
              selected: true,
              count: 2,
              inDay: true,
              onTap: () => removals++,
              onRepeat: () => repeats++,
              onMenu: () => details++,
              menuLabel: 'Details',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(rowKey);
    expectNoSplitWords(tester, within: row);
    expect(find.text('Synthetic neutral dumbbell curl'), findsOneWidget);
    expect(
      find.text('Dumbbells · Neutral grip · Bench support'),
      findsOneWidget,
    );
    for (final text in [
      find.text('Synthetic neutral dumbbell curl'),
      find.text('Dumbbells · Neutral grip · Bench support'),
    ]) {
      expect(
        tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
        isFalse,
      );
    }
    for (final tooltip in ['Add again', 'Details']) {
      final action = find.byTooltip(tooltip);
      expect(tester.getSize(action).shortestSide, greaterThanOrEqualTo(48));
      expect(action.hitTestable(), findsOneWidget);
    }
    await captureCatalog(tester, 'selected-row-320-2x');
    await tester.tap(find.byTooltip('Add again'));
    await tester.tap(find.byTooltip('Details'));
    await tester.tap(find.text('Synthetic neutral dumbbell curl'));
    expect((repeats, details, removals), (1, 1, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unknown membership never borrows family muscle facts', (
    tester,
  ) async {
    final state = discoveryState(browse: false);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      discoveryApp(CatalogPicker(state: state, multiple: true)),
    );
    await tester.enterText(
      find.byKey(const Key('catalog-search')),
      'Machine curl',
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, choice(fixtureId(13)));
    await tester.tap(
      find.descendant(
        of: choice(fixtureId(13)),
        matching: find.byTooltip('Details'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Target muscles'), findsNothing);
    expect(find.text('Muscle information unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
