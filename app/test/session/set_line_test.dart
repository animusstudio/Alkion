import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/tag.dart';

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

CatalogSetEvidence _typed({
  String profile = 'load_reps',
  Map<String, CatalogMetricEvidence> metrics = const {},
}) => CatalogSetEvidence(
  selection: CatalogSelectionEvidence(
    exerciseId: 'synthetic-exercise',
    contextId: 'synthetic-context',
    contextRevision: 1,
    displayLabel: 'Synthetic press',
    contextLabel: 'Machine A',
    profile: CatalogMeasurementProfileEvidence.forKey(profile),
  ),
  metrics: metrics,
);

CatalogMetricEvidence _q(String metric, String raw, [String? unit]) =>
    CatalogMetricEvidence.fromInput(
      raw,
      metric: metric,
      unit: unit ?? CatalogMetricEvidence.defaultUnit(metric),
    );

void main() {
  setUpAll(preloadAppFonts);

  late int taps;
  late List<int?> rirs;
  setUp(() {
    taps = 0;
    rirs = [];
  });

  Widget line(
    SetState s, {
    bool prompt = false,
    bool top = false,
    int idx = 1,
    String? variant,
  }) => SetLine(
    set: s,
    workIndex: s.isWarmup ? -1 : idx,
    unit: UnitService(),
    isLiveTop: top,
    isLivePr: false,
    showRirPrompt: prompt,
    onTap: () => taps++,
    onRir: rirs.add,
    variantLabel: variant,
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

  testWidgets('a pending line is a 48dp tap target showing only its index', (
    tester,
  ) async {
    await tester.pumpWidget(wrapL10n(line(_s())));
    // Blank until logged: the values live on the card when focused.
    expect(find.textContaining('140'), findsNothing);
    expect(find.textContaining('×'), findsNothing);
    expect(find.textContaining('RIR'), findsNothing);
    expect(find.text('1'), findsOneWidget);
    expect(
      tester.getSize(find.byType(SetLine)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byType(SetLine));
    expect(taps, 1);
  });

  testWidgets(
    'a pending catalog line is blank: no exercise, no prompt, no quantities',
    (tester) async {
      final set = _s()
        ..catalog = _typed(
          profile: 'load_reps',
          metrics: {
            'reported_load': _q('reported_load', '18'),
            'repetitions': _q('repetitions', '12'),
          },
        );
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrapL10n(line(set, idx: 2)));
      final l = AppLocalizations.of(tester.element(find.byType(SetLine)));
      expect(find.text(l.catalogRequired), findsNothing);
      expect(find.textContaining('Synthetic press'), findsNothing);
      expect(find.textContaining('Machine A'), findsNothing);
      expect(find.textContaining('18'), findsNothing);
      expect(
        tester.getSemantics(find.byType(SetLine)).getSemanticsData().label,
        'Set 2, not done',
      );
      await tester.tap(find.byType(SetLine));
      expect(taps, 1);
      handle.dispose();
    },
  );

  testWidgets(
    'a logged catalog line shows the compact form, RIR as a muted tag, and '
    'never the exercise name',
    (tester) async {
      final set = _s(done: true, rir: 2)
        ..catalog = _typed(
          metrics: {
            'reported_load': _q('reported_load', '18'),
            'repetitions': _q('repetitions', '12'),
          },
        );
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrapL10n(line(set, idx: 2)));
      expect(find.text('18 kg × 12'), findsOneWidget);
      expect(find.textContaining('Load (kg)'), findsNothing);
      expect(find.textContaining('Synthetic press'), findsNothing);
      final tag = tester.widget<Tag>(find.byKey(const Key('set-line-rir')));
      expect((tag.label, tag.tone), ('RIR 2', TagTone.mute));
      expect(
        tester.getSemantics(find.byType(SetLine)).getSemanticsData().label,
        'Set 2, 18 kg × 12, RIR 2, done',
      );
      handle.dispose();
    },
  );

  testWidgets('a different variant shows once, dim, and is read after the '
      'name', (tester) async {
    final set = _s(done: true, rir: null)
      ..catalog = _typed(
        metrics: {
          'reported_load': _q('reported_load', '40', 'lb'),
          'repetitions': _q('repetitions', '8'),
        },
      );
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      wrapL10n(line(set, idx: 3, variant: 'Cable · Machine B')),
    );
    expect(find.text('Cable · Machine B'), findsOneWidget);
    expect(find.text('40 lb × 8'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(SetLine)).getSemanticsData().label,
      'Set 3, Cable · Machine B, 40 lb × 8, done',
    );
    handle.dispose();
  });

  testWidgets('a pending line with a different variant shows only that', (
    tester,
  ) async {
    await tester.pumpWidget(wrapL10n(line(_s(), variant: 'Machine B')));
    expect(find.text('Machine B'), findsOneWidget);
    expect(find.textContaining('×'), findsNothing);
  });

  testWidgets('a logged line shows its RIR and the TOP tag', (tester) async {
    await tester.pumpWidget(wrapL10n(line(_s(done: true), top: true)));
    expect(find.text('RIR 1'), findsOneWidget);
    expect(find.text('TOP'), findsOneWidget);
  });

  testWidgets('tapping the selected chip in the strip clears the RIR', (
    tester,
  ) async {
    await tester.pumpWidget(wrapL10n(line(_s(done: true), prompt: true)));
    await tester.pumpAndSettle();
    expect(find.text('Clear RIR'), findsNothing);
    await tester.tap(find.byKey(const Key('rir-1')));
    expect(rirs, [null]);
    expect(taps, 0);
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

  for (final code in ['en', 'de', 'it', 'es']) {
    testWidgets('a logged catalog line with variant, RIR tag and PR fits '
        '320dp / 2.0x ($code)', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final set = _s(done: true, rir: 3)
        ..catalog = _typed(
          profile: 'reps_duration_optional_load',
          metrics: {
            'repetitions': _q('repetitions', '12'),
            'duration': _q('duration', '30'),
            'reported_load': _q('reported_load', '142.5'),
          },
        );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 900),
            textScaler: TextScaler.linear(2.0),
          ),
          child: wrapL10n(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 29),
              child: SetLine(
                set: set,
                workIndex: 1,
                unit: UnitService(),
                isLiveTop: true,
                isLivePr: true,
                showRirPrompt: false,
                onTap: () {},
                onRir: (_) {},
                onMenu: () {},
                variantLabel: 'Synthetic long variant · Machine B',
              ),
            ),
            locale: Locale(code),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final p = tester.renderObject<RenderParagraph>(
        find.text('142.5 kg × 12 · 30 s'),
      );
      expect(p.didExceedMaxLines, isFalse);
      expect(
        tester.getRect(find.text('142.5 kg × 12 · 30 s')).right,
        lessThanOrEqualTo(320 - 29),
      );
      expect(find.byKey(const Key('set-line-rir')), findsOneWidget);
      expectNoSplitWords(tester);
    });
  }
}
