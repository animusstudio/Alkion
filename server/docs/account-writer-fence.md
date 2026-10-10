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

**Pre-deployment gate: legacy transaction size.** The bound can strand an
installed client. The `0.18.1+37` client uploads each PowerSync CRUD transaction
as one request and cannot split it. Suppose one transaction's body exceeds
1 MiB, or cannot be sent within 10 seconds. Every retry then gets the same 503,
and that client's queue loops on 503 indefinitely. Its later local writes never
reach the server. Before this fence is deployed anywhere, measure the maximum
single-transaction upload size and duration that the `0.18.1+37` client can
produce, with synthetic data at realistic history sizes. Then confirm both stay
inside the bound with margin, or raise the bound first. The measurement has not
been made, so deploying the fence is blocked on it.

`internal/migration.LockAccountWriter(ctx, tx, accountID)` initializes under the
unique account key before `SELECT ... FOR UPDATE`; it never invents active state
on a database failure. `Store.Freeze(ctx, command)` uses the same row lock, verifies
canonical nonzero UUID identities, the exact old instance/account, next epoch and
validated request hash, and atomically records FROZEN plus an immutable receipt.
Exact retries return the persisted receipt; different command identities conflict.
Explicitly configured owner Freeze/Surrender/Unfreeze routes verify old JWT
ownership and record separate consent. Surrender and Unfreeze fetch current Hub
READY/ABORTED proofs through pinned mTLS outside the transaction, then recheck the
exact locked gate and snapshot. Hub activation remains a separate implementation.

## Owner ordering obligation and the transition-mismatch trap

The handover order starts with the Hub's durable PREPARED barrier and only then
the old Freeze. This server does not enforce that first step. Freeze checks only
its own gate: the exact old instance and account, `OLD_ACTIVE`, epoch = gate epoch
+ 1, and the request hash. The Hub's PREPARED barrier is deliberately not
peer-visible before the old freeze, so Freeze neither fetches nor authenticates
it. Every later step is authenticated: Surrender needs the Hub's READY receipt
and Unfreeze needs the Hub's ABORTED receipt, each for the same transition,
epoch and frozen snapshot.

The owner must therefore:

1. Prepare the transition on the Hub. A first transition is epoch 1; after an
   authenticated abort completion, it is the advanced `OLD_ACTIVE` epoch + 1.
   The Hub accepts no other epoch.
2. Confirm that the Hub reports that transition as PREPARED.
3. Only then freeze this account with the same transition ID and the same
   epoch.

The trap: suppose the account is frozen with transition t1 while the Hub
prepared t2. No authenticated step can then match:

- the Hub's READY for t2 needs a FROZEN receipt for t2;
- Unfreeze of t1 needs a Hub ABORTED receipt for t1, and the Hub's t2
  reservation prevents it from preparing t1;
- the Hub's abort completion for t2 needs an `OLD_ACTIVE` proof for t2.

The account stays FROZEN and the Hub source stays reserved. A Freeze with no
Hub transition at all leaves the account frozen with no tested way back. No
procedure in this branch leaves either state. Recovery from a mismatched or
orphaned freeze is an H6 requirement, and no peer protocol is added for it.

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
deployed authenticated peer binding qualification and H6 recovery remain separate
acceptance gates.

Tests use only generated identities and synthetic workout fixtures in an owned
disposable PostgreSQL database. Frozen test accounts/immutable receipts can remain
until that entire disposable container is discarded; ordinary deletion is denied.

## Authenticated abort completion proof

Unfreeze requires an authenticated exact Hub ABORTED receipt with the same
aggregate digest and frozen server snapshot. It durably records the immutable
unfreeze decision and advances old authority from FROZEN at epoch e to OLD_ACTIVE
at e+1; RETIRED is never reopened. The original four-field command and peer receipt
schema/hashes are unchanged. Request hashing binds unfreeze to its original e,
while its result key reports e+1.

Peer Status for that advanced key additionally checks the current gate remains
OLD_ACTIVE at the exact epoch and decision sequence, with no current transition
or Hub binding. After a later Freeze or RETIRED it denies the historical
OLD_ACTIVE proof. Exact owner command retries still return immutable historical
results without resetting current authority. The Hub independently fetches this
current proof to complete abort and release only its current reservation; its
original transition stays permanently ABORTED.

`TestActualTwoPostgresAbortCompletion` exercises actual public Hub controls,
old JWT owner controls, both pinned mTLS status directions and both real
PostgreSQL authority stores. It proves Prepare -> old Freeze -> blocked Ready
with durable baseline -> Abort -> Unfreeze -> authenticated completion -> ordinary
Hub evidence writes -> fresh higher epoch. It uses generated owner/TLS identities
and synthetic data only; the default Hub checker still blocks READY and no
production cutover, local R1/R2/R3/H6 qualification or activation is claimed.
