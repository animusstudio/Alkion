# Working on Alkion

Alkion, by Animus, is a pre-1.0, account-free workout app. The active runtime is
Flutter over a standalone profile-scoped SQLite store. Android is the product
target; Linux supports development and synthetic qualification. Read
[development](docs/alkion/development.md), [acceptance](docs/alkion/acceptance.md)
and the relevant approved plan before changing behavior; app rules are in
[app/AGENTS.md](app/AGENTS.md). `CLAUDE.md` files delegate to these instructions.

## Boundaries

- Default local startup remains account-free and offline. The explicitly
  configured [Animus connection](docs/alkion/animus-connection.md) permits
  foreground browser authentication and a confirmed read-access check only.
  No sender, replica download or OTA transport is enabled; do not introduce one
  as cleanup. Final release identity/signing remain open.
- Use explicit disposable storage and synthetic fixtures for qualification.
  Never discover/read owner profiles, keys, credentials, queues or real exports.
- Preserve originals, corrections, derived results and provenance separately.
  Essential local actions commit data and immutable outbox atomically. Replicas
  are not backups; recovery must retain uncertain intent and existing bytes.
- Legacy Reps v0.18.1 is frozen. The old Go/PowerSync/compose/API and legacy
  publishing routes are retired; [disposition](docs/alkion/legacy-retirement.md)
  and [non-runtime evidence](docs/history/reps-backend/README.md) record exact
  source references. Do not recreate those services in the app.
- No live migration, READY/cutover, service shutdown, deployment, signing, tag,
  release or publication without explicit owner direction. Keep private
  coordination paths, owner data and credentials out of this public tree.
- Preserve LICENSE, bundled font notices, source manifests and dated evidence.
  Historical plans describe their recorded trees, not current setup commands.

## Layout

- `app/`: local application, store, recovery/transfer and focused local proof tools.
- `docs/alkion/`: current contracts, architecture and scoped acceptance.
- `docs/history/`, `docs/superpowers/`: retired evidence and dated design records.
- `scripts/`, `tests/`: capture installation/rehearsal evidence checkers.

## Commands

Run from the repository root with explicit paths. Every local Flutter/Dart
command goes through `make -C app` and FVM 3.44.0:

```sh
make -C app get
make -C app analyze
make -C app test TEST=--concurrency=2
make -C app format
make -C app build
make -C app build-apk
python3 -m unittest discover -s tests -p test_capture_installation.py
```

`get` resolves offline with the committed lock. A fresh machine may explicitly
use `get-online` once for connected dependency bootstrap with the same lock
enforced. `format` checks only;
`fmt FORMAT_FILES=...` writes explicitly owned paths. Debug APK builds require
an explicit disposable Android user directory; never read inherited signing
configuration. The sole release-mode exception is the opt-in private dev APK
test route documented in `app/README.md`, using that disposable debug certificate.
Other release tasks and implicit run/device/scaffold/clean routes fail closed.
No backend is required for local use or ordinary tests; the opt-in live Animus
check needs a separate disposable synthetic provider/API fixture. `app-ci.yml`
keeps app analysis and tests; no
legacy signing/image publication workflow remains.

## Workflow

Use an approved lane-sized plan and focused checks, then independent review.
Assigned implementers do not re-delegate. Stage files by name, preserve unrelated
work, and use subject-only Conventional Commits. No amend, force push or history
rewrite without authorization. One branch/PR per plan, merge commit on green
checks; never push directly to main. Public pushes require exact outgoing-range
review and owner approval. The coordinator owns delivery.

For a device check, use the short [manual APK checklist](docs/alkion/android-smoke.md)
with an explicitly selected disposable profile/device. The bespoke campaign
framework is retired; ordinary unit/widget, real SQLite and native-boundary tests
remain the automated checks. Never infer device qualification from host PASS.
