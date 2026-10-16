import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/muscle_target_repository.dart';

void main() {
  const existing = MuscleTarget(id: 't1', muscle: 'chest', targetSets: 12);

  test('no row + sets>0 -> INSERT with user/muscle/sets', () {
    final op = targetOpFor(
      existing: null,
      sets: 10,
      newId: 'new1',
      userId: 'u1',
      muscle: 'chest',
      nowIso: '2026-06-02T00:00:00Z',
    );
    expect(op!.sql, contains('INSERT INTO muscle_targets'));
    expect(op.args, ['new1', 'u1', 'chest', 10, '2026-06-02T00:00:00Z']);
  });

  test('existing + sets>0 -> UPDATE by id', () {
    final op = targetOpFor(
      existing: existing,
      sets: 15,
      newId: 'x',
      userId: 'u1',
      muscle: 'chest',
      nowIso: 'now',
    );
    expect(op!.sql, 'UPDATE muscle_targets SET target_sets = ? WHERE id = ?');
    expect(op.args, [15, 't1']);
  });

  test('existing + sets==0 -> DELETE by id (no goal)', () {
    final op = targetOpFor(
      existing: existing,
      sets: 0,
      newId: 'x',
      userId: 'u1',
      muscle: 'chest',
      nowIso: 'now',
    );
    expect(op!.sql, 'DELETE FROM muscle_targets WHERE id = ?');
    expect(op.args, ['t1']);
  });

  test('no row + sets==0 -> null (no-op)', () {
    expect(
      targetOpFor(
        existing: null,
        sets: 0,
        newId: 'x',
        userId: 'u1',
        muscle: 'chest',
        nowIso: 'now',
      ),
      isNull,
    );
  });
}
