import 'catalog_discovery_picker_test.dart' show selectMuscle;
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import 'catalog_direct_browser_test.dart' show largeBrowserState;
import 'catalog_discovery_picker_test.dart'
    show discoveryApp, discoveryState, fixtureId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(preloadAppFonts);

  test('synthetic host catalog cost sample (not Android qualification)', () {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    final watch = Stopwatch()..start();
    final index = CatalogIndex(state.bundle);
    final construction = watch.elapsedMicroseconds;
    watch.reset();
    for (final variant in state.bundle.variants.values) {
      expect(index.identifyingVariantLabel(variant.id), isNotEmpty);
    }
    final coldLabels = watch.elapsedMicroseconds;
    watch.reset();
    for (final variant in state.bundle.variants.values) {
      index.identifyingVariantLabel(variant.id);
    }
    final warmLabels = watch.elapsedMicroseconds;
    watch.reset();
    index.search('');
    final coldBrowse = watch.elapsedMicroseconds;
    watch.reset();
    index.search('');
    final warmBrowse = watch.elapsedMicroseconds;
    final typing = <int>[];
    for (final query in ['s', 'sy', 'syn', 'synt', 'synth', 'synthe']) {
      watch.reset();
      index.search(query);
      typing.add(watch.elapsedMicroseconds);
    }
    watch.stop();
    // Deliberately no machine-speed threshold: host JIT cost is evidence only.
    // ignore: avoid_print
    print(
      'SYNTHETIC_HOST_US index=$construction cold_labels=$coldLabels '
      'warm_labels=$warmLabels cold_browse=$coldBrowse '
      'warm_browse=$warmBrowse typing=$typing variants=${state.bundle.variants.length}',
    );
  });

  testWidgets(
    'workout opens results and concrete selection returns on first tap',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      List<CatalogChoice>? picked;
      await tester.pumpWidget(
        discoveryApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showCatalogPicker(
                  context,
                  state: state,
                  multiple: true,
                  immediateSelection: true,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-result-count')), findsOneWidget);
      expect(find.byKey(const Key('catalog-add-selected')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Synthetic chest press',
      );
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('variant:${fixtureId(100)}@default'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(picked?.single.variantId, fixtureId(100));
      expect(find.byType(CatalogPicker), findsNothing);
      expect(
        state.exercises,
        isEmpty,
      ); // Selection creates no library enrollment.
    },
  );

  testWidgets(
    'favorites retains its view through muscle filtering and clear preserves query',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      final favorite = CatalogChoice.variant(fixtureId(10));
      state.toggleFavorite(favorite);
      await tester.pumpWidget(
        discoveryApp(CatalogPicker(state: state, immediateSelection: true)),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Favorites'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('catalog-browse-muscles')),
      );
      await tester.tap(find.byKey(const Key('catalog-browse-muscles')));
      await tester.pumpAndSettle();
      expect(
        find.text('Conditioning'),
        findsNothing,
      ); // Activity has its own selector.
      await selectMuscle(tester, 'biceps');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Favorites'))
            .selected,
        isTrue,
      );
      expect(find.text('1 result'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('catalog-clear-filters')),
      );
      await tester.tap(find.byKey(const Key('catalog-clear-filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-group-scope')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .controller!
            .text,
        'curl',
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Favorites'))
            .selected,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
