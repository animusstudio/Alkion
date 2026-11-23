# App cleanup roadmap

2026-11-23 · Coordination record · **Proposed**.

The owner is Alkion's only user and will start a fresh profile, so the app drops all
legacy, pre-catalog support. These plans also redesign Progress around catalog muscle
and family data, rewrite user-facing text in plain language, make the catalog public,
and extend Animus send to catalog workouts. Each line below is a separate plan with its
own branch and PR. This page records only the order and which files each plan owns.

## Owner decisions (2026-11-23)

- **Fresh profile.** No legacy data is converted or kept readable. Before installing the
  build that contains the store cleanup, the owner backs up the current profile and
  starts a new one. Their history returns later through the separate one-shot migration,
  which writes catalog-native data.
- **Public catalog.** The catalog should become public and open source. Until its rights
  review passes, a build without the catalog says plainly that the catalog is not
  included. No legacy fallback remains in such a build.
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

A plan edits only the files it owns. Anything else is a request to the owning plan.

- **Legacy UI removal:**
  - the old exercise sheet and every caller outside Progress;
  - the no-catalog fallbacks in the day editor, the session exercise picker, the
    Exercises tab, the exercise editor and the Plan screen;
  - the legacy choice in the catalog picker;
  - the history-mapping label and the legacy display fallback in the History set editor;
  - `history_mapping/`, `transfer/`, the recovery `tool/` scripts and the compatibility
    export, including `ui/export_failure.dart`;
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
  - fresh-profile handling: one new refusal screen file under `ui/alkion_recovery/`
    plus its routing line, merged after the backup and recovery wording plan.
- **Progress redesign:**
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
  - `session/` live workout, summary and notifications;
  - `catalog_ui/`;
  - `widgets/prescription_controls.dart` and `widgets/rir_picker.dart`.
- **Plain language, Today, Profile and History:**
  - Today, the session launcher and `ui/training_preferences_sheet.dart`;
  - Profile, including the build label in the footer and the document export messages;
  - first start (`ui/alkion_recovery/first_start_screen.dart`);
  - History screens and editors;
  - Bodyweight text other than Progress placement.
- **Catalog workout send:** `animus/`, the three `ui/animus_*.dart` panels (including
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
    removal or Progress redesign. Progress replaces its own call sites.
  - Progress stops calling the legacy Progress series and the legacy last-trained
    lookup; the store plan deletes them.
  - Progress formats e1RM locally. `data/models.dart` changes belong to the store plan.
  - `ui/bodyweight_view.dart` is shared: Progress (placement) merges before the Today,
    Profile and History plan (text).
- **One-line overlaps.** Legacy UI removal removes one compatibility line each in
  `ui/profile_screen.dart` and `ui/set_editor_sheet.dart`. It merges before the Today,
  Profile and History plan.
- **Translation keys.** A key is deleted by the plan that removes its last use.
- **Integration.** Plans merge into `main` one at a time. A plan that merges later
  rebases onto `main` (by merge, not history rewrite) and reruns its focused checks.
