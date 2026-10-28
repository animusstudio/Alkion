# Retired Reps backend evidence

Historical, non-runtime evidence only. These files describe the retired Reps
service; they are not Alkion migrations, setup instructions or a deployable stack.
No app, Make target, test runner or CI workflow executes these copies.

Source: [Alkion commit 661a05bd26b5aaad14850dcfd5bcbd29e7e97730](https://github.com/animusstudio/Alkion/tree/661a05bd26b5aaad14850dcfd5bcbd29e7e97730).
The [exact disposition](disposition.json) records original paths, retained paths
and SHA-256 for every byte-identical copy. The [cleanup inventory](../../alkion/legacy-retirement.md)
explains current callers and removal decisions.

- `schema/*.sql.txt`: all 26 legacy PostgreSQL migrations, including original
  table/column/seed definitions, replication changes and writer-fence migrations
  00023–00026. Text suffixes prevent migration-tool discovery.
- `schema/sync-rules.yaml.txt`: original replication projection and bucket rules,
  preserved as text to interpret historical capture/schema evidence.
- `protocol/*.json`: migration-peer v1 JSON Schema and synthetic wire example.
  Their original bytes and the wire fixture's schema digest remain unchanged.
- `account-writer-fence.md.txt`: original fence and ordering limitations, retained
  as evidence rather than current deployment guidance.

The peer integration test and implementation remain reviewable at the immutable
source reference, including [cross_repository_test.go](https://github.com/animusstudio/Alkion/blob/661a05bd26b5aaad14850dcfd5bcbd29e7e97730/server/internal/migration/cross_repository_test.go),
[protocol.go](https://github.com/animusstudio/Alkion/blob/661a05bd26b5aaad14850dcfd5bcbd29e7e97730/server/internal/migration/protocol.go),
[types.go](https://github.com/animusstudio/Alkion/blob/661a05bd26b5aaad14850dcfd5bcbd29e7e97730/server/internal/migration/types.go)
and [wire.go](https://github.com/animusstudio/Alkion/blob/661a05bd26b5aaad14850dcfd5bcbd29e7e97730/server/internal/migration/wire.go).
Those historical proofs do not authorize live migration, READY, retirement of a
running service or a new Animus connection.
