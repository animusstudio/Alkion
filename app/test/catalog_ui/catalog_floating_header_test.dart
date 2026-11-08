import 'package:alkion/catalog_ui/catalog_floating_header.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(_header).dy, closeTo(viewportTop, 1));
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
}
