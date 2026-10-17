import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/widgets/rir_picker.dart';

import '../support/l10n_harness.dart';

Finder _chip(int n) => find.byKey(Key('rir-$n'));

/// The chip's own fill: the keyed slot also holds the 3dp gap to its
/// neighbour, the decorated box is what the user sees.
Finder _face(int n) =>
    find.descendant(of: _chip(n), matching: find.byType(DecoratedBox));

Color? _fill(WidgetTester tester, int n) =>
    (tester.widget<DecoratedBox>(_face(n)).decoration as BoxDecoration).color;

Color? _digit(WidgetTester tester, int n) => tester
    .widget<Text>(find.descendant(of: _chip(n), matching: find.byType(Text)))
    .style
    ?.color;

void main() {
  testWidgets('selected RIR is announced independently of color', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      wrapL10n(
        SizedBox(width: 180, child: RirPicker(value: 3, onChanged: (_) {})),
      ),
    );
    for (var n = rirMin; n <= rirMax; n++) {
      expect(
        tester
            .getSemantics(_chip(n))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        n == 3 ? Tristate.isTrue : Tristate.isFalse,
      );
    }
    semantics.dispose();
  });
  Widget picker(int? value, {double width = 320, List<int>? reports}) =>
      wrapL10n(
        SizedBox(
          width: width,
          child: RirPicker(value: value, onChanged: (v) => reports?.add(v)),
        ),
      );

  testWidgets('renders one chip per RIR value, rirMin to rirMax', (
    tester,
  ) async {
    await tester.pumpWidget(picker(1));
    for (var n = rirMin; n <= rirMax; n++) {
      expect(_chip(n), findsOneWidget, reason: 'rir-$n');
    }
    expect(_chip(rirMin - 1), findsNothing);
    expect(_chip(rirMax + 1), findsNothing);
  });

  testWidgets('rirMax can be selected and is reported', (tester) async {
    final reports = <int>[];
    await tester.pumpWidget(picker(rirMax, reports: reports));
    final tokens = tester.element(find.byType(RirPicker)).tokens;
    expect(_fill(tester, rirMax), tokens.action);
    expect(_digit(tester, rirMax), tokens.onAction);
    for (var n = rirMin; n < rirMax; n++) {
      expect(_fill(tester, n), tokens.surface2, reason: 'rir-$n');
    }
    await tester.tap(_chip(rirMax));
    expect(reports, [rirMax]);
  });

  for (final value in [7, null]) {
    testWidgets('a stored $value selects no chip', (tester) async {
      await tester.pumpWidget(picker(value));
      final tokens = tester.element(find.byType(RirPicker)).tokens;
      for (var n = rirMin; n <= rirMax; n++) {
        expect(_fill(tester, n), tokens.surface2, reason: 'rir-$n');
        expect(_digit(tester, n), tokens.dim, reason: 'rir-$n');
      }
    });
  }

  testWidgets('at 288dp the six chips sit in one row of 48dp slots', (
    tester,
  ) async {
    await tester.pumpWidget(picker(1, width: 288));
    final first = tester.getRect(_chip(rirMin));
    for (var n = rirMin; n <= rirMax; n++) {
      final slot = tester.getRect(_chip(n));
      expect(slot.top, first.top, reason: 'rir-$n');
      expect(slot.width, 48, reason: 'rir-$n');
      expect(slot.height, 48, reason: 'rir-$n');
    }
    // The 3dp gap sits between chips, not after the last one.
    expect(tester.getRect(_face(rirMin)).width, 45);
    expect(tester.getRect(_face(rirMax)).width, 48);
  });

  testWidgets('at 287dp the chips split into two rows of three', (
    tester,
  ) async {
    await tester.pumpWidget(picker(1, width: 287));
    final top = tester.getRect(_chip(0));
    final bottom = tester.getRect(_chip(3));
    for (final n in [1, 2]) {
      expect(tester.getRect(_chip(n)).top, top.top, reason: 'rir-$n');
    }
    for (final n in [4, 5]) {
      expect(tester.getRect(_chip(n)).top, bottom.top, reason: 'rir-$n');
    }
    expect(bottom.top, top.bottom + 3); // the row gap
    expect(bottom.left, top.left);
    for (var n = rirMin; n <= rirMax; n++) {
      final slot = tester.getRect(_chip(n));
      expect(slot.width, closeTo(287 / 3, 1e-9), reason: 'rir-$n');
      expect(slot.height, 48, reason: 'rir-$n');
    }
    // Each row ends flush: the last chip of a row keeps no gap.
    expect(tester.getRect(_face(2)).right, tester.getRect(_chip(2)).right);
    expect(tester.getRect(_face(5)).right, tester.getRect(_chip(5)).right);
    expect(tester.getRect(_face(1)).width, closeTo(287 / 3 - 3, 1e-9));
  });

  // The picker's own tap absorber stays out of the semantics tree: only the
  // chips are tap targets for a screen reader.
  testWidgets(
    'the picker exposes one tap node per chip, labelled with its value',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(picker(1));
      final taps = <String>[];
      void walk(SemanticsNode node) {
        final d = node.getSemanticsData();
        if (d.hasAction(SemanticsAction.tap)) taps.add(d.label);
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(RirPicker)));
      expect(taps, hasLength(rirMax - rirMin + 1));
      expect(taps, [for (var n = rirMin; n <= rirMax; n++) '$n']);
      semantics.dispose();
    },
  );

  testWidgets('chips default to 48dp tall', (tester) async {
    await tester.pumpWidget(picker(1));
    expect(tester.getSize(_chip(2)).height, 48);
  });

  testWidgets('RirPicker honours its height', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        SizedBox(
          width: 320,
          child: RirPicker(value: 1, height: 56, onChanged: (_) {}),
        ),
      ),
    );
    expect(tester.getSize(_chip(2)).height, 56);
  });
}
