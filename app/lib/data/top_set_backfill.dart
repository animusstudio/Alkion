import '../store/local_store.dart';
import 'session_writer.dart';

/// The id of the heaviest non-warmup set among [groupRows] (all from ONE
/// (session,exercise) group), tie-break weight DESC (numeric), reps DESC,
/// set_number ASC, id ASC. Returns null if there is no non-warmup set.
/// Unlike [topSetIdsToStamp], this does NOT skip groups that already have a
/// flagged top set — callers that re-derive want the true winner regardless.
String? heaviestNonWarmupId(List<Map<String, Object?>> groupRows) {
  Map<String, Object?>? best;
  for (final r in groupRows) {
    if (r['catalog_set_bytes'] != null) continue;
    if ((r['is_warmup'] as int? ?? 0) != 0) {
      continue;
    }
    if (best == null) {
      best = r;
      continue;
    }
    final rw = double.tryParse(r['weight_kg']?.toString() ?? '') ?? 0;
    final bw = double.tryParse(best['weight_kg']?.toString() ?? '') ?? 0;
    final rr = r['reps'] is int ? r['reps'] as int : 0,
        br = best['reps'] is int ? best['reps'] as int : 0;
    final rn = r['set_number'] as int? ?? 0,
        bn = best['set_number'] as int? ?? 0;
    final rid = r['id'] as String, bid = best['id'] as String;
    if (rw > bw ||
        (rw == bw && rr > br) ||
        (rw == bw && rr == br && rn < bn) ||
        (rw == bw && rr == br && rn == bn && rid.compareTo(bid) < 0)) {
      best = r;
    }
  }
  return best?['id'] as String?;
}

/// Given raw `sets` rows, return the ids to stamp is_top_set=1: for each
/// (session, exercise) group with NO non-warmup set already flagged, the
/// heaviest non-warmup set (tie-break weight DESC, reps DESC, set_number ASC,
/// id ASC). weight_kg is TEXT → compare numerically.
Set<String> topSetIdsToStamp(List<Map<String, Object?>> rows) {
  final groups = <String, List<Map<String, Object?>>>{};
  for (final r in rows) {
    if (r['catalog_set_bytes'] != null) continue;
    final key = '${r['session_id']}|${r['exercise_id']}';
    (groups[key] ??= []).add(r);
  }
  final out = <String>{};
  for (final g in groups.values) {
    final working = g.where((r) => (r['is_warmup'] as int? ?? 0) == 0).toList();
    if (working.isEmpty) {
      continue;
    }
    if (working.any((r) => (r['is_top_set'] as int? ?? 0) == 1)) {
      continue;
    }
    final id = heaviestNonWarmupId(working);
    if (id != null) {
      out.add(id);
    }
  }
  return out;
}

/// One-time, idempotent backfill of is_top_set for existing local sessions
/// (no-op once every group already has a top set). Safe to run every launch.
/// One source operation (read and write); [parent] when part of a larger one.
Future<void> backfillTopSets(LocalDatabase db) => db.writeTransaction((
  tx,
) async {
  final rows = await tx.getAll(
    'SELECT * FROM reps_compat1_legacy_local WHERE deleted=0',
  );
  final ids = topSetIdsToStamp(
    rows.map((r) => Map<String, Object?>.from(r)).toList(),
  );
  for (final row in rows.where((r) => ids.contains(r['id']))) {
    final derived = await tx.getOptional(
      'SELECT result_id FROM derived_results WHERE profile_id=? AND result_id=?',
      [tx.profileId, 'workout-set:${row['id']}:${row['revision']}'],
    );
    if (derived == null) {
      await writeCompatibleSet(
        tx,
        row['id'] as String,
        row['revision'] as int,
        top: 1,
        pr: row['is_pr'] as int? ?? 0,
      );
    }
  }
});
