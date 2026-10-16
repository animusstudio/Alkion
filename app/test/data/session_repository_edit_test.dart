import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_repository.dart';

void main() {
  test('updateSetOp builds an UPDATE with weight/reps/rir', () {
    final op = updateSetOp('set-1', weightKg: '82.50', reps: 5, rir: 1);
    expect(op.sql, contains('UPDATE sets SET'));
    expect(op.sql, contains('weight_kg'));
    expect(op.sql, contains('WHERE id = ?'));
    expect(op.args, ['82.50', 5, 1, 'set-1']);
  });
  test('deleteSetOp targets the id', () {
    final op = deleteSetOp('set-9');
    expect(op.sql, 'DELETE FROM sets WHERE id = ?');
    expect(op.args, ['set-9']);
  });
  test('deleteSessionOp targets the id', () {
    final op = deleteSessionOp('sess-3');
    expect(op.sql, 'DELETE FROM sessions WHERE id = ?');
    expect(op.args, ['sess-3']);
  });
  test('insertSetOp builds an INSERT with the group + defaults', () {
    final op = insertSetOp(
      'set-new',
      sessionId: 's1',
      exerciseId: 'e1',
      setNumber: 3,
      weightKg: '80.00',
      reps: 5,
      rir: 2,
      isWarmup: false,
    );
    expect(op.sql, contains('INSERT INTO sets'));
    expect(op.sql, contains('is_top_set'));
    expect(op.args, ['set-new', 's1', 'e1', 3, '80.00', 5, 2, 0, 0, 0]);
  });
  test('insertSetOp nulls rir and flags warmup for warm-up sets', () {
    final op = insertSetOp(
      'w1',
      sessionId: 's1',
      exerciseId: 'e1',
      setNumber: 1,
      weightKg: '40.00',
      reps: 10,
      rir: 3,
      isWarmup: true,
    );
    expect(op.args, ['w1', 's1', 'e1', 1, '40.00', 10, null, 1, 0, 0]);
  });
}
