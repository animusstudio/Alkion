import 'dart:async';

import 'package:alkion/catalog_trial.dart';
import 'package:alkion/catalog_ui/catalog_loading.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/widgets/state_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:alkion/theme/typography.dart';
import 'package:alkion/catalog_ui/catalog_muscle_explorer.dart';
import 'package:alkion/catalog_ui/catalog_equipment_icon.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/icon_finders.dart';
import 'catalog_discovery_picker_test.dart';
import 'catalog_visual_discovery_test.dart' show captureCatalog, phone;

void main() {
  setUpAll(preloadAppFonts);
  for (final brightness in Brightness.values) {
    testWidgets(
      'neutral chips and immediate catalog selection ${brightness.name}',
      (tester) async {
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
        final context = tester.element(find.byKey(const Key('catalog-all')));
        final theme = Theme.of(context).chipTheme;
        expect(
          theme.color!.resolve({WidgetState.selected}),
          context.tokens.text,
        );
        expect(theme.checkmarkColor, context.tokens.bg);
        final label = tester.renderObject<RenderParagraph>(
          find.text('All A–Z'),
        );
        expect(label.text.style!.fontFamily, WorkoutType.body().fontFamily);
        expect(label.text.style!.color, context.tokens.bg);

        expect(
          theme.color!.resolve({WidgetState.selected}),
          isNot(context.tokens.accent),
        );
        expect(find.byType(CatalogGlyphSkeleton), findsNothing);
        await openChoice(tester, state, fixtureId(10));
        await tester.tap(
          find.descendant(
            of: choice(fixtureId(10)),
            matching: find.byTooltip('Add again'),
          ),
        );
        await tester
            .pump(); // Interaction is committed before the mark resolves.
        expect(find.text('Add selected · 2'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 60));
        await captureCatalog(tester, 'selection-mid-${brightness.name}');
        await tester.pump(const Duration(milliseconds: 140));
        await tester.tap(
          find.descendant(
            of: choice(fixtureId(10)),
            matching: find.byTooltip('Details'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Favorite / unfavorite'));
        await tester.tap(find.text('Favorite / unfavorite'));
        await tester.pumpAndSettle();
        expect(state.favorites, contains('variant:${fixtureId(10)}@default'));
        expect(
          tester.widget<CatalogPickerRow>(choice(fixtureId(10))).favorite,
          isTrue,
        );
        expect(
          find.descendant(
            of: choice(fixtureId(10)),
            matching: findGlyph(AlkionGlyph.favorite),
          ),
          findsOneWidget,
        );
        final favorite = find.descendant(
          of: choice(fixtureId(10)),
          matching: findGlyph(AlkionGlyph.favorite),
        );
        expect(tester.getRect(favorite).size, const Size(18, 18));
        await captureCatalog(tester, 'catalog-neutral-${brightness.name}');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final locale in ['en', 'it', 'de']) {
      testWidgets(
        'catalog status glyphs fit 320dp/2x $locale ${brightness.name}',
        (tester) async {
          phone(tester, 320, 2);
          var favorite = false;
          await tester.pumpWidget(
            RepaintBoundary(
              key: const Key('catalog-capture'),
              child: discoveryApp(
                StatefulBuilder(
                  builder: (context, update) => SingleChildScrollView(
                    child: CatalogPickerRow(
                      label: 'Synthetic exercise with a long setup name',
                      subtitle: 'Synthetic equipment and movement',
                      equipment: 'cable',
                      equipmentLabel: 'Cable',
                      favorite: favorite,
                      current: true,
                      inDay: true,
                      onTap: () {},
                      onMenu: () => update(() => favorite = !favorite),
                      menuLabel: 'Details',
                      onRepeat: () {},
                    ),
                  ),
                ),
                brightness: brightness,
                locale: locale,
              ),
            ),
          );
          await tester.tap(findGlyph(AlkionGlyph.more));
          await tester.pump();
          for (final elapsed in [
            Duration.zero,
            const Duration(milliseconds: 60),
            const Duration(milliseconds: 60),
          ]) {
            await tester.pump(elapsed);
            final bounds = tester.getRect(findGlyph(AlkionGlyph.favorite));
            expect(bounds.width, greaterThanOrEqualTo(16));
            expect(bounds.height, greaterThanOrEqualTo(16));
          }
          expect(
            tester.getRect(findGlyph(AlkionGlyph.favorite)).size,
            const Size(18, 18),
          );
          for (final glyph in [AlkionGlyph.current, AlkionGlyph.inDay]) {
            expect(tester.getRect(findGlyph(glyph)).size, const Size(16, 16));
          }
          expect(tester.takeException(), isNull);
          await captureCatalog(
            tester,
            'iconoir-status-${brightness.name}-$locale',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('paused body controls and list keep region selection immediate', (
    tester,
  ) async {
    phone(tester, 412, 1);
    final state = discoveryState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('catalog-capture'),
        child: discoveryApp(
          CatalogMuscleExplorer(index: state.index('en'), selected: 'chest'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('catalog-body-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await captureCatalog(tester, 'body-turn-60ms');
    await tester.tap(find.byKey(const Key('catalog-muscle-list-link')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('catalog-muscle-triceps')));
    await tester.tap(find.byKey(const Key('catalog-muscle-triceps')));
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('catalog-muscle-triceps')))
          .selected,
      isTrue,
    );
    expect(find.text('Show exercises · Triceps'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 216));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'loading and completion material provide bounded host frame evidence',
    (tester) async {
      phone(tester, 412, 1);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('catalog-capture'),
          child: const CatalogLoadingApp(
            brightness: Brightness.dark,
            accent: Colors.orange,
          ),
        ),
      );
      await tester.pump();
      await captureCatalog(tester, 'actual-wait-glyphs');
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('catalog-capture'),
          child: discoveryApp(
            const Center(
              child: SuccessMark(
                event: 'committed-synthetic-session',
                size: 72,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final resolvingMark = find.descendant(
        of: find.byType(SuccessMark),
        matching: findGlyph(AlkionGlyph.check),
      );
      expect(tester.getRect(resolvingMark).size, const Size(72, 72));
      final clip = find
          .descendant(
            of: find.byType(SuccessMark),
            matching: find.byType(ClipRect),
          )
          .first;
      expect(tester.getSize(clip).width, inExclusiveRange(0, 72));
      expect(tester.getSize(clip).height, 72);
      await captureCatalog(tester, 'confirmed-mark-60ms');
      await tester.pump(const Duration(milliseconds: 156));
      final mark = find.descendant(
        of: find.byType(SuccessMark),
        matching: findGlyph(AlkionGlyph.check),
      );
      expect(mark, findsOneWidget);
      expect(tester.getRect(mark).size, const Size(72, 72));
      await captureCatalog(tester, 'confirmed-mark-final');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('decode preserves immediate input and completes within 200ms', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      discoveryApp(
        CatalogReadyReveal(
          enabled: true,
          child: GestureDetector(
            onTap: () => taps++,
            child: const Text('Ready'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Ready'));
    expect(taps, 1);
    await tester.pump(const Duration(milliseconds: 200));
    final motion =
        tester
                .widget<AnimatedBuilder>(
                  find
                      .descendant(
                        of: find.byType(EventProgress),
                        matching: find.byType(AnimatedBuilder),
                      )
                      .first,
                )
                .animation
            as AnimationController;
    expect(motion.value, 1);
    await tester.pump(
      const Duration(milliseconds: 16),
    ); // Retire the final frame.
    expect(motion.isAnimating, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'trial actual pending load shows stable glyphs then ready, failure has no success decode',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      final pending = Completer<CatalogBundle>();
      await tester.pumpWidget(
        CatalogTrialBootstrap(loader: () => pending.future),
      );
      await tester.pump();
      expect(find.byType(CatalogGlyphSkeleton), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      pending.complete(state.bundle);
      await tester.pump();
      await tester.pump();
      expect(find.byType(CatalogGlyphSkeleton), findsNothing);
      expect(find.byType(CatalogReadyReveal), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        CatalogTrialBootstrap(
          loader: () async => throw const FormatException('synthetic failure'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CatalogGlyphSkeleton), findsNothing);
      expect(find.byType(CatalogReadyReveal), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reduced catalog filters apply immediately with zero chip/sheet durations',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final state = discoveryState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        discoveryApp(CatalogPicker(state: state, multiple: true)),
      );
      final all = tester.widget<ChoiceChip>(
        find.byKey(const Key('catalog-all')),
      );
      expect(all.chipAnimationStyle!.selectAnimation!.duration, Duration.zero);
      await tester.tap(find.byKey(const Key('catalog-filters')));
      await tester.pump();
      final equipment = find.byKey(const Key('catalog-equipment-cable'));
      await tester.ensureVisible(equipment);
      await tester.tap(equipment);
      await tester.pump();
      expect(tester.widget<FilterChip>(equipment).selected, isTrue);
      final icon = tester.widget<CatalogEquipmentIcon>(
        find.descendant(
          of: equipment,
          matching: find.byType(CatalogEquipmentIcon),
        ),
      );
      expect(icon.color, tester.element(equipment).tokens.bg);

      expect(
        tester
            .widget<FilterChip>(equipment)
            .chipAnimationStyle!
            .selectAnimation!
            .duration,
        Duration.zero,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reduced load handoff is static and retains loading theme/locale',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures.allOn;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        const CatalogLoadingApp(
          brightness: Brightness.light,
          accent: Colors.orange,
          locale: Locale('it'),
        ),
      );
      final context = tester.element(find.byType(CatalogGlyphSkeleton));
      expect(Theme.of(context).brightness, Brightness.light);
      expect(Localizations.localeOf(context), const Locale('it'));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(
        discoveryApp(
          const CatalogReadyReveal(enabled: true, child: Text('Ready')),
        ),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(EventProgress), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
