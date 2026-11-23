# Plain language: backup and recovery

2026-11-23 · Standard lane · **Proposed**.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 1).
Siblings: [workout flow](2026-11-23-plain-language-workout-flow.md), [Today, Profile and History](2026-11-23-plain-language-today-profile-history.md).
Baseline: public `main` at `104232d`. `lib/`, `test/` and `tool/` paths are relative to `app/`. Branch named at approval.

## Outcome and observed problems

Backup, restore and recovery speak in storage vocabulary: digests, manifests, staging.

- **Backup screen.** `alkionBackupExplain` is three sentences about what "counts" as
  verified. `alkionBackupCreate` ("Create backup") and `alkionBackupSaveCopy` ("Create
  backup and save copy") are two buttons for one task. The result lines show a SHA-256
  digest; the check result says "covered rows match the manifest; schema and integrity
  checks passed".
- **Restore.** `alkionRestoreConfirmMessage` says the current state is "kept and fenced"
  and that newer work is "listed for review". `alkionRestoreUnknownNewerWork` mentions
  "bytes". The screen carries six sections, most of them read-only evidence with no action.
- **Foreign profile.** `alkionBackupForeignProfile` tells the user to "Clear Alkion's
  storage in Android settings", which erases the app's data and recovery copies.
- **Failures.** `alkionStoreRecoveryTitle/Body` and `alkionKeptNoticeDraft` read as alarming
  internals; `util/error_message.dart` and some surfaces can still show raw exception text.

Goal: a simple front (Back up now, Restore, last backup date), everything technical behind one
collapsed **Details** section, and errors that say what happened and what to do.

## Decisions and non-goals

- **Wording, layout and grouping only.** No recovery, storage, restore-format or backup
  behavior changes. The check that a backup file is good still runs; only its report
  changes.
- **One primary action:** "Back up now" creates the backup, saves the copy and checks it.
  If the current flow cannot be one tap without behavior change, the two steps stay but
  sit under one button label and one result (decide at T2; otherwise a follow-up).
- **Restore in one short sentence:** replaces your data with the backup; the app closes
  and must be reopened. Previous data is still kept and mentioned only in Details.
- **Details (collapsed by default):** restore history, newer-work review, kept workout
  data, stored copies, digest and manifest facts, restore technical details. Safety
  evidence stays reachable; sections with no items do not render at all.
- **Front never shows:** digest, manifest, schema, staging, bytes, "fenced", raw exception
  text, file paths on Android (the Linux path field stays desktop-only).
- **Foreign-profile message** says the backup is from a different install, offers the
  safe path that exists today (restore from the start screen of a fresh install) and
  never suggests clearing Android storage. If no safe in-app path exists, say so and list
  "restore into a fresh install" as the only path; a new in-app path is a follow-up.
- **Error mapping:** each `AppError` kind maps to one calm sentence plus an action
  ("Try again", "Reopen and retry"). Raw `error.toString()` never reaches a widget.
- **Non-goals:** Animus panels (catalog send plan), first-start entry wording (Today plan),
  `ui/export_failure.dart` and the profile `alkionDocument*` messages (Today, Profile and
  History plan), store/backup format (legacy store removal plan), legacy-tagged strings (legacy UI
  removal plan).

## Writing guide (shared by all three plans)

- **Tone.** Plain, calm, second person, present tense. Say what happened, then what to do.
  No blame, no alarm words ("corrupt", "fenced", "evidence"), no humor.
- **Length.** Titles 1-4 words. Buttons 1-3 words, verb first ("Back up now"). Helper text
  one sentence, at most 80 characters in English (about 100 in Italian/German/Spanish);
  an error is at most two short sentences. A longer explanation goes behind Details.
- **Numbers.** Counts use plural ICU forms ("12 sets"); dates use the locale's short date;
  never show a raw date or id string; use the unit setting for weight; "-" means no data
  and needs no explanation.
- **Scope.** User-visible text only. Code doc comments, log lines and test names are out of
  scope; "developer-style" text means words a person reads on screen.
- **Forbidden on the front:** build, profile (for the user's data), local state, staging,
  digest, hash, manifest, schema, token, payload, synchronize, prescription, evidence.
- **States.** Show the result, not a state explanation; a failed save says "Couldn't save"
  plus one action.
- **No data** is "-", with no explanation. "Backup file" is "backup" in every language.

| Concept | EN | IT |
| --- | --- | --- |
| Make a backup | Back up now | Esegui backup |
| Restore | Restore | Ripristina |
| Plan day (one training day) | day | giorno |
| Day with its exercises, the saved structure | plan | piano |
| Equipment/variant of an exercise | equipment / variation | attrezzo / variante |
| Reps in reserve (see decision R1) | RIR (reps left) | RIR (ripetizioni in riserva) |
| Warm-up set | warm-up | riscaldamento |
| Working set | set | serie |
| Details (collapsed section) | Details | Dettagli |
| Try again | Try again | Riprova |

Banned synonyms: routine, template, split (for the whole plan), session (use "workout"),
setup, execution, rotation.

## Owner decisions (recommended default first)

- **R1 RIR naming.** Keep "RIR" with a one-line first-use explanation ("Reps you could
  still do after the set"), since the owner trains with it. Alternatives: "Reps left";
  "Effort". Decided here, applied in the workout-flow plan.
- **R2 Terminology.** The table above: "plan day" for a training day, never "routine";
  "variation" for an exercise variant, never "execution"; "workout" for a session.
- **R3 Helper-text length.** One sentence, at most 80 characters (English).
- **R4 Evidence sections.** Collapse rather than delete (matches the owner's depth rule).

## Acceptance

- A1. The backup screen's front shows one primary backup action, one restore action and
  the last backup date; everything else is behind a collapsed Details section.
- A2. After a backup, restore or check, no digest, manifest, schema, staging, byte or row
  word appears outside Details, in any of the four languages.
- A3. Restore confirmation and the restore-done message each state, in one short sentence,
  that the data is replaced and the app must be reopened.
- A4. Details still reaches restore history, kept workout data, newer work and stored
  copies; sections with nothing to show are absent.
- A5. The foreign-profile message never instructs clearing Android storage.
- A6. A failed write shows one generic message and one retry action in banner and dialog;
  the kept-data notice states that the data is safe without implementation detail.
- A7. Forcing each error kind through the mapping shows no raw exception text, type name
  or path; the launch-failure screen has one sentence and a collapsed technical section.
- A8. Backup, restore, recovery and storage behavior is unchanged: existing store, restore
  and recovery tests pass without edits to their logic.

## Tasks

- **T1 Error mapping and shared pieces** (standard code: Opus `high`). Owns
  `lib/util/error_message.dart`, `lib/util/error_surface.dart`, `lib/widgets/w_dialog.dart`,
  `lib/widgets/storage_recovery_banner.dart`, `lib/widgets/kept_data_notice.dart`,
  `lib/ui/launch_failure_app.dart`, their tests. Checks: `make -C app analyze`; focused
  tests for error surfaces, banner, dialog, launch failure in `en` and `it`.
- **T2 Backup and restore screens** (standard code: Opus `high`; after T1). Owns
  `lib/ui/alkion_recovery/recovery_screen.dart`, `recovery_format.dart` and their tests
  (not `first_start_screen.dart`, owned by the Today plan). Single primary action,
  one-sentence restore, Details grouping, hide empty sections, foreign-profile text.
  Checks: analyze; focused recovery-screen widget tests in `en` and `it`, including a
  collapsed-by-default and an empty-section case.
- **T3 Copy** (docs/mechanical: Sonnet `medium`; parallel with T1 after keys are frozen
  in a short list at the start). Owns the values of the backup, restore, recovery,
  kept-notice, store-recovery, `error*` and launch-failure keys in the four ARB files,
  plus new keys under prefix `plainRecovery*`; deletes only keys it made unused. Then
  `make -C app get` and commit the regenerated output. Italian is drafted for owner review.
- **T4 Integration** (coordinator). Merge order T1, T3, T2; full `make -C app test` and
  `analyze`; screenshot check of the backup screen in `en` and `it`.

T1 and T3 run together; T2 follows T1. This plan merges first.

## Owner gates

- Owner approves this plan and R1-R4, reviews the Italian wording before merge (German and
  Spanish follow meaning), and confirms the one-button backup if T2 finds it needs a behavior change.

## Follow-ups (not tasks)

- A safe in-app path for a foreign-profile backup; hiding the Linux-only path field on Android.

## Status
Proposed (2026-11-23). Next: owner approval of R1-R4.
