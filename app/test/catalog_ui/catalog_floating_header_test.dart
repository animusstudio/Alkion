import 'package:alkion/catalog_ui/catalog_floating_header.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart' show setPhone;
import 'catalog_direct_browser_test.dart'
    show browser, browserScroll, largeBrowserState;
import 'catalog_discovery_picker_test.dart' show discoveryApp, pickerScroll;

final _search = find.byKey(const Key('catalog-search'));
final _filters = find.byKey(const Key('catalog-filters'));
// The header is a sliver; measure its opaque box child.
final _header = find
    .descendant(
      of: find.byKey(const Key('catalog-search-header')),
      matching: find.byType(ColoredBox),
    )
    .first;

double _offset(WidgetTester tester, Finder scroll) =>
    tester.state<ScrollableState>(scroll).position.pixels;

/// Shown means the whole header paints from the viewport's leading edge
/// (or lower) and its field takes taps.
void _expectShown(WidgetTester tester, Finder scroll) {
  expect(_search.hitTestable(), findsOneWidget);
  expect(_filters.hitTestable(), findsOneWidget);
  expect(
    tester.getTopLeft(_search).dy,
    greaterThanOrEqualTo(tester.getTopLeft(scroll).dy),
  );
}

/// Every string the semantics tree currently exposes.
Set<String> _semanticStrings(WidgetTester tester) {
  final strings = <String>{};
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    strings.addAll(
      [
        data.label,
        data.hint,
        data.tooltip,
        data.value,
      ].where((text) => text.isNotEmpty),
    );
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return strings;
}

bool _hitsRenderOf(WidgetTester tester, Offset point, Finder finder) {
  final targets = {
    for (final element in finder.evaluate()) element.renderObject,
  };
  return tester
      .hitTestOnBinding(point)
      .path
      .any((entry) => targets.contains(entry.target));
}

void _expectHidden() {
  expect(_search.hitTestable(), findsNothing);
  expect(_filters.hitTestable(), findsNothing);
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets('embedded: hides on scroll down and floats back on scroll up', (
    tester,
  ) async {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    await tester.pumpAndSettle();
    final scroll = browserScroll();
    _expectShown(tester, scroll);
    // Search and filters share the floating row; the chips stay below it.
    expect(
      tester.getCenter(_filters).dy,
      closeTo(tester.getCenter(_search).dy, 1),
    );
    expect(
      tester.getTopLeft(_filters).dx,
      greaterThan(tester.getTopRight(_search).dx),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('catalog-all'))).dy,
      greaterThan(tester.getBottomLeft(_header).dy),
    );
    final opaque = tester.widget<ColoredBox>(_header);
    expect(opaque.color, tester.element(_header).tokens.bg);

    await tester.drag(scroll, const Offset(0, -900));
    await tester.pumpAndSettle();
    final deep = _offset(tester, scroll);
    expect(deep, greaterThan(800));
    _expectHidden();

    // A short scroll up brings the whole header back mid-list.
    await tester.drag(scroll, const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(_offset(tester, scroll), lessThan(deep));
    expect(_offset(tester, scroll), greaterThan(800));
    _expectShown(tester, scroll);
    expect(
      tester.getTopLeft(_header).dy,
      closeTo(tester.getTopLeft(scroll).dy, 1),
    );

    await tester.drag(scroll, const Offset(0, -300));
    await tester.pumpAndSettle();
    _expectHidden();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scroll up reveals at once while the finger is still down', (
    tester,
  ) async {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    await tester.pumpAndSettle();
    final scroll = browserScroll();
    await tester.drag(scroll, const Offset(0, -900));
    await tester.pumpAndSettle();
    _expectHidden();
    final gesture = await tester.startGesture(tester.getCenter(scroll));
    // Past the touch slop, then a few pixels of real upward scrolling.
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 6));
    await tester.pump();
    // The list ignores taps while dragging, so check where the header paints.
    final viewportTop = tester.getTopLeft(scroll).dy;
    final extent = tester.getSize(_header).height;
    expect(
      tester.getTopLeft(_header).dy,
      lessThan(viewportTop - extent / 2),
      reason: 'only the scrolled pixels show before the reveal starts',
    );
    // Holding the finger still schedules no frames, so settling runs the
    // reveal to its end whatever its duration.
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_header).dy, closeTo(viewportTop, 1));
    expect(
      tester.state<ScrollableState>(scroll).position.isScrollingNotifier.value,
      isTrue,
      reason: 'the reveal completed while the drag was still held',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    _expectShown(tester, scroll);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a header left part way snaps out after a short scroll down', (
    tester,
  ) async {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    await tester.pumpAndSettle();
    final scroll = browserScroll();
    await tester.drag(scroll, const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.drag(scroll, const Offset(0, 40));
    await tester.pumpAndSettle();
    _expectShown(tester, scroll);
    final extent = tester.getSize(_header).height;
    await tester.drag(scroll, Offset(0, -extent / 3));
    await tester.pumpAndSettle();
    _expectHidden();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sheet picker floats its header over the surface', (
    tester,
  ) async {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      discoveryApp(CatalogPicker(state: state, multiple: true)),
    );
    await tester.pumpAndSettle();
    final scroll = pickerScroll();
    final opaque = tester.widget<ColoredBox>(_header);
    expect(opaque.color, tester.element(_header).tokens.surface);
    await tester.drag(scroll, const Offset(0, -900));
    await tester.pumpAndSettle();
    _expectHidden();
    await tester.drag(scroll, const Offset(0, 30));
    await tester.pumpAndSettle();
    _expectShown(tester, scroll);
    await tester.enterText(_search, 'Synthetic 6');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_search).controller!.text, 'Synthetic 6');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion reveals without an animation', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    await tester.pumpAndSettle();
    final scroll = browserScroll();
    await tester.drag(scroll, const Offset(0, -900));
    await tester.pumpAndSettle();
    _expectHidden();
    final gesture = await tester.startGesture(tester.getCenter(scroll));
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 6));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getTopLeft(_header).dy,
      closeTo(tester.getTopLeft(scroll).dy, 1),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    _expectShown(tester, scroll);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('restored offsets keep their place and the header stays out', (
    tester,
  ) async {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    final controller = CatalogBrowserController();
    await tester.pumpWidget(browser(state, controller: controller));
    await tester.pumpAndSettle();
    await tester.drag(browserScroll(), const Offset(0, -900));
    await tester.pumpAndSettle();
    final offset = _offset(tester, browserScroll());
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(browser(state, controller: controller));
    await tester.pumpAndSettle();
    expect(_offset(tester, browserScroll()), closeTo(offset, 1));
    _expectHidden();
    expect(
      find.byType(CatalogFloatingHeader, skipOffstage: false),
      findsOneWidget,
    );
    // A jump back to the top shows the header in its own place.
    tester.state<ScrollableState>(browserScroll()).position.jumpTo(0);
    await tester.pumpAndSettle();
    _expectShown(tester, browserScroll());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('2x text at 320dp keeps one header row and still floats', (
    tester,
  ) async {
    setPhone(tester, width: 320, textScale: 2);
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    await tester.pumpAndSettle();
    final scroll = browserScroll();
    _expectShown(tester, scroll);
    expect(tester.takeException(), isNull);
    expect(
      tester.getCenter(_filters).dy,
      closeTo(tester.getCenter(_search).dy, 1),
    );
    expect(tester.getSize(_filters).shortestSide, greaterThanOrEqualTo(48));
    expect(tester.getRect(_header).right, lessThanOrEqualTo(320));
    expectNoSplitWords(tester, within: _header);
    await tester.drag(scroll, const Offset(0, -900));
    await tester.pumpAndSettle();
    _expectHidden();
    await tester.drag(scroll, const Offset(0, 30));
    await tester.pumpAndSettle();
    _expectShown(tester, scroll);
    expect(
      tester.getTopLeft(_header).dy,
      closeTo(tester.getTopLeft(scroll).dy, 1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('taps in the header band reach the header only while shown', (
    tester,
  ) async {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    await tester.pumpAndSettle();
    final scroll = browserScroll();
    await tester.drag(scroll, const Offset(0, -900));
    await tester.drag(scroll, const Offset(0, 30));
    await tester.pumpAndSettle();
    _expectShown(tester, scroll);
    // A point in the band that both the shown header and a row occupy.
    final point = tester.getCenter(_search);
    final rows = find.byType(CatalogPickerRow);
    expect(
      rows.evaluate().any(
        (row) => tester.getRect(find.byWidget(row.widget)).contains(point),
      ),
      isTrue,
      reason: 'a row must sit under the floating header',
    );
    expect(_hitsRenderOf(tester, point, _search), isTrue);
    expect(_hitsRenderOf(tester, point, rows), isFalse);
    await tester.drag(scroll, const Offset(0, -300));
    await tester.pumpAndSettle();
    _expectHidden();
    expect(_hitsRenderOf(tester, point, rows), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a hidden header leaves the semantics tree', (tester) async {
    final semantics = tester.ensureSemantics();
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    await tester.pumpAndSettle();
    final scroll = browserScroll();
    final l = AppLocalizations.of(tester.element(scroll));
    final filters = CatalogLabels('en').filterCount(0);
    var strings = _semanticStrings(tester);
    expect(strings, contains(l.exerciseSheetSearchHint));
    expect(strings, contains(filters));
    await tester.drag(scroll, const Offset(0, -900));
    await tester.pumpAndSettle();
    _expectHidden();
    strings = _semanticStrings(tester);
    expect(strings, isNot(contains(l.exerciseSheetSearchHint)));
    expect(strings, isNot(contains(filters)));
    await tester.drag(scroll, const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(_semanticStrings(tester), contains(l.exerciseSheetSearchHint));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a replaced scroll position moves the header listener', (
    tester,
  ) async {
    // A new physics type makes the Scrollable create a new position; a new
    // controller alone only re-attaches the same one.
    ScrollPhysics physics = const ClampingScrollPhysics();
    late StateSetter swap;
    const box = Key('floating-box');
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            swap = setState;
            return CustomScrollView(
              physics: physics,
              slivers: [
                const CatalogFloatingHeader(
                  child: ColoredBox(
                    key: box,
                    color: Color(0xFF101010),
                    child: SizedBox(height: 60),
                  ),
                ),
                SliverList.builder(
                  itemCount: 200,
                  itemBuilder: (context, i) => const SizedBox(height: 50),
                ),
              ],
            );
          },
        ),
      ),
    );
    final scroll = find.byType(Scrollable);
    final header = find.byKey(box);
    Future<void> hideAndReveal() async {
      await tester.drag(scroll, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(header.hitTestable(), findsNothing);
      // tester.drag ends before layout sees it, so only the stop listener
      // on the current position can bring the header back.
      await tester.drag(scroll, const Offset(0, 30));
      await tester.pumpAndSettle();
      expect(header.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(header).dy, closeTo(0, 1));
    }

    await hideAndReveal();
    final before = tester.state<ScrollableState>(scroll).position;
    swap(
      () => physics = const ClampingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scroll).position, isNot(same(before)));
    await hideAndReveal();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
