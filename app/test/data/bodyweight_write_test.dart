import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/bodyweight_repository.dart';

// We test bodyweightUpsertOp directly: it is a pure top-level function and
// does not need a real db.  FakeExec only has `execute` (no `getOptional`),
// so we cannot fake a full writeTransaction — but the pure helper covers the
// dedup logic completely.

void main() {
  group('bodyweightUpsertOp', () {
    const dateIso = '2026-05-31';
    const kg = 80.0;
    const existingId = 'existing-uuid-123';
    const newId = 'new-uuid-456';

    test('existingId non-null → UPDATE reusing same id, not newId', () {
      final op = bodyweightUpsertOp(existingId, dateIso, kg, newId);

      expect(op.sql, contains('UPDATE bodyweight_logs'));
      expect(op.sql, contains('WHERE id = ?'));
      // The existing id is the second arg; newId must NOT appear
      expect(op.args, contains(existingId));
      expect(op.args, isNot(contains(newId)));
    });

    test('existingId null → INSERT using newId', () {
      final op = bodyweightUpsertOp(null, dateIso, kg, newId);

      expect(op.sql, contains('INSERT INTO bodyweight_logs'));
      expect(op.args, contains(newId));
    });

    test('weight_kg is toStringAsFixed(2) String in both branches', () {
      final opUpdate = bodyweightUpsertOp(existingId, dateIso, 72.5, newId);
      final opInsert = bodyweightUpsertOp(null, dateIso, 72.5, newId);

      expect(opUpdate.args, contains('72.50'));
      expect(opInsert.args, contains('72.50'));
    });

    test('neither op includes user_id or created_at', () {
      final opUpdate = bodyweightUpsertOp(existingId, dateIso, kg, newId);
      final opInsert = bodyweightUpsertOp(null, dateIso, kg, newId);

      for (final op in [opUpdate, opInsert]) {
        expect(op.sql, isNot(contains('user_id')));
        expect(op.sql, isNot(contains('created_at')));
      }
    });
  });
}
