import 'package:powersync/powersync.dart';

import '../capture/source_write_gate.dart';

/// One-time, idempotent backfill of `is_template` for owned rows.
///
/// Builds before the create-exercise/day fix omitted `is_template` on INSERT,
/// so rows created offline (or while sync was erroring) were stored with
/// `is_template = NULL`. The list filters hid them, and — more subtly — the
/// absorb migration's de-dup queries match on the exact `is_template = 0`, so
/// a NULL owned row is invisible to them and a same-named server template or
/// seed could be absorbed a SECOND time, producing a duplicate.
///
/// Normalizing every NULL to 0 makes all owned content canonical: visible in
/// lists and seen by the absorb de-dup. Server template rows (`is_template=1`)
/// and synced rows (the server forces the column) are untouched. Guarded so it
/// only writes when there is something to fix; safe to run on every launch and
/// MUST run before `absorbTemplates`.
///
/// Sync note: these UPDATEs enqueue upstream PATCH ops carrying `is_template`.
/// The server PATCH handlers apply explicit column allowlists that do NOT read
/// `is_template`, so the ops apply as harmless no-op updates (verified against
/// sync_upload.go) — no server state changes.
///
/// Every row this flips becomes newly visible to the catalog/day queries, so
/// the row mappers MUST tolerate whatever those rows contain — see the
/// `double.tryParse` rule in CLAUDE.md (an empty-string base weight in exactly
/// such a row once blanked the whole catalog).
///
/// One source operation (check and write); [parent] when part of a larger one.
Future<void> backfillIsTemplate(PowerSyncDatabase db, {SourceTicket? parent}) =>
    runSourceWrite('boot.backfill_is_template', (_) => _backfillIsTemplate(db),
        parent: parent);

Future<void> _backfillIsTemplate(PowerSyncDatabase db) async {
  final row = await db.get(
    'SELECT '
    '(SELECT COUNT(*) FROM exercises WHERE is_template IS NULL) + '
    '(SELECT COUNT(*) FROM day_templates WHERE is_template IS NULL) + '
    '(SELECT COUNT(*) FROM day_template_items WHERE is_template IS NULL) AS n',
  );
  if ((row['n'] as num? ?? 0) == 0) return;

  await db.writeTransaction((tx) async {
    await tx.execute(
        'UPDATE exercises SET is_template = 0 WHERE is_template IS NULL');
    await tx.execute(
        'UPDATE day_templates SET is_template = 0 WHERE is_template IS NULL');
    await tx.execute(
        'UPDATE day_template_items SET is_template = 0 WHERE is_template IS NULL');
  });
}
