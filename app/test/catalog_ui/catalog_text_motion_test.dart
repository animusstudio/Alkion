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
    // One reveal shares one slot count: the first screen's capacity at this
    // height (420 / 76 rounded up, plus one), never more rows than exist.
    final slots = revealing.first.reveal!.slots;
    expect(revealing.map((r) => r.reveal!.slots).toSet(), {slots});
    expect(slots, lessThanOrEqualTo((420 / 76).ceil() + 1));
    expect(revealing.length, lessThanOrEqualTo(slots));
    expect(
      revealing.map((r) => r.reveal!.delay).toList(),
      [
        for (var i = 0; i < revealing.length; i++)
          RevealStagger.delay(i, slots),
      ],
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
    // Every finished row went back to a plain label, motion listeners and all.
    expect(_rows(tester).where((r) => r.reveal != null), isEmpty);
    expect(find.byType(RevealText), findsNothing);

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

  testWidgets('a change that leaves the rows as they are does not reveal', (
    tester,
  ) async {
    await _open(tester, height: 420);
    // All is already showing: the tap still runs an update.
    await tester.tap(find.byKey(const Key('catalog-all')));
    await tester.pump();
    expect(_rows(tester).where((r) => r.reveal != null), isEmpty);
    expect(_moving, findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('activity and unclassified chips glitch on tap', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('catalog-filters')));
    await tester.pumpAndSettle();
    final groups = find.byWidgetPredicate(
      (w) =>
          w is FilterChip &&
          '${w.key}'.contains('catalog-group-') &&
          !'${w.key}'.contains('unclassified'),
    );
    expect(groups, findsWidgets);
    final group = tester.widget(groups.first).key!;
    await tester.ensureVisible(find.byKey(group));
    await tester.tap(find.byKey(group));
    await tester.pump();
    expect(_movingIn(find.byKey(group)), findsOneWidget);
    await tester.pumpAndSettle();

    const unclassified = Key('catalog-group-unclassified');
    await tester.ensureVisible(find.byKey(unclassified));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(unclassified));
    await tester.pump();
    expect(_movingIn(find.byKey(unclassified)), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a revealing row keeps one constant semantics label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _open(tester, height: 420);
    await _backToAll(tester);
    final row = find.byWidgetPredicate(
      (w) => w is CatalogPickerRow && w.reveal != null,
    );
    final key = tester.widget(row.first).key!;
    String label() => tester.getSemantics(find.byKey(key)).label;
    final spoken = label();
    expect(spoken, contains(tester.widget<CatalogPickerRow>(row.first).label));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(label(), spoken);
    }
    await tester.pumpAndSettle();
    expect(label(), spoken);
    handle.dispose();
  });

  testWidgets('a scroll restore after the change still reveals and cleans up', (
    tester,
  ) async {
    // At this height the group action sits below the fold, so opening the
    // group restores the scroll to the top after the first layout.
    await _open(tester, height: 440);
    await tester.enterText(find.byKey(const Key('catalog-search')), 'Chest');
    await tester.pump();
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('catalog-group-action-chest'));
    await tester.scrollUntilVisible(action, 60, scrollable: pickerScroll());
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(pickerScroll()).position;
    expect(position.pixels, greaterThan(0));
    await tester.tap(action);
    await tester.pump();
    expect(position.pixels, 0, reason: 'the restore jumped after layout');
    expect(_rows(tester).where((r) => r.reveal != null), isNotEmpty);
    await tester.pumpAndSettle();
    expect(_rows(tester).where((r) => r.reveal != null), isEmpty);
    expect(find.byType(RevealText), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  group('CatalogRevealPlan', () {
    test('claims slots in order within the window only', () {
      final plan = CatalogRevealPlan();
      expect(plan.open(2), isTrue);
      expect(plan.claim('a', 'A')!.delay, RevealStagger.delay(0, 2));
      expect(plan.claim('b', 'B')!.delay, RevealStagger.delay(1, 2));
      expect(plan.claim('c', 'C'), isNull, reason: 'no slot left');
      expect(plan.close(), isFalse);
      expect(plan.window, isFalse);
      expect(plan.claim('d', 'D'), isNull, reason: 'built after the window');
      expect(plan.claim('a', 'A'), isNotNull, reason: 'a rebuild keeps it');
    });

    test('a scroll restore hold keeps revealing rows and frees slots', () {
      final plan = CatalogRevealPlan();
      plan.open(2);
      final a = plan.claim('a', 'A')!;
      plan.claim('b', 'B');
      plan.holdForJump();
      expect(plan.close(), isTrue, reason: 'one more layout');
      expect(plan.window, isTrue);
      expect(plan.claim('a', 'A'), a, reason: 'no pop back to a plain label');
      expect(plan.claim('c', 'C')!.delay, RevealStagger.delay(0, 2));
      expect(plan.close(), isFalse);
      expect(plan.length, 3);
    });

    test('a changed label drops the reveal instead of replaying it', () {
      final plan = CatalogRevealPlan();
      plan.open(3);
      plan.claim('a', 'Curl');
      plan.close();
      expect(plan.claim('a', 'Flessione'), isNull);
      expect(plan.claim('a', 'Curl'), isNull, reason: 'it stays dropped');
    });

    test('done empties the plan once every row settled', () {
      final plan = CatalogRevealPlan();
      plan.open(2);
      final a = plan.claim('a', 'A')!;
      final b = plan.claim('b', 'B')!;
      expect(plan.done('a', a.epoch), isFalse, reason: 'window still open');
      plan.close();
      expect(plan.done('b', b.epoch - 1), isFalse, reason: 'an older run');
      expect(plan.done('b', b.epoch), isTrue);
      expect(plan.length, 0);
    });
  });
}
