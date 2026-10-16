# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Current state:** `main` is pre-1.0 development of Alkion, the successor app (see `docs/alkion/`). v0.18.1 is the final legacy Reps release. Before Alkion 1.0, create no `v*` tag or GitHub release and do not use the `release` skill; the Releases section below describes the legacy process.

## What this is

"Reps" (`io.github.psychonaut0.reps`) — a personal, local-first gym-logging app. Flutter client (Android phone + Linux desktop for dev) over a PowerSync-synced SQLite, with an optional self-hosted Go backend + Postgres for multi-device sync. Works fully offline with no account; sync is opt-in. The root README.md is the original capture document (training split, seed data) — it predates the build and its "status" line is stale; this file and the per-directory CLAUDE.md files are the operative truth.

## Layout

- `app/` — Flutter client (see `app/CLAUDE.md`)
- `server/` — Go API: auth, PowerSync token, `/sync/upload` write path (see `server/CLAUDE.md`)
- `infra/` — local dev compose stack: Postgres, server, PowerSync service (see `infra/CLAUDE.md`)
- `powersync/` — PowerSync service config + `sync-rules.yaml` (bucket definitions)
- `api/` — OpenAPI 3.1 spec for the Go API (`make -C server lint-spec`)
- `docs/superpowers/specs/` + `docs/superpowers/plans/` — design specs and implementation plans, one pair per increment; `docs/design_handoff_workout_tracker/` — the authoritative visual/interaction spec (README + `.jsx` prototypes)
- `web/` — placeholder, not built

## Commands

Everything runs from the **repo root** with explicit paths — never `cd` (committed docs/runbooks follow the same rule).

- App: `make -C app analyze` · `make -C app test` (single file: `make -C app test TEST=test/widgets/foo_test.dart`) · `make -C app build` (Linux) · `make -C app build-apk-release` (signed APK; needs gitignored `app/android/key.properties`)
- Server: `make -C server test` (needs the dev Postgres up; injects `TEST_DATABASE_URL`) · `make -C server build` · `make -C server run`
- Dev stack: `docker compose -f infra/compose.yml -f infra/compose.dev.yml --env-file infra/.env up -d` — **always both files**; base-only drops the host ports (8080 server, 8090 powersync, **5433** postgres — not 5432, that's taken by another project)

## Releases

- Tag `v*` on main → `.github/workflows/android-release.yml` builds and publishes the signed `reps-vX.Y.Z.apk` to GitHub Releases (signing via repo secrets; release runbook in `app/android/RELEASE.md`, automated end-to-end by the project `release` skill). **Before tagging `vX.Y.Z`, bump `app/pubspec.yaml` `version:` to `X.Y.Z+N`** — the in-app OTA updater reads the running version from there, and the release workflow hard-fails if the pubspec version (sans `+build`) doesn't match the tag.
- Push to main → `.github/workflows/build.yml` publishes the server image to GHCR (`ghcr.io/psychonaut0/workout-tracker-server`, public). Production runs on the homelab (`ct-workout` LXC); deployment lives in the separate infra repo (`personal/infra/stacks/ct-workout/`).

## Cross-cutting architecture facts

- **Local-first**: the app always opens its local PowerSync SQLite; identity is a locally generated user id (`IdentityService`). Login/registration only attaches sync. The server is source of truth only when syncing.
- **Ownership model ("nothing is locked")**: server-seeded template rows (`is_template=1`, `created_by NULL`) are read-only server-side and are NEVER shown in the UI. A boot migration (`app/lib/data/template_absorb.dart`) copies them into user-owned rows with deterministic `uuid.v5(ns, '$userId:$templateId')` ids and re-points references. Every visible exercise/day is editable and deletable.
- **Sync contract** (details in `server/CLAUDE.md`): client uploads `{op,table,id,data}` batches to `POST /sync/upload`; server stamps `user_id`/`created_by`, computes `is_top_set`/`is_pr`, never returns 4xx for bad data (per-op SAVEPOINT + skip). PATCH handlers apply an explicit column allowlist — a client `UPDATE` touching a column the handler ignores is silently dropped upstream (re-point that kind of change via DELETE+INSERT instead).
- **Workflow convention**: each increment goes brainstorm → spec (`docs/superpowers/specs/`) → plan (`docs/superpowers/plans/`) → implementation (subagent-driven with TDD) → adversarial review → merge `--no-ff` → tag. Commit style: Conventional Commits, standard types, subject line only, no body. Plan/spec documents are committed; never reference plan numbers inside code — use descriptive language.
- Treat the repo as public: secrets stay in gitignored files (`server/.secrets/`, `app/android/key.properties`, `infra/.env`) and GitHub Actions secrets.
