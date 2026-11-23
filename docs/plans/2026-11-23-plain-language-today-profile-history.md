# Plain language: Today, Profile and History

2026-11-23 · Standard lane · **Approved**. Approved by the owner on 2026-11-23 ("I confirm every decision"), with every recommended default.
Parent: [app cleanup roadmap](2026-11-23-app-cleanup-roadmap.md) (wave 2).
Writing guide, terminology table and owner decisions R1-R4:
[backup and recovery](2026-11-23-plain-language-backup-recovery.md#writing-guide-shared-by-all-three-plans).
Waits for: [legacy UI removal](2026-11-23-legacy-ui-removal.md) (Today labels and the
History set editor's legacy display are removed there). Baseline: public `main` at `104232d`. `lib/`, `test/` and `tool/` paths are relative to `app/`.

## Outcome and observed problems

- **Profile footer.** `profile_screen.dart` renders `'Alkion Dev'` /
  `'Alkion Dev · v$_version'`, hardcoded and untranslated.
- **Today.** `alkionDateUnavailable` ("Date unavailable · {raw}") shows a raw string;
  `alkionDateWindowUnavailable` ("no qualified day; time-window totals"),
  `trainingRepStartUnavailable` ("rep prescription ... unavailable"),
  `trainingRirPolicyUnavailable` ("RIR policy ... unsupported"),
  `splitNextInRotation`, and three strings for an empty workout (`splitNoTemplate`,
  `splitBuildAsYouGo`, `splitAddExercisesLive`).
- **Session launcher.** `alkionFreshLimit*` and `alkionOrderChoiceTitle/Body` ("Choose a
  baseline ... records a preference, not a historical fact").
- **History.** Three discard dialogs (`historyDiscardSetsTitle`, `historyDiscardOwedMessage`,
  `historyDiscardUnsaved*`) with "owed" and "stored" semantics; `historyResumeFailed`
  prints a raw `{error}`; `historyNotSavedWillRetry`; `historyNoSetupToLog` ("setup");
  abbreviations (`historySummarySuffix` "4wk", `historyExerciseCountShort` "ex").
- **First start / Profile.** `alkionEntryUnavailable` ("isn't set up in this build"),
  `alkionOfflineTitle` ("Start training offline"), `exportHistorySub` ("JSON"),
  `trainingPreferencesHint` (three claims in one line).
- **Bodyweight text.** `alkionBodyweightDateCoverage` ("current and time-window values
  unavailable; numeric history retained"), duplicate "Daily log" / "History" headings.

## Decisions and non-goals

- **Wording, layout and grouping only.** No data, saving or retry behavior changes.
- **Profile footer:** "Alkion v{version}", localized through a key, in every build; no "Dev"
  or "debug" there. The build type appears only under the About/Details area.
- **First start:** primary action "Get started"/"Use without an account"; when sign-in is
  not configured the sign-in button is hidden instead of explained. Restore wording
  in this screen's `alkionFirstReselect*` keys belongs to the backup plan (values only).
- **One discard dialog pattern in History editors:** "Discard unsaved changes?" with Keep
  editing / Discard; the three variants share it, with a count when useful.
- **No raw error text:** failures use the shared message mapping of the backup plan
  (`util/error_message.dart`); this plan only calls it and never edits it.
- **Set counts:** "N sets" via plural forms; "{n} exercises", "last 4 weeks" instead
  of abbreviations; weekly-total captions "Based on N of M sets".
- **Undated and unavailable values:** show "No date" and "-"; no raw strings.
- **Empty workout:** one card on Today, "Empty workout - add exercises as you go".
- **Today unavailable states:** one "Couldn't load" line per tile; start-blocked days say
  "{name} is turned off. Turn it on in Plan." or "Check the reps for {name} in Plan."
- **Non-goals:** the session launcher's behavior and limits (wording only), Progress,
  Animus panels, backup screens, the
  Today labels and legacy display removal (legacy UI removal plan).

## Acceptance

- A1. The Profile footer shows "Alkion v" plus the version in every language and never
  the word "Dev" or "debug".
- A2. First start has one obvious primary action; with sign-in unconfigured, no
  "not set up in this build" text appears.
- A3. Today shows no raw date string, "qualified day", "prescription", "policy" or
  "rotation"; an empty workout is one card.
- A4. All History editors use one discard dialog pattern; no dialog mentions "owed",
  "stored" or "pending retry".
- A5. Any History or Today failure shows a plain sentence and an action, never exception
  text, in a forced-failure test for resume, delete and save.
- A6. Set and exercise counts read as full words with correct plurals in en, it, de, es.
- A7. Bodyweight shows one heading for entries and a single plain note when some entries
  have no date.
- A8. Behavior is unchanged: existing Today, History, Profile and launcher tests pass with
  only string expectations edited.

## Tasks

- **T1 Today, session launcher, first start** (standard code: Opus `high`). Owns
  `lib/ui/today_screen.dart`, `today_stat_tiles.dart`, `workload_top_muscles.dart`,
  `lib/ui/alkion_recovery/first_start_screen.dart`, `lib/shell/session_launcher.dart`,
  `session_indicator.dart`, `w_tab_bar.dart` (wording only), and wording only in
  `lib/ui/character_body*.dart` and `body_figure.dart` (the legacy tab is removed by the legacy plan), with tests. Checks:
  `make -C app analyze`; focused Today and first-start widget tests in `en` and `it`.
- **T2 Profile** (standard code: Sonnet `high`). Owns `lib/ui/profile_screen.dart`
  (footer, row helper texts, export row wording; not the Animus panel, owned by the send
  plan), and the remaining `lib/ui/export_failure.dart` with the `alkionDocument*` messages
  ("Delivery only", "private staging"); the legacy plan deletes only its compatibility part.
  `training_preferences_sheet.dart` belongs to the workout-flow plan.
  Checks: analyze; focused profile test in `en` and `it` pinning the footer.
- **T3 History screens and editors** (standard code: Opus `high`). Owns
  `lib/ui/history_screen.dart`, `set_editor_sheet.dart`, `catalog_history_editor.dart`
  (except legacy items removed by the legacy plan), with tests. One discard dialog helper.
  Checks: analyze; focused History and editor widget tests in `en` and `it`, including a
  discard flow and a forced failure.
- **T4 Bodyweight text** (docs/mechanical: Sonnet `medium`). Owns text and heading in
  `lib/ui/bodyweight_view.dart` and `add_weight_sheet.dart`, excluding Progress's
  Bodyweight placement. Focused bodyweight test in `en` and `it`.
- **T5 Copy** (docs/mechanical: Sonnet `medium`; first, to freeze keys). Owns values of
  the keys of these screens and new keys under `plainToday*`, `plainHistory*`; deletes
  only keys it makes unused; regenerates with `make -C app get`.
- **T6 Integration** (coordinator). Merge by rebase-by-merge on `main`; full
  `make -C app test`, `make -C app analyze`.

Parallelism: T5 first; T1-T4 then run in parallel (disjoint files); T6 last. Starts only
after the legacy UI removal plan merges.

## Owner gates

- Owner approves R1-R4 (defined in the backup plan) and the first-start wording.
- Owner reviews the Italian wording before merge; German and Spanish follow meaning.

## Follow-ups (not tasks)

- Moving the Bodyweight goal under Training preferences is a layout change worth doing.
- Hiding the session launcher's size limits entirely, if they are unreachable in practice.
- Replacing the entry/offline split with a single start button if sign-in stays optional.

## Status

Approved 2026-11-23. Next: waits for the legacy UI
removal plan.
