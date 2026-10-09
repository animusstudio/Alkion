# Legacy account writer fence

Implemented server slice: the authenticated `/sync/upload` transaction initializes
and locks a durable account authority row before reading any body bytes. It holds
that lock through savepoints, set/PR recomputation and commit. Missing gate storage
or instance identity, frozen/retired authority, oversized/unreadable bodies and
transaction failures return 503 without acknowledging the batch. Expired tokens
remain 401. Active malformed JSON remains an accepted no-op after a successful
gate transaction. Historical callers need no installation headers.

Uploads buffer at most 1 MiB and have a 10 second transaction/read deadline. The
handler sets the HTTP read deadline and closes a canceled request body. The HTTP
server uses the same read timeout. A queue larger than this bound remains pending;
its client must submit a smaller batch before normal uploads can resume.

`internal/migration.LockAccountWriter(ctx, tx, accountID)` initializes under the
unique account key before `SELECT ... FOR UPDATE`; it never invents active state
on a database failure. `Store.Freeze(ctx, command)` uses the same row lock, verifies
canonical nonzero UUID identities, the exact old instance/account, next epoch and
validated request hash, and atomically records FROZEN plus an immutable receipt.
Exact retries return the persisted receipt; different command identities conflict.
There is no exposed freeze route, reopen function, peer transport, surrender or
Hub activation implementation in this slice. Trusted controls and consent belong
to the next protocol slice.

Snapshot format `reps-account-snapshot-v1` contains the pinned old account/instance
and seven families in alphabetical order. Each family contains every column of
its rows ordered by UUID. User-owned rows and shared exercise/day templates are
included, with PostgreSQL session timezone pinned to UTC. The exact canonical JSON
bytes are stored as `bytea`; SHA-256 over those bytes reproduces the receipt digest.
JSONB does not preserve that byte representation. Freeze receipts reject UPDATE
and DELETE, including attempted authority/account cascades. The migration has no
ordinary down path because removing the gate can reopen retired accounts.

## Tracked writer inventory

| Writer / configuration evidence | Dataset effects | Fence / disposition |
| --- | --- | --- |
| `internal/api/sync_upload.go`, registered by `internal/api/router.go` | sessions, sets, bodyweight_logs, exercises, day_templates, day_template_items, muscle_targets; computed top-set/PR changes | Fenced in the same transaction before decoding. All seven families covered by real PostgreSQL tests. |
| `internal/api/auth_handlers.go`, `internal/auth/users.go`, `internal/auth/refresh_store.go` | users and refresh tokens | Authentication/account creation only; no workout dataset writes or account deletion route. Password changes do not establish writer authority. |
| `cmd/createuser/main.go` | User creation/password reset | No workout writes. Its database credential is an administrative capability; deployed privileges are unverified. |
| `cmd/genkey`, health/readiness and JWKS handlers | No database workout mutations | Outside the dataset writer set. |
| Embedded startup migrations in `cmd/server/main.go`, `internal/db/migrate.go`, migrations 00001–00022 | Schema, seed templates, exercise traits/rest and day schedule/focus backfills | These maintenance writes bypass the account gate. A release must apply and then quiesce dataset-changing migrations before certifying a baseline; migration downgrade/restore is not a reopen mechanism. Migration 00023 adds only authority storage. |
| `db/migrations/00004_powersync_replication.sql`, later publication migrations, `powersync/powersync.yaml` | PowerSync consumes source replication with SELECT, REPLICATION and BYPASSRLS | Tracked role has no dataset DML grants. Migration 00023 revokes inherited SELECT on instance/gate/receipts and does not add them to the publication. Actual deployed role memberships/privileges remain unverified. |
| `infra/compose.yml` server and PostgreSQL services | Server uses the configured PostgreSQL initialization identity | Tracked configuration does not separate migration/admin credentials from runtime DML. This potentially bypasses every application fence; deployed credentials and privileges were intentionally not inspected. |
| Manual goose/SQL maintenance, external deployment workers, old images, backups/restores and jobs outside this repository | Potential unrestricted dataset or authority writes | Not fenced or certified here. They must be explicitly disabled/quiesced or moved behind the gate before readiness. Production deployment configuration is outside this checkout and remains unverified. |

## Readiness remains blocked

This slice supplies local gate/snapshot evidence, not a valid global handover.
Unverified deployed writers, old images without this gate, administrative database
credentials and restore paths block readiness. No production services or role
memberships were inspected, changed or deployed. Template maintenance and any
cross-account exercise references need disposition before a stable migration
baseline can be certified. Device/SDK response behavior, R1/R2/R3 evidence,
authenticated peer binding and H6 recovery remain separate acceptance gates.

Tests use only generated identities and synthetic workout fixtures in an owned
disposable PostgreSQL database. Frozen test accounts/immutable receipts can remain
until that entire disposable container is discarded; ordinary deletion is denied.
