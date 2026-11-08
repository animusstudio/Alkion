import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/widgets/text_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import 'catalog_discovery_picker_test.dart';
import 'catalog_visual_discovery_test.dart' show phone;

/// A label mid-motion: text motion swaps its plain Text for per-character
/// spans only while a run plays (or waits in its stagger).
final _moving = find.byWidgetPredicate(
  (w) => w is Text && w.data == null && w.textSpan != null,
);

Finder _movingIn(Finder of) => find.descendant(of: of, matching: _moving);

Iterable<CatalogPickerRow> _rows(WidgetTester tester) =>
    tester.widgetList<CatalogPickerRow>(find.byType(CatalogPickerRow));

Future<void> _open(WidgetTester tester, {double height = 800}) async {
  phone(tester, 412, 1);
  tester.view.physicalSize = Size(412, height);
  final state = discoveryState();
  addTearDown(state.dispose);
  await tester.pumpWidget(
    discoveryApp(CatalogPicker(state: state, multiple: true)),
  );
  await tester.pumpAndSettle();
}

/// Moves the list to Favorites (empty in the fixture) and back to All, so
/// the All rows return as a changed result set.
Future<void> _backToAll(WidgetTester tester) async {
  await tester.tap(find.text('Favorites'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('catalog-all')));
  await tester.pump();
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('view chips glitch on tap and stay calm once selected', (
    tester,
  ) async {
    await _open(tester);
    final favorites = find.ancestor(
      of: find.text('Favorites'),
      matching: find.byType(ChoiceChip),
    );
    final all = find.byKey(const Key('catalog-all'));
    expect(_movingIn(all), findsNothing);

    await tester.tap(all);
    await tester.pump();
    expect(_movingIn(all), findsNothing, reason: 'All is already selected');

    await tester.tap(favorites);
    await tester.pump();
    expect(_movingIn(favorites), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_movingIn(favorites), findsNothing);

    // Selected Favorites: a tap goes back to All without a glitch.
    await tester.tap(favorites);
    await tester.pump();
    expect(_movingIn(favorites), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('filter sheet chips glitch unless already selected', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('catalog-filters')));
    await tester.pumpAndSettle();
    final chip = find.byWidgetPredicate(
      (w) =>
          w is FilterChip &&
          (w.key as ValueKey?)?.value.toString().startsWith(
                'catalog-equipment-',
              ) ==
              true,
    );
    final first = chip.first;
    final key = tester.widget(first).key!;
    await tester.tap(first);
    await tester.pump();
    expect(_movingIn(find.byKey(key)), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(find.byKey(key)).selected, isTrue);

    await tester.tap(find.byKey(key));
    await tester.pump();
    expect(_movingIn(find.byKey(key)), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(find.byKey(key)).selected, isFalse);
  });

  testWidgets('only rows on screen in the first frame reveal, staggered', (
    tester,
  ) async {
    await _open(tester, height: 420);
    await _backToAll(tester);
    final revealing = _rows(tester).where((r) => r.reveal != null).toList();
    expect(revealing, isNotEmpty);
    expect(
      revealing.map((r) => r.reveal!.delay).toList(),
      [
        for (var i = 0; i < revealing.length; i++)
          RevealStagger.delay(i, revealing.length < 7 ? 7 : revealing.length),
      ].take(revealing.length).toList(),
      reason: 'build order is the stagger order',
    );

    // After the first frame, rows built only for the cache extent settle at
    // once; rows on screen keep revealing.
    await tester.pump();
    final viewport = tester.getRect(pickerScroll());
    for (final row in find.byType(CatalogPickerRow).evaluate()) {
      final finder = find.byWidget(row.widget);
      final onScreen = tester.getRect(finder).overlaps(viewport);
      final moving = _movingIn(finder).evaluate().isNotEmpty;
      if (!onScreen) expect(moving, isFalse, reason: 'offscreen rows settle');
    }
    expect(
      _moving,
      findsWidgets,
      reason: 'the visible result titles are revealing',
    );

    await tester.pumpAndSettle();
    expect(_moving, findsNothing);
    expect(tester.binding.transientCallbackCount, 0);

    // Scrolling builds and shows more rows; none of them reveal.
    final gesture = await tester.startGesture(tester.getCenter(pickerScroll()));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_moving, findsNothing);
    }
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('rows first built by scrolling never reveal', (tester) async {
    await _open(tester, height: 300);
    await _backToAll(tester);
    final before = _rows(tester).map((r) => r.key).toSet();
    await tester.pumpAndSettle();
    await tester.drag(pickerScroll(), const Offset(0, -600));
    await tester.pump();
    final built = _rows(tester).where((r) => !before.contains(r.key));
    expect(built, isNotEmpty);
    for (final row in built) {
      expect(row.reveal, isNull, reason: '${row.label} was built by a scroll');
    }
    expect(_moving, findsNothing);
    await tester.pumpAndSettle();
    expect(_moving, findsNothing);
  });

  testWidgets('fast typing reveals once, not on every keystroke', (
    tester,
  ) async {
    await _open(tester);
    final search = find.byKey(const Key('catalog-search'));
    Set<int> epochs() => {
      for (final row in _rows(tester))
        if (row.reveal case final reveal?) reveal.epoch,
    };

    Set<String> labels() => {for (final row in _rows(tester)) row.label};
    await tester.enterText(search, 'press');
    await tester.pump();
    await tester.pump();
    final first = epochs();
    expect(first, hasLength(1), reason: 'the first keystroke reveals');

    final seen = {labels().join('|')};
    for (final query in ['curl', 'plank', 'row', 'press']) {
      await tester.enterText(search, query);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
      seen.add(labels().join('|'));
      expect(
        epochs().difference(first),
        isEmpty,
        reason: '"$query" typed quickly starts no new reveal',
      );
    }
    expect(seen.length, greaterThan(1), reason: 'the results did change');
    await tester.pumpAndSettle();

    // After a pause, the next change that alters the results reveals again.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(search, 'curl');
    await tester.pump();
    await tester.pump();
    expect(epochs().difference(first), isNotEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion builds no reveal at all', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _open(tester, height: 420);
    await _backToAll(tester);
    expect(_rows(tester).where((r) => r.reveal != null), isEmpty);
    expect(find.byType(RevealText), findsNothing);
    await tester.pumpAndSettle();
  });
}
