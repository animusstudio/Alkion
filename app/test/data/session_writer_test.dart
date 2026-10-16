import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_writer.dart';

class FakeExec implements SqlExecutor {
  final calls = <(String, List<Object?>)>[];
  @override
  Future<void> execute(String sql, [List<Object?> params = const []]) async {
    calls.add((sql, params));
  }
}

void main() {
  test(
    'persistSession writes 1 session + N sets, stamps client flags',
    () async {
      final exec = FakeExec();
      await persistSession(
        exec,
        SessionWrite(
          id: 'sess1',
          dateIso: '2026-05-30',
          dayTemplateId: 'day1',
          splitLabel: 'Upper A - Push',
          durationMin: 42,
          sets: [
            SetWrite(
              id: 's1',
              exerciseId: 'e1',
              setNumber: 1,
              weightKg: '60.00',
              reps: 8,
              rir: 1,
              isWarmup: false,
            ),
            SetWrite(
              id: 's2',
              exerciseId: 'e1',
              setNumber: 2,
              weightKg: '80.00',
              reps: 6,
              rir: 1,
              isWarmup: false,
              isTopSet: true,
              isPr: true,
            ),
          ],
        ),
      );
      expect(exec.calls.length, 3); // 1 session + 2 sets
      expect(exec.calls.first.$1, contains('INSERT INTO sessions'));
      final setInserts = exec.calls
          .where((c) => c.$1.contains('INSERT INTO sets'))
          .toList();
      expect(setInserts.length, 2);
      // client flags are written: is_top_set + is_pr are the last two params.
      expect(setInserts[0].$2.sublist(8, 10), [0, 0]); // default false
      expect(setInserts[1].$2.sublist(8, 10), [1, 1]); // top set + pr
    },
  );

  test('persistSession binds the training day through a subquery', () async {
    final exec = FakeExec();
    await persistSession(
      exec,
      const SessionWrite(
        id: 'sess1',
        dateIso: '2026-09-23',
        dayTemplateId: 'day1',
        splitLabel: 'Upper A',
        durationMin: 42,
        sets: [],
      ),
    );
    expect(
      exec.calls.single.$1,
      contains(
        'SELECT ?, ?, (SELECT id FROM day_templates WHERE id = ?), ?, ?',
      ),
    );
    expect(exec.calls.single.$2, [
      'sess1',
      '2026-09-23',
      'day1',
      'Upper A',
      42,
    ]);
  });

  test(
    'replaceSession updates the session row, never deletes it, and re-inserts the sets',
    () async {
      final exec = FakeExec();
      await replaceSession(
        exec,
        const SessionWrite(
          id: 'sess1',
          dateIso: '2026-09-20',
          dayTemplateId: 'day1',
          splitLabel: 'Upper A',
          durationMin: 55,
          sets: [
            SetWrite(
              id: 's1',
              exerciseId: 'e1',
              setNumber: 1,
              weightKg: '80.00',
              reps: 6,
              rir: 1,
              isWarmup: false,
              isTopSet: true,
            ),
          ],
        ),
      );
      expect(
        exec.calls[0].$1,
        'UPDATE sessions SET split_label = ?, duration_min = ? WHERE id = ?',
      );
      expect(exec.calls[0].$2, ['Upper A', 55, 'sess1']);
      expect(
        exec.calls[1].$1,
        contains('WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE id = ?)'),
      );
      expect(exec.calls[1].$2, [
        'sess1',
        '2026-09-20',
        'day1',
        'Upper A',
        55,
        'sess1',
      ]);
      expect(exec.calls[2].$1, 'DELETE FROM sets WHERE session_id = ?');
      expect(exec.calls[2].$2, ['sess1']);
      expect(exec.calls[3].$1, startsWith('INSERT INTO sets'));
      expect(exec.calls.length, 4);
      expect(
        exec.calls.any((c) => c.$1.contains('DELETE FROM sessions')),
        isFalse,
      );
    },
  );
}
