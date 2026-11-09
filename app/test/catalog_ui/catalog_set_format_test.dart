import 'package:alkion/catalog_ui/catalog_set_format.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

CatalogSetEvidence _set(
  String profile,
  Map<String, CatalogMetricEvidence> metrics,
) => CatalogSetEvidence(
  selection: CatalogSelectionEvidence(
    exerciseId: 'synthetic-exercise',
    contextId: 'synthetic-context',
    contextRevision: 1,
    displayLabel: 'Synthetic exercise',
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

  group('catalogSetCompact', () {
    final en = lookupAppLocalizations(const Locale('en'));

    for (final (name, evidence, expected) in [
      (
        'load and reps',
        _set('load_reps', {
          'reported_load': _q('reported_load', '18'),
          'repetitions': _q('repetitions', '12'),
        }),
        '18 kg × 12',
      ),
      (
        'duration only',
        _set('duration_distance_optional', {'duration': _q('duration', '45')}),
        '45 s',
      ),
      (
        'distance and duration in profile order',
        _set('distance_duration', {
          'distance': _q('distance', '200'),
          'duration': _q('duration', '45'),
        }),
        '200 m · 45 s',
      ),
      (
        'load and reps grouped where reps sit, then duration',
        _set('reps_duration_optional_load', {
          'repetitions': _q('repetitions', '12'),
          'duration': _q('duration', '30'),
          'reported_load': _q('reported_load', '18'),
        }),
        '18 kg × 12 · 30 s',
      ),
      (
        'reps only uses the plural key',
        _set('reps_distance_optional', {
          'repetitions': _q('repetitions', '12'),
        }),
        '12 reps',
      ),
      (
        'a single rep',
        _set('reps_distance_optional', {'repetitions': _q('repetitions', '1')}),
        '1 rep',
      ),
      (
        'load only, after the required duration',
        _set('duration_load_optional', {
          'duration': _q('duration', '60'),
          'reported_load': _q('reported_load', '20'),
        }),
        '60 s · 20 kg',
      ),
      (
        'values and units exactly as stored: no conversion, no rounding',
        _set('load_reps', {
          'reported_load': _q('reported_load', '060.250000000000001', 'lb'),
          'repetitions': _q('repetitions', '08'),
        }),
        '060.250000000000001 lb × 08',
      ),
      (
        'empty and invalid metrics are left out',
        _set('reps_duration_optional_load', {
          'repetitions': _q('repetitions', '10'),
          'duration': _q('duration', ''),
          'reported_load': _q('reported_load', 'abc'),
        }),
        '10 reps',
      ),
      (
        'a missing optional metric is left out',
        _set('reps_duration_optional_load', {
          'repetitions': _q('repetitions', '10'),
          'duration': const CatalogMetricEvidence(
            state: ValueState.missing,
            raw: null,
            unit: 's',
          ),
        }),
        '10 reps',
      ),
      ('no metrics', _set('load_reps', const {}), ''),
    ]) {
      test(name, () => expect(catalogSetCompact(evidence, en), expected));
    }

    test('reps read naturally in every locale', () {
      final evidence = _set('reps_distance_optional', {
        'repetitions': _q('repetitions', '12'),
      });
      expect(
        {
          for (final code in ['en', 'de', 'it', 'es'])
            code: catalogSetCompact(
              evidence,
              lookupAppLocalizations(Locale(code)),
            ),
        },
        {'en': '12 reps', 'de': '12 Wdh.', 'it': '12 rip.', 'es': '12 rep.'},
      );
    });

    test('the runs mark values, units and separators', () {
      final runs = catalogSetRuns(
        _set('load_reps', {
          'reported_load': _q('reported_load', '18'),
          'repetitions': _q('repetitions', '12'),
        }),
        en,
      );
      expect(runs.map((r) => (r.text, r.role)), [
        ('18', CatalogSetRunRole.value),
        (' kg', CatalogSetRunRole.unit),
        (' × ', CatalogSetRunRole.separator),
        ('12', CatalogSetRunRole.value),
      ]);
      final reps = catalogSetRuns(
        _set('reps_distance_optional', {
          'repetitions': _q('repetitions', '12'),
        }),
        en,
      );
      expect(reps.map((r) => (r.text, r.role)), [
        ('12', CatalogSetRunRole.value),
        (' reps', CatalogSetRunRole.unit),
      ]);
    });
  });

  group('CatalogSetText', () {
    testWidgets('mono numbers with smaller units, as one line', (tester) async {
      await tester.pumpWidget(
        wrapL10n(
          CatalogSetText(
            _set('load_reps', {
              'reported_load': _q('reported_load', '18'),
              'repetitions': _q('repetitions', '12'),
            }),
          ),
        ),
      );
      final rich = tester.widget<RichText>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == '18 kg × 12',
        ),
      );
      final spans = (rich.text as TextSpan).children!.first as TextSpan;
      final children = spans.children!.cast<TextSpan>();
      expect(children.first.style!.fontSize, 15);
      expect(children[1].style!.fontSize, 12);
      expect(children.last.style!.fontSize, 15);
      expect(rich.maxLines, 1);
    });

    testWidgets('a set with no valid metric shows a dash', (tester) async {
      await tester.pumpWidget(
        wrapL10n(CatalogSetText(_set('load_reps', const {}))),
      );
      expect(find.text('—'), findsOneWidget);
    });

    for (final code in ['en', 'de', 'it']) {
      testWidgets('a long set scales down whole at 320dp / 2.0x ($code)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 600),
              textScaler: TextScaler.linear(2.0),
            ),
            child: wrapL10n(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: CatalogSetText(
                    _set('distance_duration_load', {
                      'distance': _q('distance', '1200.5'),
                      'duration': _q('duration', '3600'),
                      'reported_load': _q('reported_load', '142.25'),
                    }),
                  ),
                ),
              ),
              locale: Locale(code),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        const text = '1200.5 m · 3600 s · 142.25 kg';
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.getRect(find.text(text)).right, lessThanOrEqualTo(304));
        expectNoSplitWords(tester);
      });
    }
  });
}
