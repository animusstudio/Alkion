# App cleanup roadmap

2026-11-23 · Coordination record · **Approved**. Approved by the owner on 2026-11-23 ("I confirm every decision"), with every recommended default.

The owner is Alkion's only user and will start a fresh profile, so the app drops all
legacy, pre-catalog support. These plans also redesign Progress around catalog muscle
and family data, rewrite user-facing text in plain language, make the catalog public,
and extend Animus send to catalog workouts. `lib/`, `test/` and `tool/` paths in all plans are relative to `app/`. Each line below is a separate plan with its
own branch and PR. This page records only the order and which files each plan owns.

## Owner decisions (2026-11-23)

- **Fresh profile.** No legacy data is converted or kept readable. Before installing the
  build that contains the store cleanup, the owner backs up the current profile and
  starts a new one. Their history returns later through the separate one-shot migration,
  which writes catalog-native data.
- **Public catalog.** The catalog should become public and open source. Until its rights
  review passes, a build without the catalog says plainly that the catalog is not
  included. No legacy fallback remains in such a build.
- **Catalog-required builds.** Until the public catalog bundle lands, only the Dev identity
  build loads the catalog (the gate in `lib/catalog/catalog_development.dart`), so every other
  build shows the not-included state and cannot add exercises. The Profile footer shows
  "Alkion v{version}" in every build; the build type appears only under About/Details.
- **Catalog Animus send.** Animus send moves to catalog workouts. Native-only send goes
  away together with the legacy exercise model.
- **Simplification depth.** A simple front, with technical detail behind a collapsed
  Details section. Safety evidence stays reachable and no recovery behavior changes.

## Plans and waves

| Wave | Plan | Lane | Waits for |
| --- | --- | --- | --- |
| 1 | [Legacy UI and code removal](2026-11-23-legacy-ui-removal.md) | Standard | — |
| 1 | [Progress redesign](2026-11-23-progress-redesign.md) | Standard | — |
| 1 | [Plain language: backup and recovery](2026-11-23-plain-language-backup-recovery.md) | Standard | — |
| 2 | [Legacy store removal](2026-11-23-legacy-store-removal.md) ([spec](../specs/2026-11-23-legacy-store-removal.md)) | Full | Legacy UI removal |
| 2 | [Plain language: workout flow](2026-11-23-plain-language-workout-flow.md) | Standard | Legacy UI removal |
| 2 | [Plain language: Today, Profile and History](2026-11-23-plain-language-today-profile-history.md) | Standard | Legacy UI removal |
| 3 | [Catalog workout send](2026-11-23-catalog-workout-send.md) | Full, cross-repository | Legacy store removal; current LAN follow-ups delivered |
| 3 | [Public catalog bundle](2026-11-23-public-catalog-bundle.md) | Standard | Rights review approved; legacy UI removal |

The catalog rights review and licence choice run first and in parallel, in the private
coordination repository. Only their outcome comes here.

## File ownership

A plan edits only the files it owns. Anything else is a request to the owning plan. Paths below omit the `lib/` prefix.

- **Legacy UI removal:**
  - the old exercise sheet's callers outside Progress, and `ui/exercise_sheet.dart` with its test
    as its last step if Progress has already removed its call sites (otherwise Progress's final
    task deletes it);
  - the no-catalog fallbacks in the day editor, the session exercise picker, the
    Exercises tab, the exercise editor and the Plan screen;
  - the legacy choice in the catalog picker;
  - the history-mapping label and the legacy display fallback in the History set editor;
  - `history_mapping/`, `transfer/`, the recovery `tool/` scripts (including
    `alkion_backup_recovery.dart`) and the compatibility export, including only the
    compatibility part of `ui/export_failure.dart`;
  - dead constructors;
  - the legacy muscle framing (`muscles.dart` framing, volume attribution, body workload
    legacy paths, live weekly volume, Targets, Today labels, the body figure legacy tab);
  - the matching `main.dart` hooks.
- **Legacy store removal:**
  - `store/` schema and migrations;
  - `session_writer.dart` compatibility writes;
  - `data/models.dart`, including `Exercise.muscleGroup`;
  - legacy SQL in `data/*_repository.dart`, including the legacy Progress series;
  - backup and restore format;
  - the other `Exercise.muscleGroup` users: `ui/editor_guard.dart`, `session/resume.dart`,
    `session/active_session_controller.dart` (draft JSON key), `character_body_preview.dart`
    and the `muscle_group` entry in `animus/workout_translation.dart` (a recorded one-line
    handoff from the send plan's ownership of `animus/`);
  - fresh-profile handling: one new refusal screen file under `ui/alkion_recovery/`
    plus its routing line, merged after the backup and recovery wording plan.
- **Progress redesign:**
  - the old exercise sheet's Progress call sites, and `ui/exercise_sheet.dart` with its test
    if Legacy UI removal merged first without deleting it;
  - `ui/progress_*.dart` and its new files;
  - new read-only `data/progress_*.dart` files;
  - `widgets/line_chart.dart` extensions;
  - the Progress entry in `shell/app_shell.dart`;
  - Bodyweight placement in `ui/bodyweight_view.dart`.

  It must not edit `stats_repository.dart` or `progress_repository.dart`.
- **Plain language, backup and recovery:**
  - `ui/alkion_recovery/`, except `first_start_screen.dart`;
  - `ui/launch_failure_app.dart`;
  - `widgets/w_dialog.dart`, `widgets/storage_recovery_banner.dart` and
    `widgets/kept_data_notice.dart`;
  - `util/error_message.dart` and `util/error_surface.dart`.
- **Plain language, workout flow:**
  - Plan, Split, day view and editors, slot cards;
  - the exercise editor;
  - `session/` live workout, summary and notifications, including
    `shell/notification_explainer.dart`;
  - `catalog_ui/`, including `catalog_ui/catalog_muscle_explorer.dart`;
  - `ui/training_preferences_sheet.dart`;
  - `widgets/prescription_controls.dart` and `widgets/rir_picker.dart`.
- **Plain language, Today, Profile and History:**
  - Today, `shell/session_launcher.dart`, `shell/session_indicator.dart` and
    `shell/w_tab_bar.dart`;
  - Profile, including the build label in the footer;
  - the remaining `ui/export_failure.dart` and the `alkionDocument*` messages (Legacy UI removal
    deletes only its compatibility part);
  - wording only in `ui/character_body*.dart` and `ui/body_figure.dart` (the legacy tab removal
    stays with Legacy UI removal);
  - first start (`ui/alkion_recovery/first_start_screen.dart`);
  - History screens and editors;
  - Bodyweight text other than Progress placement.
- **Catalog workout send:** `animus/` (the one `muscle_group` line in `workout_translation.dart` is removed earlier by the store plan), the three `ui/animus_*.dart` panels (including
  their wording) and `docs/alkion/animus-workout-upload.md`.
- **Public catalog bundle:** catalog asset staging, the build flag that gates the
  catalog, catalog loading in `main.dart`, licensing notices for catalog data.

## Shared files

- **Translation files.** The four ARB files are shared. Each plan changes only the
  values of keys its owned screens use, adds keys under its own prefix, and deletes only
  keys it owns. Generated `app_localizations*.dart` files are never merged by hand: on
  conflict, rerun `make -C app get` and commit the regenerated output.
- **Owner reviews.** Italian wording is owner-reviewed in each plain-language plan; German
  and Spanish follow English and Italian meaning.
- **Handoffs between plans.**
  - The old exercise sheet is deleted by whichever plan merges second: Legacy UI
    removal (as its last step, if Progress's call sites are gone) or Progress redesign
    (its final task). Progress replaces its own call sites.
  - Progress stops calling the legacy Progress series and the legacy last-trained
    lookup; the store plan deletes them.
  - Progress formats e1RM locally. `data/models.dart` changes belong to the store plan.
  - `ui/bodyweight_view.dart` is shared: Progress (placement) merges before the Today,
    Profile and History plan (text).
- **One-line overlaps.** Legacy UI removal removes one compatibility line each in
  `ui/profile_screen.dart` and `ui/set_editor_sheet.dart`. It merges before the Today,
  Profile and History plan.
- **Shared docs.** Docs edited by several plans (`docs/alkion/legacy-retirement.md`,
  `acceptance.md`, `development.md`, `app/AGENTS.md`) are rebased by the later-merging plan.
- **Translation keys.** A key is deleted by the plan that removes its last use.
- **Integration.** Plans merge into `main` one at a time. A plan that merges later
  rebases onto `main` (by merge, not history rewrite) and reruns its focused checks.

## Later

| Item | State |
| --- | --- |
| Muscle source alignment (Today, Targets): Progress uses muscle v2 profiles, Today and Targets use reviewed target groups | Not yet written; after the Progress redesign (see its D1) |
