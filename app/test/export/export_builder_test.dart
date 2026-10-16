import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/export/export_builder.dart';

void main() {
  group('buildFullExport', () {
    test('envelope fields and table passthrough', () {
      final out = buildFullExport(
        tables: {
          'exercises': [
            {'id': 'e1', 'name': 'Bench', 'slug': 'bench'},
          ],
          'sessions': [
            {'id': 's1', 'user_id': 'u1', 'date': '2026-06-01'},
          ],
        },
        settings: {'unit': 'kg', 'mode': 'dark'},
        exportedAt: DateTime(2026, 6, 3, 18, 0),
      );
      expect(out['format'], 'reps-export');
      expect(out['version'], 1);
      expect(out['kind'], 'full');
      expect(out['exported_at'], DateTime(2026, 6, 3, 18, 0).toIso8601String());
      expect(out['settings'], {'unit': 'kg', 'mode': 'dark'});
      final data = out['data'] as Map<String, dynamic>;
      expect((data['exercises'] as List).single, {
        'id': 'e1',
        'name': 'Bench',
        'slug': 'bench',
      });
    });

    test('strips user_id and created_by from every row of every table', () {
      final out = buildFullExport(
        tables: {
          'sessions': [
            {'id': 's1', 'user_id': 'u1', 'date': '2026-06-01'},
            {'id': 's2', 'user_id': null, 'date': '2026-06-02'},
          ],
          'sets': [
            {'id': 'x1', 'user_id': 'u1', 'session_id': 's1', 'reps': 8},
          ],
          'exercises': [
            {'id': 'e1', 'name': 'Bench', 'created_by': 'u1'},
          ],
        },
        settings: const {},
        exportedAt: DateTime(2026, 6, 3),
      );
      final data = out['data'] as Map<String, dynamic>;
      for (final rows in data.values) {
        for (final row in rows as List) {
          expect((row as Map).containsKey('user_id'), isFalse);
          expect(row.containsKey('created_by'), isFalse);
        }
      }
      // Other columns intact.
      expect(((data['sets'] as List).single as Map)['reps'], 8);
      expect(((data['exercises'] as List).single as Map)['name'], 'Bench');
    });

    test('does not mutate the input rows', () {
      final row = {'id': 's1', 'user_id': 'u1'};
      buildFullExport(
        tables: {
          'sessions': [row],
        },
        settings: const {},
        exportedAt: DateTime(2026, 6, 3),
      );
      expect(row.containsKey('user_id'), isTrue);
    });
  });

  group('buildHistoryExport', () {
    Map<String, Object?> set_({
      required String ex,
      required int n,
      String w = '80.0',
      int reps = 8,
      int? rir = 1,
      int warmup = 0,
      int top = 0,
      int pr = 0,
    }) => {
      'id': '$ex-$n',
      'session_id': 's1',
      'exercise_id': ex,
      'set_number': n,
      'weight_kg': w,
      'reps': reps,
      'rir': rir,
      'is_warmup': warmup,
      'is_top_set': top,
      'is_pr': pr,
    };

    final exercises = {
      'bench': (name: 'Bench Press', muscleGroup: 'chest'),
      'row': (name: 'Barbell Row', muscleGroup: 'back'),
    };

    test('nests sessions → exercises → sets with names resolved', () {
      final out = buildHistoryExport(
        sessions: [
          {
            'id': 's1',
            'date': '2026-06-01',
            'split_label': 'Upper A',
            'duration_min': 62,
          },
        ],
        setsBySession: {
          's1': [
            set_(ex: 'bench', n: 1, warmup: 1, rir: null, w: '40.0'),
            set_(ex: 'bench', n: 2, top: 1, pr: 1),
            set_(ex: 'row', n: 1, w: '60.0', reps: 10),
          ],
        },
        exerciseById: exercises,
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 6, 3),
      );

      expect(out['format'], 'reps-export');
      expect(out['version'], 1);
      expect(out['kind'], 'history');
      expect(out['unit'], 'kg');
      expect(out['date_range'], {'from': '2026-01-01', 'to': '2026-06-03'});

      final sessions = out['sessions'] as List;
      final s = sessions.single as Map<String, dynamic>;
      expect(s['date'], '2026-06-01');
      expect(s['label'], 'Upper A');
      expect(s['duration_min'], 62);

      final exs = s['exercises'] as List;
      expect(exs, hasLength(2));
      final bench = exs[0] as Map<String, dynamic>;
      expect(bench['name'], 'Bench Press');
      expect(bench['muscle_group'], 'chest');
      final benchSets = bench['sets'] as List;
      expect(benchSets, hasLength(2));
      expect(benchSets[0], {
        'weight_kg': 40.0,
        'reps': 8,
        'rir': null,
        'warmup': true,
        'top_set': false,
        'pr': false,
      });
      expect(benchSets[1], {
        'weight_kg': 80.0,
        'reps': 8,
        'rir': 1,
        'warmup': false,
        'top_set': true,
        'pr': true,
      });
    });

    test('unknown exercise falls back to its id, null label to Workout', () {
      final out = buildHistoryExport(
        sessions: [
          {
            'id': 's1',
            'date': '2026-06-01',
            'split_label': null,
            'duration_min': null,
          },
        ],
        setsBySession: {
          's1': [set_(ex: 'ghost', n: 1)],
        },
        exerciseById: const {},
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
      );
      final s = (out['sessions'] as List).single as Map<String, dynamic>;
      expect(s['label'], 'Workout');
      expect(s['duration_min'], isNull);
      final ex = (s['exercises'] as List).single as Map<String, dynamic>;
      expect(ex['name'], 'ghost');
      expect(ex['muscle_group'], '');
    });

    test('session with no sets yields empty exercises, none crash', () {
      final out = buildHistoryExport(
        sessions: [
          {
            'id': 's1',
            'date': '2026-06-01',
            'split_label': 'X',
            'duration_min': 1,
          },
        ],
        setsBySession: const {},
        exerciseById: const {},
        from: DateTime(2026, 6, 1),
        to: DateTime(2026, 6, 1),
      );
      final s = (out['sessions'] as List).single as Map<String, dynamic>;
      expect(s['exercises'], isEmpty);
    });

    test('empty sessions list yields empty sessions array', () {
      final out = buildHistoryExport(
        sessions: const [],
        setsBySession: const {},
        exerciseById: const {},
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 6, 3),
      );
      expect(out['sessions'], isEmpty);
    });
  });
}
