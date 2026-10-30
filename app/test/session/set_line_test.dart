import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';
import '../support/rir_expect.dart';

SetState _s({
  bool done = false,
  bool warmup = false,
  int? rir = 1,
  double w = 140,
  int reps = 6,
}) => SetState(
  id: 's1',
  weightKg: w,
  reps: reps,
  rir: warmup ? null : rir,
  isWarmup: warmup,
  done: done,
);

void main() {
  setUpAll(preloadAppFonts);

  late int taps;
  late List<int> rirs;
  setUp(() {
    taps = 0;
    rirs = [];
  });

  Widget line(
    SetState s, {
    bool prompt = false,
    bool top = false,
    int idx = 1,
  }) => SetLine(
    set: s,
    workIndex: s.isWarmup ? -1 : idx,
    unit: UnitService(),
    isLiveTop: top,
    isLivePr: false,
    showRirPrompt: prompt,
    onTap: () => taps++,
    onRir: rirs.add,
  );

  testWidgets(
    'the whole row carries button semantics but keeps its text readable',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrapL10n(line(_s(done: true), top: true)));
      final node = tester.getSemantics(find.byType(SetLine));
      expect(node.flagsCollection.isButton, isTrue);
      expect(find.text('140kg  ×  6'), findsOneWidget);
      expect(find.text('TOP'), findsOneWidget);
      handle.dispose();
    },
  );

  testWidgets('a pending line is a 48dp tap target showing weight × reps', (
    tester,
  ) async {
    await tester.pumpWidget(wrapL10n(line(_s())));
    // A Text.rich matches find.text by its whole plain text.
    expect(find.text('140kg  ×  6'), findsOneWidget);
    expect(
      tester.getSize(find.byType(SetLine)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byType(SetLine));
    expect(taps, 1);
  });

  testWidgets(
    'an empty pending catalog row names required evidence without fabricated quantities',
    (tester) async {
      final set = _s()
        ..catalog = CatalogSetEvidence(
          selection: CatalogSelectionEvidence(
            exerciseId: 'synthetic-exercise',
            contextId: 'synthetic-context',
            contextRevision: 1,
            displayLabel: 'Synthetic duration',
            profile: CatalogMeasurementProfileEvidence.forKey(
              'duration_distance_optional',
            ),
          ),
          metrics: const {},
        );
      await tester.pumpWidget(wrapL10n(line(set)));
      final l = AppLocalizations.of(tester.element(find.byType(SetLine)));
      expect(find.text(l.catalogRequired), findsOneWidget);
      expect(find.textContaining('kg'), findsNothing);
      expect(find.textContaining('140'), findsNothing);
      expect(set.catalog!.metrics, isEmpty);
      await tester.tap(find.byType(SetLine));
      expect(taps, 1);
    },
  );

  testWidgets('a logged line shows its RIR and the TOP tag', (tester) async {
    await tester.pumpWidget(wrapL10n(line(_s(done: true), top: true)));
    expect(find.text('RIR 1'), findsOneWidget);
    expect(find.text('TOP'), findsOneWidget);
  });

  testWidgets('a logged working set with no RIR shows no RIR text', (
    tester,
  ) async {
    await tester.pumpWidget(wrapL10n(line(_s(done: true, rir: null))));
    expect(find.text('140kg  ×  6'), findsOneWidget);
    expect(find.textContaining('RIR'), findsNothing);
  });

  testWidgets(
    'the RIR strip shows 48dp chips; a chip tap sets RIR, not focus',
    (tester) async {
      await tester.pumpWidget(wrapL10n(line(_s(done: true), prompt: true)));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('rir-2'))).height, 48);
      await tester.tap(find.byKey(const Key('rir-2')));
      expect(rirs, [2]);
      expect(taps, 0);
    },
  );

  // The line's width in a block on a 320dp and a 412dp phone (the list
  // padding, block border and sets padding take 58dp), and the chip rows
  // the strip must fall into there.
  for (final (width, scale, rows) in const [
    (262.0, 1.0, 2),
    (262.0, 2.0, 2),
    (354.0, 1.0, 1),
    (354.0, 2.0, 2),
  ]) {
    testWidgets(
      'every RIR chip is at least 48x48 at ${width.toInt()}dp / ${scale}x, '
      'in $rows row${rows == 1 ? '' : 's'}',
      (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width + 58, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: wrapL10n(
              SizedBox(width: width, child: line(_s(done: true), prompt: true)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(expectRirChipsAtLeast48(tester), rows);
      },
    );
  }

  testWidgets('in two rows the RIR caption sits level with the first', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapL10n(SizedBox(width: 262, child: line(_s(done: true), prompt: true))),
    );
    await tester.pumpAndSettle();
    expect(expectRirChipsAtLeast48(tester), 2);
    expectCaptionOnFirstRirRow(tester, find.text('RIR'));
  });

  testWidgets(
    'a tap in the gap between the chip rows neither sets RIR nor focuses the set',
    (tester) async {
      await tester.pumpWidget(
        wrapL10n(
          SizedBox(width: 262, child: line(_s(done: true), prompt: true)),
        ),
      );
      await tester.pumpAndSettle();
      final top = tester.getRect(find.byKey(const Key('rir-0')));
      final bottom = tester.getRect(find.byKey(const Key('rir-3')));
      expect(bottom.top, greaterThan(top.bottom)); // two rows, with a gap
      await tester.tapAt(Offset(top.center.dx, (top.bottom + bottom.top) / 2));
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(rirs, isEmpty);
    },
  );

  // In two rows the strip has blank space the chips don't cover: beside the
  // second row, under the caption, and the strip's bottom padding. A tap
  // there would turn the logged set back into the live card.
  testWidgets(
    'a tap in the strip beside or below the chips neither sets RIR nor focuses the set',
    (tester) async {
      await tester.pumpWidget(
        wrapL10n(
          SizedBox(width: 262, child: line(_s(done: true), prompt: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(expectRirChipsAtLeast48(tester), 2);
      final lineRect = tester.getRect(find.byType(SetLine));
      final second = tester.getRect(find.byKey(const Key('rir-3')));
      final beside = Offset(second.left - 6, second.center.dy);
      final below = Offset(
        tester.getRect(find.byKey(const Key('rir-4'))).center.dx,
        second.bottom + 4,
      );
      for (final (where, point) in [
        ('beside the second row', beside),
        ('in the bottom padding', below),
      ]) {
        expect(lineRect.contains(point), isTrue, reason: where);
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(taps, 0, reason: where);
        expect(rirs, isEmpty, reason: where);
      }
    },
  );

  testWidgets('a warm-up never shows the RIR strip and shows a W index', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapL10n(line(_s(done: true, warmup: true), prompt: true)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rir-0')), findsNothing);
    expect(find.text('W'), findsOneWidget);
  });

  testWidgets(
    'the logged value takes the full row width instead of ellipsising',
    (tester) async {
      // A done TOP working set with both the inline RIR text and the TOP tag
      // showing (the widest realistic combination), at a width whose free
      // space the old Flexible-vs-Spacer 50/50 split couldn't fit into.
      await tester.pumpWidget(
        wrapL10n(
          SizedBox(
            width: 380,
            child: line(_s(done: true, w: 142.5, reps: 10), top: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final para = tester.renderObject<RenderParagraph>(
        find.text('142.5kg  ×  10'),
      );
      expect(para.didExceedMaxLines, isFalse);
    },
  );

  testWidgets('no overflow at 320dp / 1.3× (it)', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: wrapL10n(
          SizedBox(
            width: 260,
            child: line(_s(done: true), prompt: true, top: true),
          ),
          locale: const Locale('it'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final lb in [true, false]) {
    for (final width in [320.0, 412.0]) {
      for (final pr in [false, true]) {
        testWidgets(
          'a logged ${pr ? 'PR' : 'TOP'} row shows weight and reps whole at '
          '${width.toInt()}dp / 2.0x in ${lb ? 'lb' : 'kg'}',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final units = UnitService();
            if (lb) units.setUnit(Unit.lb);
            final reps = lb ? 10 : 12;
            final set = _s(done: true, rir: 2, w: lb ? 65 : 142.5, reps: reps);
            await tester.pumpWidget(
              MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 900),
                  textScaler: const TextScaler.linear(2.0),
                ),
                child: wrapL10n(
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SetLine(
                      set: set,
                      workIndex: 1,
                      unit: units,
                      isLiveTop: !pr,
                      isLivePr: pr,
                      showRirPrompt: false,
                      onTap: () {},
                      onRir: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final paras = find
                .byType(RichText)
                .evaluate()
                .map((e) => e.renderObject)
                .whereType<RenderParagraph>()
                .where((p) => p.text.toPlainText().contains('×'))
                .toList();
            expect(paras, hasLength(1));
            final p = paras.single;
            final plain = p.text.toPlainText();
            expect(plain, endsWith('$reps'));
            expect(plain, isNot(contains('…')));
            expect(p.didExceedMaxLines, isFalse);
            // The group may scale down but must stay inside the row.
            final box = tester.getRect(
              find.byWidgetPredicate(
                (w) => w is RichText && w.text.toPlainText().contains('×'),
              ),
            );
            expect(box.right, lessThanOrEqualTo(width - 16));
            expectNoSplitWords(tester);
          },
        );
      }
    }
  }
}
