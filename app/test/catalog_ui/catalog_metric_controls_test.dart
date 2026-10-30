import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/catalog_set_values_editor.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/pending_input.dart';
import 'package:alkion/widgets/ruler_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

CatalogSetEvidence _evidence(
  String profile, [
  Map<String, CatalogMetricEvidence> metrics = const {},
]) => CatalogSetEvidence.fromJson(
  CatalogSetEvidence(
    selection: CatalogSelectionEvidence(
      exerciseId: 'synthetic-exercise',
      contextId: 'synthetic-context',
      contextRevision: 1,
      profile: CatalogMeasurementProfileEvidence.forKey(profile),
      displayLabel: 'Synthetic exercise',
    ),
    metrics: metrics,
  ).toJson(),
);

CatalogMetricEvidence _metric(String metric, String raw, {String? unit}) =>
    CatalogMetricEvidence.fromInput(
      raw,
      metric: metric,
      unit: unit ?? CatalogMetricEvidence.defaultUnit(metric),
    );

// Only the editor's surrounding state is simulated: every callback is applied
// through the actual evidence codec, just as a controller would apply it.
class _Host extends ChangeNotifier {
  _Host(this.evidence);
  CatalogSetEvidence evidence;
  final unit = UnitService();
  final edits = <(String, String, String)>[];

  void edit(String metric, String text, String unit) {
    edits.add((metric, text, unit));
    evidence = CatalogSetEvidence.fromJson(
      CatalogSetEvidence(
        selection: evidence.selection,
        metrics: {
          ...evidence.metrics,
          metric: _metric(metric, text, unit: unit),
        },
      ).toJson(),
    );
    notifyListeners();
  }

  Widget app({String locale = 'en', Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        theme: buildTheme(brightness, accents[0]),
        locale: Locale(locale),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: Listenable.merge([this, unit]),
              builder: (_, _) => CatalogSetValuesEditor(
                evidence: evidence,
                unit: unit,
                onMetricChanged: edit,
              ),
            ),
          ),
        ),
      );

  @override
  void dispose() {
    unit.dispose();
    super.dispose();
  }
}

Finder _ruler(String metric) => find.byKey(Key('catalog-ruler-$metric'));
Finder _type(String metric) => find.byKey(Key('catalog-type-$metric'));
Finder get _field => find.byKey(const Key('number-entry-field'));
Finder get _done => find.byKey(const Key('number-entry-done'));

Future<void> _open(WidgetTester tester, String metric) async {
  final target = _ruler(metric).evaluate().isNotEmpty
      ? find.descendant(
          of: _ruler(metric),
          matching: find.byKey(const Key('ruler-centre')),
        )
      : _type(metric);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(_field, findsOneWidget);
}

void main() {
  setUpAll(preloadAppFonts);

  for (final profile in CatalogMeasurementProfileEvidence.definitions.keys) {
    testWidgets('$profile mounts all required and optional controls unset', (
      tester,
    ) async {
      final host = _Host(_evidence(profile));
      addTearDown(host.dispose);
      final original = host.evidence.toJson();
      await tester.pumpWidget(host.app());
      await tester.pumpAndSettle();
      expect(host.evidence.validForLogging, isFalse);
      expect(host.evidence.metrics, isEmpty);
      expect(host.edits, isEmpty);
      for (final metric in [
        'reported_load',
        'repetitions',
        'duration',
        'distance',
      ]) {
        if (!host.evidence.selection.profile.metrics.contains(metric)) {
          expect(_ruler(metric), findsNothing);
          expect(_type(metric), findsNothing);
        }
      }
      for (final metric in host.evidence.selection.profile.metrics) {
        final target = _type(metric).evaluate().isNotEmpty
            ? _type(metric)
            : _ruler(metric);
        expect(target, findsOneWidget);
        await tester.ensureVisible(target);
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
        if (_ruler(metric).evaluate().isNotEmpty) {
          final ruler = tester.widget<RulerPicker>(_ruler(metric));
          expect(ruler.format(ruler.value), '—', reason: 'unset is not zero');
        }
        await _open(tester, metric);
        expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
        await tester.tap(_done);
        await tester.pumpAndSettle();
      }
      expect(host.edits, isEmpty);
      expect(host.evidence.toJson(), original);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('modal retains leading zeros and exact comma decimal lexemes', (
    tester,
  ) async {
    final host = _Host(_evidence('load_reps'));
    addTearDown(host.dispose);
    await tester.pumpWidget(host.app());
    await _open(tester, 'reported_load');
    await tester.enterText(_field, '00020,500000000000000001');
    await tester.tap(_done);
    await tester.pumpAndSettle();
    await _open(tester, 'repetitions');
    await tester.enterText(_field, '007');
    await tester.tap(_done);
    await tester.pumpAndSettle();
    expect(host.edits, [
      ('reported_load', '00020.500000000000000001', 'kg'),
      ('repetitions', '007', 'count'),
    ]);
    expect(host.evidence.validForLogging, isTrue);
    expect(
      host.evidence.metrics['reported_load']!.raw,
      '00020.500000000000000001',
    );
    expect(host.evidence.metrics['repetitions']!.raw, '007');
  });

  testWidgets('lb evidence survives kg/lb display, untouched Done and cancel', (
    tester,
  ) async {
    final host = _Host(
      _evidence('load_reps', {
        'reported_load': _metric('reported_load', '020.500', unit: 'lb'),
        'repetitions': _metric('repetitions', '007'),
      }),
    );
    addTearDown(host.dispose);
    final original = host.evidence.toJson();
    await tester.pumpWidget(host.app());
    for (final unit in [Unit.kg, Unit.lb, Unit.kg]) {
      host.unit.setUnit(unit);
      await tester.pumpAndSettle();
      await _open(tester, 'reported_load');
      await tester.tap(_done);
      await tester.pumpAndSettle();
      await _open(tester, 'reported_load');
      await tester.enterText(_field, '999');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(_field, findsNothing);
      expect(host.evidence.toJson(), original);
      expect(host.edits, isEmpty);
    }
    host.unit.setUnit(Unit.lb);
    await tester.pumpAndSettle();
    await _open(tester, 'reported_load');
    await tester.enterText(_field, '030,250000000000000001');
    await tester.tap(_done);
    await tester.pumpAndSettle();
    expect(host.edits.single, (
      'reported_load',
      '030.250000000000000001',
      'lb',
    ));
  });

  testWidgets('duration and distance retain exact units and optional clear', (
    tester,
  ) async {
    final host = _Host(
      _evidence('duration_distance_optional', {
        'duration': _metric('duration', '060.000000000000000001'),
        'distance': _metric('distance', '00100.500000000000000001'),
      }),
    );
    addTearDown(host.dispose);
    final original = host.evidence.toJson();
    await tester.pumpWidget(host.app());
    for (final metric in ['duration', 'distance']) {
      await _open(tester, metric);
      await tester.tap(_done);
      await tester.pumpAndSettle();
    }
    expect(host.edits, isEmpty);
    expect(host.evidence.toJson(), original);
    await _open(tester, 'duration');
    await tester.enterText(_field, '042,500000000000000001');
    await tester.tap(_done);
    await tester.pumpAndSettle();
    await _open(tester, 'distance');
    await tester.enterText(_field, '012,250000000000000001');
    await tester.tap(_done);
    await tester.pumpAndSettle();
    expect(host.edits, [
      ('duration', '042.500000000000000001', 's'),
      ('distance', '012.250000000000000001', 'm'),
    ]);
    expect(find.byKey(const Key('catalog-clear-duration')), findsNothing);
    final clear = find.byKey(const Key('catalog-clear-distance'));
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(host.edits.last, ('distance', '', 'm'));
    expect(host.evidence.metrics['distance']!.state, ValueState.empty);
    expect(host.evidence.validForLogging, isTrue);
  });

  testWidgets(
    'unknown optional evidence stays unknown until an explicit edit',
    (tester) async {
      final host = _Host(
        _evidence('duration_load_optional', {
          'duration': _metric('duration', '60'),
          'reported_load': const CatalogMetricEvidence(
            state: ValueState.invalid,
            raw: 'source unavailable',
            unit: 'lb',
          ),
        }),
      );
      addTearDown(host.dispose);
      final original = host.evidence.toJson();
      await tester.pumpWidget(host.app());
      await tester.pumpAndSettle();
      if (_ruler('reported_load').evaluate().isNotEmpty) {
        final ruler = tester.widget<RulerPicker>(_ruler('reported_load'));
        expect(ruler.format(ruler.value), '—');
      }
      await _open(tester, 'reported_load');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(host.edits, isEmpty);
      expect(host.evidence.toJson(), original);
      expect(host.evidence.validForLogging, isFalse);
    },
  );

  testWidgets(
    'unrepresentable exact magnitude remains editable without rewrite',
    (tester) async {
      const raw = '100000000000000000000000000000000000000000000000000001';
      final host = _Host(
        _evidence('duration_distance_optional', {
          'duration': _metric('duration', raw),
        }),
      );
      addTearDown(host.dispose);
      final original = host.evidence.toJson();
      await tester.pumpWidget(host.app());
      await tester.pumpAndSettle();
      await _open(tester, 'duration');
      expect(tester.widget<TextField>(_field).controller!.text, raw);
      await tester.tap(_done);
      await tester.pumpAndSettle();
      expect(host.evidence.toJson(), original);
      expect(host.edits, isEmpty);
      await _open(tester, 'duration');
      await tester.enterText(_field, '042.500000000000000001');
      await tester.tap(_done);
      await tester.pumpAndSettle();
      expect(host.edits.single, ('duration', '042.500000000000000001', 's'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unrepresentable lb evidence is not relabeled as kg', (
    tester,
  ) async {
    const raw = '100000000000000000000000000000000000000000000000000001';
    final host = _Host(
      _evidence('load_reps', {
        'reported_load': _metric('reported_load', raw, unit: 'lb'),
        'repetitions': _metric('repetitions', '007'),
      }),
    );
    addTearDown(host.dispose);
    final original = host.evidence.toJson();
    await tester.pumpWidget(host.app());
    await _open(tester, 'reported_load');
    expect(tester.widget<TextField>(_field).controller!.text, raw);
    // This fallback edits retained raw evidence because a display conversion
    // cannot represent the original quantity. Its title must identify lb.
    expect(find.textContaining('(lb)'), findsWidgets);
    await tester.tap(_done);
    await tester.pumpAndSettle();
    expect(host.evidence.toJson(), original);
    expect(host.edits, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('positive duration underflow retains exact modal evidence', (
    tester,
  ) async {
    final raw = '0.${List.filled(350, '0').join()}1';
    final host = _Host(
      _evidence('duration_distance_optional', {
        'duration': _metric('duration', raw),
      }),
    );
    addTearDown(host.dispose);
    expect(host.evidence.validForLogging, isTrue);
    expect(host.evidence.metrics['duration']!.exact!.coefficient, BigInt.one);
    final original = host.evidence.toJson();
    await tester.pumpWidget(host.app());
    await tester.pumpAndSettle();
    expect(_type('duration'), findsOneWidget);
    expect(_ruler('duration'), findsNothing, reason: 'positive is not zero');
    await _open(tester, 'duration');
    expect(tester.widget<TextField>(_field).controller!.text, raw);
    await tester.tap(_done);
    await tester.pumpAndSettle();
    expect(host.edits, isEmpty);
    expect(host.evidence.toJson(), original);
    await _open(tester, 'duration');
    await tester.enterText(_field, '042.500000000000000001');
    await tester.tap(_done);
    await tester.pumpAndSettle();
    expect(host.edits.single, ('duration', '042.500000000000000001', 's'));
    expect(host.evidence.validForLogging, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'off-step ruler settles silently and a real fling obeys barrier',
    (tester) async {
      final host = _Host(
        _evidence('load_reps', {
          'reported_load': _metric('reported_load', '060.123456789012345678'),
          'repetitions': _metric('repetitions', '007'),
        }),
      );
      addTearDown(host.dispose);
      final original = host.evidence.toJson();
      await tester.pumpWidget(host.app());
      await tester.pumpAndSettle();
      commitPendingInput();
      await tester.pumpAndSettle();
      expect(host.edits, isEmpty);
      expect(host.evidence.toJson(), original);
      await tester.fling(_ruler('reported_load'), const Offset(-150, 0), 3000);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(host.edits, isNotEmpty);
      expect(
        host.edits.every((e) => e.$1 == 'reported_load' && e.$3 == 'kg'),
        isTrue,
      );
      final count = host.edits.length;
      final stopped = host.evidence.toJson();
      commitPendingInput();
      await tester.pumpAndSettle();
      expect(host.edits.length, count);
      expect(host.evidence.toJson(), stopped);
    },
  );

  for (final locale in ['en', 'it', 'de', 'es']) {
    for (final brightness in Brightness.values) {
      for (final width in [320.0, 412.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('metric modal $locale $brightness ${width}dp ${scale}x', (
            tester,
          ) async {
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            tester.view.viewInsets = const FakeViewPadding(bottom: 240);
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.reset);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final host = _Host(_evidence('duration_distance_optional'));
            addTearDown(host.dispose);
            await tester.pumpWidget(
              host.app(locale: locale, brightness: brightness),
            );
            await _open(tester, 'duration');
            expect(tester.getSize(_field).height, greaterThanOrEqualTo(48));
            expect(tester.getSize(_done).height, greaterThanOrEqualTo(48));
            expect(tester.getRect(_done).bottom, lessThanOrEqualTo(560));
            await tester.enterText(_field, '042,500000000000000001');
            await tester.tap(_done);
            await tester.pumpAndSettle();
            expect(host.edits.single, (
              'duration',
              '042.500000000000000001',
              's',
            ));
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          });
        }
      }
    }
  }
}
