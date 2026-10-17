# Alkion app development

This is the pre-1.0, account-free Alkion app. Flutter is pinned to 3.44.0 with
FVM in [`.fvmrc`](.fvmrc). Follow the current [Alkion development
guide](../docs/alkion/development.md) for toolchain, storage and safety
boundaries. From the repository root, the active app checks are:

```sh
make -C app get
make -C app alkion-toolchain
make -C app analyze
make -C app test TEST='test/path/to/focused_test.dart'
make -C app test
make -C app format
make -C app build
```

`get` uses offline locked dependencies; `format` checks formatting without
writing files; `build` creates the Linux bundle. Use `make -C app test TEST=...`
for a focused test path.

## Historical Reps scaffold notes

The following body is retained from the inherited Reps scaffold. It records the
older PowerSync/backend proof-of-concept and its setup instructions; it is
historical context, not current Alkion setup or run guidance.

# app/

Flutter (Dart) client for workout-tracker. Local-first: reads/writes a local
SQLite database that [PowerSync](https://www.powersync.com/) keeps in sync with
the Go API + Postgres backend. See
`docs/superpowers/specs/2026-05-24-workout-tracker-stack-design.md` for the
stack rationale.

The UI in `lib/ui/` is intentionally minimal/throwaway — UX is deferred to a
later design phase. These foundations exist to prove the sync round-trip
(download of seeded data + upload of local writes).

## Layout

- `lib/sync/schema.dart` — PowerSync local schema for the six synced tables.
- `lib/sync/db.dart` — opens the single `PowerSyncDatabase`, connect/disconnect.
- `lib/sync/connector.dart` — `PowerSyncBackendConnector`: `fetchCredentials`
  (POST `/auth/powersync-token`) and `uploadData` (POST `/sync/upload`).
- `lib/auth/auth_store.dart` — login / refresh / logout + secure token storage.
- `lib/ui/` — throwaway login + exercises-list/write screens.

## Toolchain

Flutter is pinned to 3.44.0 via [fvm](https://fvm.app) in `app/.fvmrc`. Install
the pinned SDK once (from the repo root):

```sh
make -C app install
make -C app doctor   # the Linux toolchain section should be all green
```

All Flutter/Dart commands run through `make -C app <target>`, which invokes
`fvm flutter`/`fvm dart` with the pinned SDK.

## First-time scaffold

`lib/` and `pubspec.yaml` are committed; the platform runner directory
(`linux/`) is generated once, in place (additive — it will not touch `lib/`):

```sh
make -C app scaffold-linux
make -C app get
```

## Run (Linux desktop — foundations validation target)

The backend must be up:

```sh
docker compose -f infra/compose.yml -f infra/compose.dev.yml --env-file infra/.env up -d
make -C app run
```

Dev credentials: `me@example.com` / `devpassword`.

- The exercises list should populate with the seeded template exercises
  (proves DOWNLOAD).
- "Log a quick session" inserts a session + two sets locally; the connector
  uploads them to `/sync/upload` → Postgres (proves UPLOAD).

## Analyze / test

```sh
make -C app analyze
make -C app test
```
