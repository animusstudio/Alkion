import 'catalog_discovery_picker_test.dart' show finishFilters;
import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_measurement_form.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import '../support/memory_catalog_state.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../support/app_fonts.dart';

MemoryCatalogState memoryCatalog() => MemoryCatalogState(
  CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog())),
);
Widget app(
  Widget child, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: buildTheme(brightness, accents[0]),
  locale: locale,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Future<void> revealPicker(WidgetTester tester, Finder finder) async {
  // Input paint precedes the committed result frame; then build the lazy row.
  await tester.pump();
  await tester.pump();
  await tester.scrollUntilVisible(
    finder,
    100,
    scrollable: find
        .descendant(
          of: find.byType(CatalogPicker),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pump();
}

void main() {
  setUpAll(preloadAppFonts);
  testWidgets(
    'broad family never selects a variant and exact query stays direct',
    (tester) async {
      final state = memoryCatalog();
      await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pump();
      await tester.pump();
      await revealPicker(tester, find.text('Curl'));
      expect(find.text('Curl'), findsOneWidget);
      expect(find.text('Neutral dumbbell curl'), findsNothing);
      await tester.tap(find.text('Curl'));
      await tester.pump();
      final neutralId = state.bundle.variants.values
          .firstWhere((v) => v.key == 'neutral_curl')
          .id;
      final neutralRow = find.byKey(ValueKey('variant:$neutralId@default'));
      await revealPicker(tester, neutralRow);
      expect(neutralRow, findsOneWidget);
      expect(find.text('Add selected · 0'), findsOneWidget);
      await tester.ensureVisible(neutralRow);
      await tester.pump();
      await tester.tap(neutralRow);
      await tester.pump();
      expect(find.text('Add selected · 1'), findsOneWidget);
      // Selected tap removes the last occurrence; Add again explicitly repeats.
      await tester.ensureVisible(neutralRow);
      await tester.pump();
      await tester.tap(neutralRow);
      await tester.pump();
      expect(find.text('Add selected · 0'), findsOneWidget);
      await tester.ensureVisible(neutralRow);
      await tester.pump();
      await tester.tap(neutralRow);
      await tester.pump();
      await tester.tap(
        find.descendant(of: neutralRow, matching: find.byTooltip('Details')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add again'));
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 2'), findsOneWidget);
      if (find.byTooltip('Leave exercise family').evaluate().isNotEmpty) {
        await tester.ensureVisible(
          find.byTooltip('Leave exercise family').first,
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Leave exercise family').first);
        await tester.pump();
      }
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Standing barbell shoulder press',
      );
      await tester.pump();
      await tester.pump();
      final pressId = state.bundle.variants.values
          .firstWhere((v) => v.key == 'standing_press')
          .id;
      final exactRow = find.byKey(ValueKey('variant:$pressId@default'));
      await revealPicker(tester, exactRow);
      expect(exactRow.hitTestable(), findsOneWidget);
      expect(
        find.byKey(
          ValueKey(
            'catalog-navigation-family-${state.bundle.variants[pressId]!.familyId}',
          ),
        ),
        findsNothing,
      );
      expect(find.text('Add selected · 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('custom name keeps query and Back retains picker selection', (
    tester,
  ) async {
    final state = memoryCatalog();
    await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('catalog-search')),
      'My travel movement',
    );
    await tester.pump();
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('catalog-create')));
    await tester.tap(find.byKey(const Key('catalog-create')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('catalog-custom-name')))
          .controller!
          .text,
      'My travel movement',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('catalog-search')))
          .controller!
          .text,
      'My travel movement',
    );
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'all eight metric profiles validate independently and retain exact draft across locale',
    (tester) async {
      final state = memoryCatalog();
      expect(state.bundle.measurementProfiles.length, 8);
      for (final profile in state.bundle.measurementProfiles.values) {
        final values = <String, String>{};
        await tester.pumpWidget(
          app(
            CatalogMeasurementForm(
              key: ValueKey(profile.key),
              profile: profile,
              values: values,
              onChanged: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(catalogMeasurementsValid(profile, values), isFalse);
        for (final metric in profile.requiredMetrics) {
          await tester.enterText(
            find.byKey(ValueKey('metric-$metric')),
            metric == 'repetitions' ? '7' : '12.50',
          );
        }
        expect(catalogMeasurementsValid(profile, values), isTrue);
        for (final metric in profile.optionalMetrics) {
          expect(values[metric], isNull);
        }
        final exact = Map<String, String>.of(values);
        await tester.pumpWidget(
          app(
            CatalogMeasurementForm(
              key: ValueKey(profile.key),
              profile: profile,
              values: values,
              onChanged: () {},
            ),
            locale: const Locale('it'),
            brightness: Brightness.light,
          ),
        );
        await tester.pumpAndSettle();
        expect(values, exact);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  for (final language in ['en', 'it', 'de', 'es']) {
    testWidgets('catalog is reachable at 320dp 2x keyboard in $language', (
      tester,
    ) async {
      final state = memoryCatalog();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
              viewInsets: EdgeInsets.only(bottom: 220),
            ),
            child: CatalogPicker(state: state, multiple: true),
          ),
          locale: Locale(language),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('catalog-add-selected')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('catalog-search')));
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets(
    'custom selected measurement wraps fully at 320dp 2x with Italian IME',
    (tester) async {
      final state = memoryCatalog();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: 220);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showCatalogPicker(context, state: state),
              child: const Text('Open picker'),
            ),
          ),
          locale: const Locale('it'),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Movimento personale',
      );
      await tester.pump();
      await tester.pump();
      final create = find.byKey(const Key('catalog-create'));
      await tester.scrollUntilVisible(
        create,
        150,
        scrollable: find
            .descendant(
              of: find.byType(CatalogPicker),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();
      final selected = find.text('Carico (kg) + Ripetizioni');
      final selector = find.byType(DropdownButtonFormField<String>);
      expect(selected, findsOneWidget);
      await tester.ensureVisible(selector);
      await tester.pumpAndSettle();
      final textBounds = tester.getRect(selected),
          selectorBounds = tester.getRect(selector);
      expect(textBounds.top, greaterThanOrEqualTo(selectorBounds.top));
      expect(textBounds.bottom, lessThanOrEqualTo(selectorBounds.bottom));
      expect(textBounds.right, lessThanOrEqualTo(selectorBounds.right));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'single picker final action scrolls above Android bottom safe inset',
    (tester) async {
      final state = memoryCatalog();
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(bottom: 48);
      tester.view.viewPadding = FakeViewPadding(bottom: 48);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showCatalogPicker(context, state: state),
              child: const Text('Open picker'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      final create = find.byKey(const Key('catalog-create'));
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      expect(create.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(create).dy, lessThanOrEqualTo(752));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'selected equipment remains visible and clearable after narrowing',
    (tester) async {
      final state = memoryCatalog();
      await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pump();
      await tester.pump();
      await revealPicker(tester, find.text('Curl'));
      await tester.tap(find.text('Curl'));
      await tester.pump();
      await revealPicker(tester, find.byKey(const Key('catalog-filters')));
      await tester.tap(find.byKey(const Key('catalog-filters')));
      await tester.pumpAndSettle();
      expect(find.text('Dumbbells'), findsWidgets);
      await tester.tap(find.text('Machine').last);
      await tester.pumpAndSettle();
      await finishFilters(tester);
      expect(find.widgetWithText(InputChip, 'Machine'), findsOneWidget);
      final other = state.bundle.variants.values.firstWhere(
        (v) => v.key == 'neutral_curl',
      );
      expect(find.byKey(ValueKey('variant:${other.id}@default')), findsNothing);
      await tester.tap(find.byTooltip('Clear equipment'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-equipment-scope')), findsNothing);
      await revealPicker(
        tester,
        find.byKey(ValueKey('variant:${other.id}@default')),
      );
      expect(
        find.byKey(ValueKey('variant:${other.id}@default')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'favorites honor qualified query and Change setup movement admission',
    (tester) async {
      final state = memoryCatalog();
      final machine = state.bundle.variants.values.firstWhere(
        (v) => v.equipmentKind == 'machine',
      );
      final press = state.bundle.variants.values.firstWhere(
        (v) => v.key == 'standing_press',
      );
      final curl = CatalogChoice.variant(machine.id),
          standing = CatalogChoice.variant(press.id);
      final known = state.newSetup(curl, 'Hotel curl');
      state.toggleFavorite(curl);
      state.toggleFavorite(known);
      state.toggleFavorite(standing);
      final customA = CatalogChoice.custom('My café hold', 'load_reps');
      final customB = CatalogChoice.custom('My café hold', 'load_reps');
      state.toggleFavorite(customA);
      state.toggleFavorite(customB);
      await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Favorites'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Standing barbell shoulder press',
      );
      await tester.pump();
      await tester.pump();
      await revealPicker(tester, find.byKey(ValueKey(standing.key)));
      expect(find.byKey(ValueKey(standing.key)), findsOneWidget);
      expect(find.byKey(ValueKey(curl.key)), findsNothing);
      expect(find.byKey(ValueKey(known.key)), findsNothing);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'MY CAFE HOLD',
      );
      await tester.pump();
      await tester.pump();
      await revealPicker(tester, find.byKey(ValueKey(customA.key)));
      expect(customA.key, isNot(customB.key));
      expect(find.byKey(ValueKey(customA.key)), findsOneWidget);
      expect(find.byKey(ValueKey(customB.key)), findsOneWidget);
      expect(find.byKey(ValueKey(standing.key)), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          CatalogPicker(
            state: state,
            multiple: true,
            familyId: machine.familyId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Favorites'));
      await tester.pump();
      await revealPicker(tester, find.byKey(ValueKey(curl.key)));
      expect(find.byKey(ValueKey(curl.key)), findsOneWidget);
      expect(find.byKey(ValueKey(known.key)), findsOneWidget);
      expect(find.byKey(ValueKey(standing.key)), findsNothing);
      expect(find.byKey(ValueKey(customA.key)), findsNothing);
      expect(find.byKey(ValueKey(customB.key)), findsNothing);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Standing barbell shoulder press',
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(CatalogPickerRow), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
