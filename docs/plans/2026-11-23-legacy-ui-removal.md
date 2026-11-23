# Remove the legacy exercise model from the app

2026-11-23 · Standard lane · **Approved**. Approved by the owner on 2026-11-23 ("I confirm every decision"), with every recommended default.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 1). Baseline: `104232d`.
Follows [the 2026-11-08 legacy removal](2026-11-08-legacy-removal.md), which deferred the items here.
`lib/`, `test/` and `tool/` paths are relative to `app/`.

## Outcome and why

The owner starts a fresh profile and the catalog becomes the only exercise model. The app still
carries the pre-catalog model: an exercise without an execution definition, the 8-group exercise
sheet, chip-based muscle editing, history-mapping labels, Reps-era transfer tooling, a compatibility
export and a fallback for builds without the catalog. This plan removes all of it from the code and
screens. It changes no stored schema or SQL; that is the
[legacy store removal](2026-11-23-legacy-store-removal.md).

## Decisions

- **No catalog, no exercises.** A build without the catalog shows one plain "exercise catalog not
  included in this build" state wherever an exercise would be added or chosen. Nothing can add an
  exercise there. The public catalog arrives under its own plan. Until that bundle lands, only
  the Dev identity build loads the catalog (the gate in `lib/catalog/catalog_development.dart`),
  so every other build shows this state and cannot add exercises. The Profile footer shows
  "Alkion v{version}" in every build; the build type appears only under About/Details.
- **Custom exercises stay.** Creating a custom exercise through the catalog picker is the only
  create path. It needs the catalog's measurement profiles, so it is part of the same state.
- **History "add exercise" uses the catalog picker.** Stored catalog and custom exercises appear
  there as owned choices; there is no flat list of all stored exercises.
- **The 8 muscle keys stay** where they are catalog browse groups or stored target keys. Only the
  legacy framing goes: exercise-level `muscle_group` attribution, coarse volume attribution, the
  legacy body-figure tab, the Targets and Today labels that depend on it.
- **Exports.** Only the history export stays. `lib/export/alkion_exports.dart` uses
  `transfer/full_v1.dart` (`fullV1Tables`) and `transfer/json_span_reader.dart` (`readJsonSpans`)
  only inside the compatibility exporter (`buildCompatTransferExport`, `_lexemeOrString`), so
  nothing moves into `export/`; both imports go with that code. `domainBytes` and
  `buildDomainExport` have no user-facing caller (Profile uses only `exportHistory`; the only
  users are tests), so they are deleted with their tests. `exact_json.dart` stays.
- **Old exercise sheet.** `lib/ui/exercise_sheet.dart` and its test are deleted as this plan's last
  step only if the Progress plan has already removed its call sites; otherwise the Progress
  plan's final task deletes them.
- **Kept on purpose.** Notification-receipt "legacy" handling, and the Animus development-HTTP
  flag, which is not Reps legacy.
- **Code stops reading legacy store paths.** Repositories and models keep their columns and SQL
  until the store plan; this plan only removes UI and logic that consume them.
- **Host recovery tools go.** `lib/history_mapping/`, `lib/transfer/`, the three Reps-era `tool/`
  scripts (`alkion_history_recovery.dart`, `alkion_transfer_recovery.dart`,
  `alkion_backup_recovery.dart`, which imports `transfer/transfer_service.dart`) and their Make
  targets (`alkion-history-recovery`, `alkion-import-history`, `alkion-transfer-recovery`,
  `alkion-backup-recovery`) are removed. `alkion_store_recovery.dart` and
  `alkion_verify_backup.dart` do not import `transfer/` and stay. The 2026-11-08 plan kept them as a base for the owner's
  history migration; that plan will write catalog-native data and starts from git history instead.

## Non-goals

Schema, SQL, backup format and fresh-profile handling (store plan); the Progress picker and
Progress muscle use (Progress plan); `animus/` and the three Animus panels (catalog send plan);
wording rewrites (plain-language plans); the catalog asset and build flag (public catalog plan).

## Acceptance

- **A1.** In a build without the catalog, the day editor, the live session picker, the Exercises
  tab, the Plan screen and History "add exercise" each show the plain not-included state. None can
  create or add an exercise, and none crashes.
- **A2.** In a build with the catalog, the same entry points open the catalog picker. A custom
  exercise created there still saves, appears in the library, slots and sessions, and logs sets.
- **A3.** History "add exercise" lists catalog choices through the picker. Nothing groups
  exercises under the 8 legacy groups, and no "Legacy exercise" choice or label appears.
- **A4.** The exercise editor has no muscle chips, base-weight or plate-step start model. Editing
  a catalog or custom exercise shows only its catalog fields.
- **A5.** No screen shows the history-mapping label, the "legacy display fallback" or any
  Reps-compatibility text. Stored numbers display as before.
- **A6.** Targets, Today labels, weekly volume and the body figure use catalog target groups only.
  The body figure has no legacy tab. The 8 muscle keys still browse the catalog and still key
  saved targets, so existing targets keep working.
- **A7.** Profile offers no compatibility export. History export still works.
- **A8.** No lib or tool code imports `history_mapping/` or `transfer/`. The matching Make targets, tool
  scripts (including `alkion_backup_recovery.dart`), tests and docs are gone, and no dead `Object legacy` constructor remains.
- **A9.** Notification receipts still accept older receipts; the Animus dev-HTTP flag is unchanged.
- **A10.** `make -C app analyze` is clean, no ARB key is unused, all four locales keep one key
  set, and the full suite passes except named inherited failures.

## Tasks

Implementers run on the Claude column of the routing table, reviewers on Sonnet `high`. Each task
migrates the test fixtures of the tests it touches (T0). Order: **T0, then T1 ‖ T3, then T2.**
T1 and T3 own disjoint files and run in parallel on separate worktrees. T2 deletes packages that
T1 stops using, so it runs after T1.

| Task | Work class | Owns | Acceptance |
| --- | --- | --- | --- |
| **T0 Synthetic catalog fixtures.** Add one shared test helper that builds a small synthetic catalog bundle and seeds catalog-bound and custom exercises through the real catalog repository; extend `memory_catalog_state.dart` rather than add a parallel path. Migrate the first fixtures. | Standard code, Opus `high` | `test/support/` (new helper, `screen_harness.dart` `seedExercise`, `memory_catalog_state.dart`) | A2 |
| **T1 Pickers and fallbacks.** Remove the old exercise sheet's callers outside Progress; replace the no-catalog branches in the day editor, session picker, Exercises tab, editor and Plan with the not-included state; make History add-exercise open the catalog picker; drop the legacy choice, `choiceForOwned` legacy path and `HistoryMappingScope.selectable` filters in the picker and library. | Standard code, Opus `high` | `lib/ui/day_editor.dart`, `lib/session/exercise_picker_sheet.dart`, `lib/ui/exercise_library_tab.dart`, `exercise_editor.dart`, `plan_screen.dart`, `history_screen.dart` (add-exercise), `lib/catalog_ui/catalog_picker.dart`, `catalog_runtime_state.dart`, slot files for non-catalog branches (`slot_summary`, `slot_modes`, `day_slot_card`, `day_view`, `lib/session/exercise_block.dart`), their tests, their ARB keys | A1-A4 |
| **T3 Muscle framing.** Drop legacy attribution from volume, workload, live weekly volume, Targets, Today labels and the body-figure legacy tab; reduce `muscles.dart` to catalog browse groups and target keys. | Standard code, Opus `high` | `lib/data/muscles.dart`, `volume_attribution.dart`, `body_workload*.dart`, `planned_workload.dart`, `lib/session/live_weekly_volume.dart`, `lib/ui/targets_tab.dart`, `today_labels.dart`, `body_figure.dart` (legacy tab only), their tests. `stats_repository.dart` is the store plan's: this task stops passing `muscleGroup` into the pure functions and leaves the SQL | A6 |
| **T2 Transfer, mapping and export removal.** Delete `lib/history_mapping/`, `lib/transfer/`, the three `tool/` scripts above, the compatibility exporter with `ExportService.transferBytes`, `domainBytes`/`buildDomainExport` and their tests (including the domain-export and compatibility phases of `test/alkion/acceptance/integrated_flows_test.dart`), the compatibility-export part of `ui/export_failure.dart` and the Profile message (the rest of that file and the `alkionDocument*` messages stay with the Today, Profile and History plan), the history-mapping label and legacy display fallback in `set_editor_sheet.dart`, the four `Object legacy` constructors, dead ARB keys; clean `main.dart` mapping hooks; update docs. **Last step:** delete `lib/ui/exercise_sheet.dart` and its test if Progress has already removed its call sites (see Decisions). | Standard code, Opus `high` | `lib/history_mapping/`, `lib/transfer/`, `tool/` scripts above, `Makefile` targets, `lib/export/`, `lib/ui/export_failure.dart` (compat part), `lib/ui/set_editor_sheet.dart`, the one compat line in `lib/ui/profile_screen.dart`, `lib/main.dart` mapping hooks, the four repositories' dead constructors, `lib/ui/exercise_sheet.dart` (conditional), `docs/alkion/{transfer,exports,reps-import,legacy-retirement,acceptance,development}.md`, `app/README.md`, `app/AGENTS.md` | A5, A7-A10 |

## Test-fixture migration (T0 and each task)

About 70 test files build `Exercise(muscleGroup:)` or `seedExercise(muscle:)` fixtures. Move them
by purpose, not mechanically:

- Tests of logic that only needs "an exercise" (sessions, sets, history, plan): use the T0 helper's
  synthetic catalog exercise.
- Tests whose subject is the legacy path (`exercise_sheet_test`, `exercise_editor_muscle_test`,
  `history_mapping_label_test`, compat export tests, `test/history_mapping/`): delete them with
  the code.
- Tests of muscle math: build catalog target groups, not `muscleGroup`.
- The `muscleGroup` field stays on `Exercise` and the drafts until the store plan removes it, so
  fixtures may still pass it during this plan. They must not depend on it for behavior.

## Checks

- Focused, per task: `make -C app test TEST='--concurrency=2 test/<area>'` for the areas the task
  touches, and `make -C app analyze`.
- Integrated, after T2: `make -C app format`, the full `make -C app test` (named inherited
  failures only), and a build without the catalog launched once to see the not-included state.
- Public build check: the public Android build still ships no private catalog.

## Docs

`docs/alkion/` stops describing in-app mapping, Reps transfer and the compatibility export;
`development.md`, `acceptance.md` and `app/AGENTS.md` match the code. Dated history stays.

## Open owner decisions (recommended default)

Delete the host recovery tools, relying on git history for the migration plan (recommended), or
keep `alkion_history_recovery.dart` until that plan starts.

## Task state

Approved; nothing started. Next: T0.
