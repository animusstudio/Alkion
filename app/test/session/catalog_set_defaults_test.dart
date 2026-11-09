import 'package:alkion/data/catalog_load_history.dart' show CatalogLastSet;
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/session/catalog_set_defaults.dart';
import 'package:flutter_test/flutter_test.dart';

CatalogSelectionEvidence _selection(String profile) => CatalogSelectionEvidence(
  exerciseId: 'synthetic-exercise',
  contextId: 'synthetic-context',
  contextRevision: 1,
  displayLabel: 'Synthetic',
  profile: CatalogMeasurementProfileEvidence.forKey(profile),
);

CatalogMetricEvidence _v(String metric, String text, [String? unit]) =>
    CatalogMetricEvidence.fromInput(
      text,
      metric: metric,
      unit: unit ?? CatalogMetricEvidence.defaultUnit(metric),
    );

Map<String, Object?> _json(Map<String, CatalogMetricEvidence> metrics) => {
  for (final entry in metrics.entries) entry.key: entry.value.toJson(),
};

CatalogLastSet _set(bool warmup, String load, String reps) => CatalogLastSet(
  isWarmup: warmup,
  metrics: {
    'reported_load': _v('reported_load', load),
    'repetitions': _v('repetitions', reps),
  },
);

void main() {
  final loadReps = _selection('load_reps');
  // Last session: warm-ups 20x10, 30x6; working 50x8, 52.5x7, 55x5.
  final lastSets = [
    _set(true, '20', '10'),
    _set(false, '50', '8'),
    _set(true, '30', '6'),
    _set(false, '52.5', '7'),
    _set(false, '55', '5'),
  ];
  final top = {
    'reported_load': _v('reported_load', '55'),
    'repetitions': _v('repetitions', '5'),
  };

  Map<String, Object?> defaults({
    bool warmup = false,
    int index = 0,
    Map<String, CatalogMetricEvidence> targets = const {},
    int? fixedReps,
    List<CatalogLastSet> last = const [],
    Map<String, CatalogMetricEvidence>? lastTop,
    CatalogSelectionEvidence? selection,
  }) => _json(
    catalogSetDefaults(
      selection: selection ?? loadReps,
      isWarmup: warmup,
      index: index,
      slotTargets: targets,
      fixedReps: fixedReps,
      lastSets: last,
      lastTop: lastTop,
    ),
  );

  group('precedence per metric', () {
    final table =
        <
          ({
            String name,
            bool warmup,
            int index,
            Map<String, CatalogMetricEvidence> targets,
            int? fixedReps,
            List<CatalogLastSet> last,
            Map<String, CatalogMetricEvidence>? lastTop,
            Map<String, String> expected,
          })
        >[
          (
            name: 'no history and no targets opens empty',
            warmup: false,
            index: 0,
            targets: const {},
            fixedReps: null,
            last: const [],
            lastTop: null,
            expected: const {},
          ),
          (
            name: 'same-numbered working set',
            warmup: false,
            index: 1,
            targets: const {},
            fixedReps: null,
            last: lastSets,
            lastTop: top,
            expected: const {'reported_load': '52.5', 'repetitions': '7'},
          ),
          (
            name: 'beyond the last session falls back to its top set',
            warmup: false,
            index: 3,
            targets: const {},
            fixedReps: null,
            last: lastSets,
            lastTop: top,
            expected: const {'reported_load': '55', 'repetitions': '5'},
          ),
          (
            name: 'slot target beats the same-numbered set per metric',
            warmup: false,
            index: 0,
            targets: {'reported_load': _v('reported_load', '60')},
            fixedReps: null,
            last: lastSets,
            lastTop: top,
            expected: const {'reported_load': '60', 'repetitions': '8'},
          ),
          (
            name: 'fixed authored reps beat the same-numbered set',
            warmup: false,
            index: 0,
            targets: const {},
            fixedReps: 6,
            last: lastSets,
            lastTop: top,
            expected: const {'reported_load': '50', 'repetitions': '6'},
          ),
          (
            name: 'a repetitions slot target beats fixed reps',
            warmup: false,
            index: 0,
            targets: {'repetitions': _v('repetitions', '4')},
            fixedReps: 6,
            last: const [],
            lastTop: null,
            expected: const {'repetitions': '4'},
          ),
          (
            name: 'warm-ups match by warm-up index',
            warmup: true,
            index: 1,
            targets: const {},
            fixedReps: null,
            last: lastSets,
            lastTop: top,
            expected: const {'reported_load': '30', 'repetitions': '6'},
          ),
          (
            name: 'a warm-up never takes the top set',
            warmup: true,
            index: 2,
            targets: const {},
            fixedReps: null,
            last: lastSets,
            lastTop: top,
            expected: const {},
          ),
          (
            name: 'a warm-up ignores fixed working reps',
            warmup: true,
            index: 0,
            targets: const {},
            fixedReps: 6,
            last: const [],
            lastTop: top,
            expected: const {},
          ),
          (
            name: 'slot targets still apply to warm-ups, as before',
            warmup: true,
            index: 5,
            targets: {'reported_load': _v('reported_load', '40')},
            fixedReps: null,
            last: lastSets,
            lastTop: top,
            expected: const {'reported_load': '40'},
          ),
        ];
    for (final row in table) {
      test(row.name, () {
        final result = defaults(
          warmup: row.warmup,
          index: row.index,
          targets: row.targets,
          fixedReps: row.fixedReps,
          last: row.last,
          lastTop: row.lastTop,
        );
        expect({
          for (final entry in result.entries)
            entry.key: (entry.value as Map)['raw'],
        }, row.expected);
      });
    }
  });

  test('invalid, empty and missing values are skipped, not copied', () {
    final invalid = CatalogLastSet(
      isWarmup: false,
      metrics: {
        'reported_load': _v('reported_load', 'abc'),
        'repetitions': const CatalogMetricEvidence(
          state: ValueState.missing,
          raw: null,
          unit: 'count',
        ),
      },
    );
    expect(invalid.metrics['reported_load']!.state, ValueState.invalid);
    // An invalid slot target and an invalid same-numbered value fall through
    // to the top set; a missing value too.
    expect(
      defaults(
        targets: {'reported_load': _v('reported_load', '')},
        last: [invalid],
        lastTop: top,
      ),
      _json(top),
    );
    // With no valid fallback the metric stays absent.
    expect(defaults(last: [invalid]), isEmpty);
    expect(
      defaults(
        last: [
          CatalogLastSet(
            isWarmup: false,
            metrics: {
              'reported_load': const CatalogMetricEvidence(
                state: ValueState.unknown,
                raw: '1e1000',
                unit: 'kg',
              ),
            },
          ),
        ],
      ),
      isEmpty,
    );
  });

  test('values are copied verbatim: raw text, state and unit', () {
    final exact = CatalogLastSet(
      isWarmup: false,
      metrics: {
        'reported_load': _v('reported_load', '45.000000000000000001', 'lb'),
        'repetitions': _v('repetitions', '007'),
      },
    );
    final result = catalogSetDefaults(
      selection: loadReps,
      isWarmup: false,
      index: 0,
      lastSets: [exact],
    );
    expect(_json(result), _json(exact.metrics));
    expect(result['reported_load']!.unit, 'lb');
    expect(result['reported_load']!.raw, '45.000000000000000001');
    expect(result['repetitions']!.raw, '007');
    // Typing the same text produces the same evidence.
    expect(
      result['reported_load']!.toJson(),
      _v('reported_load', '45.000000000000000001', 'lb').toJson(),
    );
  });

  test(
    'non-load profiles prefill their own metrics; optional ones absent last time stay absent',
    () {
      final duration = _selection('duration_distance_optional');
      final last = [
        CatalogLastSet(
          isWarmup: false,
          metrics: {'duration': _v('duration', '45')},
        ),
        CatalogLastSet(
          isWarmup: false,
          metrics: {
            'duration': _v('duration', '60'),
            'distance': _v('distance', '200'),
          },
        ),
      ];
      expect(
        defaults(selection: duration, last: last),
        _json({'duration': _v('duration', '45')}),
      );
      expect(
        defaults(selection: duration, index: 1, last: last),
        _json({
          'duration': _v('duration', '60'),
          'distance': _v('distance', '200'),
        }),
      );
      // Fixed reps never add a metric outside the profile.
      expect(defaults(selection: duration, fixedReps: 8), isEmpty);
    },
  );

  test('inputs are not modified', () {
    final targets = {'reported_load': _v('reported_load', '60')};
    final copy = _json(targets);
    defaults(targets: targets, last: lastSets, lastTop: top);
    expect(_json(targets), copy);
    expect(lastSets, hasLength(5));
  });
}
