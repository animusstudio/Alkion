# Retired source disposition

2026-10-20. **Implemented after coordinator checked and approved the exact disposition.**
Implements inventory T1 of the approved [source cleanup plan](../plans/2026-10-20-alkion-source-cleanup.md).
Retired source reference:
[`661a05bd26b5aaad14850dcfd5bcbd29e7e97730`](https://github.com/animusstudio/Alkion/tree/661a05bd26b5aaad14850dcfd5bcbd29e7e97730).
Every removal path and retained file digest is recorded in the
[exact manifest](../history/reps-backend/disposition.json); the retiring paths
are unchanged between that reference and this cleanup's starting tree.

## Runtime and delivery removal

| Paths | Actual callers and disposition |
| --- | --- |
| `server/` (97 files) | Go entrypoints, embedded SQL migrations, auth/sync/upload/migration handlers, tests and Dockerfile form the old service. No current app, Python capture checker, Android harness or app CI imports/builds it. Remove the whole runtime/module/test tree; retain the schema/protocol evidence below. |
| `powersync/` (3 files) | Service config is mounted only by the retiring compose stack; sync rules describe the old replication layout. Remove service/configuration; retain sync rules as historical text. |
| `infra/` (6 files) | Compose, environment example and runbooks operate only the old PostgreSQL/Go/PowerSync stack. Remove all paths; current app builds require none of them. |
| `api/` (2 files) | Legacy OpenAPI auth/probe contract and future codegen notes. Only the old server Makefile lints it; no generated/current app client consumes it. Remove; exact old contract remains in Git history. |
| `.github/workflows/build.yml` | Builds `./server` and publishes the old GHCR image. Remove. |
| `.github/workflows/{android-preview,android-release}.yml` | Legacy Reps signed APK/version/tag/OTA publication, using release secrets and a nonflavored release recipe. Current Android Gradle configuration explicitly refuses release tasks; no app CI caller needs them. Remove both, without a replacement release route. |
| `.claude/skills/release/SKILL.md`, `app/android/RELEASE.md` | Instructions invoke the retired release workflows and legacy signing identity; no current app caller. Remove; provenance remains at the source reference. |
| `web/README.md` | Sole placeholder file for an unimplemented Next.js client; no sources, dependencies, build, workflow or current Alkion caller. Historical plans describe an earlier intent, not a current app role. Remove. |

## Evidence retained before deletion

[Historical evidence](../history/reps-backend/README.md) retains 30 byte-identical
files with original paths and SHA-256: all 26 legacy SQL migrations as `.sql.txt`,
PowerSync bucket rules as `.yaml.txt`, the writer-fence notes as `.md.txt`, and
migration-peer schema/wire JSON fixtures. No executable Go, service config,
launcher, Makefile or deployment recipe is retained there.

The peer integration test and protocol implementation are linked to the immutable
source reference. In particular migrations 00023–00026, the synthetic wire
fixture and `cross_repository_test.go` remain reviewable without a runnable old
service. The schema fixture's hash embedded in `wire-v1.json` is preserved.

Keep `docs/reps-capture-{qualification,installation}.md` as dated evidence, with a
current historical notice rather than rewriting recorded results. Keep existing
app transfer/recovery fixtures, import contracts, package/license/font notices,
source manifests and dated design/qualification plans.

## Current app and tooling retained

- Normal `app/lib/main.dart` imports standalone profile/local-store/recovery
  modules, not the removed `lib/sync`, auth or capture producer modules. Current
  app code/tests/tooling have no path dependency on the retiring Go/SQL/API tree.
- `scripts/check-capture-installation.py` and `tests/test_capture_installation.py`
  validate explicit synthetic receipt facts independently of the retired stack.
- `scripts/verify-capture-rehearsal.py` builds the rehearsal from an explicitly
  supplied external read-only Hub snapshot (`connectors/reps/cmd/reps-migration-rehearsal`),
  refuses a working tree, and validates retained captures. It never builds the
  old `server/`; keep its validation unchanged. Its older producer instructions
  are historical because current Make capture-production routes already refuse.
- Keep `.github/workflows/app-ci.yml`, pinned FVM, normal debug/Linux builds,
  SQLite store, import/recovery/backup/transfer contracts and current capture
  evidence/checkers. The later owner amendment retires the bespoke Android
  campaigns; see [current scope](android-smoke.md). No new integration is added.
- Keep dependencies by actual callers: `sqlite_async`/`sqlite3` back the local
  store; `crypto` hashes store/backup/transfer evidence; `uuid` supplies revision,
  profile, restore and deterministic IDs. No dependency or lockfile purge.

## Dead visual recipe and its exact callers

`app/Makefile`'s `android-synthetic-ui-apk` is stale: its target
`integration_test/android_ui_visual_test.dart` is absent. Its only executable
caller is the fake-FVM recipe-argument block in `app/tool/android_synthetic.sh`'s
lifecycle self-test; that block never opens the missing Dart file. Remove the
recipe, its PHONY/export references and that obsolete self-test block together.
The dated 2026-10-17 owner-readiness plan is history and remains unchanged.
At the T3 checkpoint `5f90857687b3996f863a15f4a8dc86b703c818fc`, native observer
routes remained. The subsequent owner-approved T5 amendment retires all bespoke
campaign routes together; their exact source remains at that immutable ref.

Current README/agent/development guidance and stale active-code comments were
updated in T3. Historical documentation remains under its original dates;
references to removed source resolve through this disposition and immutable Git
history. No owner data, keys, device state or live service is involved.
