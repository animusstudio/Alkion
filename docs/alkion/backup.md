# Alkion manual backup and receiving verification

T6 implementation of the spec R7 manual Alkion backup over the accepted T1
coherent-backup primitive and the T2 store boundary. It is Linux/synthetic
development evidence, not a complete legacy backup, an off-device copy, a
scheduled job or device qualification. Status:
[integrated acceptance](acceptance.md).

Code: `app/lib/recovery/backup.dart` (format, covered inventory, writer,
receiving verification), `app/lib/recovery/recovery_host.dart` and the screen
`app/lib/ui/alkion_recovery/recovery_screen.dart`, reached from Profile → Data →
Backup & restore. Restore and forward recovery are in [recovery](recovery.md);
the store boundary is in [storage](storage.md).

## What a backup is

A backup is manual: the owner creates it, copies the file off the device and
checks the copy there. Alkion has no reminder, schedule, dashboard, upload or
service. Work committed after the last verified backup can be lost; the
destination, its protection and retention belong to owner infrastructure. A
share sheet, a copy or a sync folder is **not** backup proof; only a receiving
verification of the copy is. Seven-table JSON exports, replicas and hot copies
of the main SQLite file are not backups (see [exports](exports.md)).

## Frozen format `alkion-backup/1`

One file, `alkion-backup-<profile8>-<UTC stamp>Z-<nonce>.alkionbackup`:

1. the ASCII line `alkion-backup/1`;
2. one line of canonical local JSON (recursively sorted keys): the manifest;
3. the exact SQLite snapshot bytes (single file, rollback-journal mode).

| Manifest field | Content |
| --- | --- |
| `format`, `version` | `alkion-backup`, `1`. Another version is refused, never guessed. |
| `created_at` | Offset-bearing creation instant. |
| `tool` | Writer `alkion-backup-writer/1`, development application ID, pinned `sqlite_async` 0.14.2 / `sqlite3` 3.3.2 and the native SQLite version. |
| `profile` | Profile ID, installation ID and store generation of the snapshot. |
| `schema` | `user_version`, application ID, every migration version/SQL digest and the resulting `sqlite_master` digest. |
| `boundary` | `sqlite_online_backup_single_owned_read_lease`; committed WAL content included; durable input flushed by the caller first; uncommitted keystrokes excluded. Work after this boundary is not in the backup. |
| `inventory` | For every preserved table: row count and SHA-256 of its canonical rows (BLOBs as `{"blob_base64": ...}`, rows ordered by primary key), total rows and an overall digest. |
| `database` | Snapshot length and SHA-256. |
| `exclusions` | Credentials (none are stored), installation identity, locks, `-wal/-shm` sidecars (their committed content is inside the snapshot), other generations and staging, exported files, OS notifications/alarms (timer truth is in SQLite), device preferences (none outside SQLite). |

Covered state is the complete store: the seven domain projections with
tombstones; immutable revisions, corrections and derived results; source
artifacts with exact raw bytes, origin mappings, source revisions/projections,
import generations/journal and correspondence; catalog pins; operations,
dependencies, attempts, outcomes, reviews and decisions (including T5
quarantine evidence); local draft/finished-recovery/timer/semantic settings/goal
initialization/order/catalog selection/onboarding state; replica rows and
checkpoints; restore journal and profile metadata. The writer and verifier
refuse a snapshot containing a table outside this list, so a future table
cannot be silently omitted.

## Writer

`createBackup(store, destination)`; the runtime host first runs the app's
lifecycle flush barrier. The writer:

1. snapshots through `LocalStore.backupTo` (the T1-qualified sqlite3 online
   backup on an owned read lease, ordered after queued writers), so a commit
   that exists only in the WAL is included and later writes are excluded;
2. converts the private snapshot copy to rollback-journal mode and inspects it
   READONLY (schema, integrity, foreign keys, metadata, inventory);
3. writes the container to a hidden `.<name>.partial-<nonce>` file and flushes it;
4. publishes it atomically without replacing an existing name: Android uses the
   min24 NDK `renameat2(RENAME_NOREPLACE)` shim, which consumes the temporary
   name; Linux retains libc `link(2)` and removes its remaining temporary name.
   The writer then fsyncs the directory;
5. re-reads and verifies the published file like any received copy.

A failure removes only the writer's own unpublished temporary files. A published
name is never removed or rewritten. A SIGKILL can leave a hidden partial or work
directory; neither is ever named as a backup and the partial fails verification
while incomplete.

## Receiving verification

`verifyBackupFile(file)` runs wherever the copy is. It checks, in order: file
type and the 512 MiB bound; header and version; canonical manifest bytes;
snapshot length (`backup_truncated`/`backup_length_mismatch`) and SHA-256
(`backup_digest_mismatch`); then, on a private inspection copy opened READONLY,
application ID, newer (`backup_newer_schema`) or unknown schema and migration
history, `integrity_check`, `foreign_key_check`, uncovered tables, single
writable profile metadata, and finally that profile, schema and the complete
recomputed inventory equal the manifest (`backup_inventory_mismatch`). The
check screen reports a verified backup of another profile without offering to
restore it here. Verification evidence and restore evidence are separate.

## Verification

```sh
make -C app format
make -C app analyze
make -C app test TEST="--concurrency=2 test/alkion/recovery/"
make -C app alkion-backup-recovery ALKION_OUTPUT=<fresh backup-proof* directory>
```

`test/alkion/recovery/backup_restore_test.dart` covers a WAL-only commit in the
backup, single publication and receiving verification, an injected disk-full
(`ENOSPC`) while writing (nothing published, source unchanged) and T5 quarantine
evidence surviving byte-exact. The proof target's backup cases are listed in
[recovery](recovery.md#proof-target). Physical `ENOSPC`, power loss, Android
storage/share destinations and off-device media are UNRUN.
