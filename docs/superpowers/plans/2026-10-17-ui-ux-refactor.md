# Alkion UI/UX refactor plan

Date: 2026-10-17. Status: **approved refactor scope; independent planning review PASS**.

## Outcome

Refactor the existing Alkion mobile experience to improve clarity and align it with the shared Animus visual system before final owner-device qualification. The source audit is recorded in the [design brief](../specs/2026-10-17-ui-ux-refactor.md). The owner may optionally rank a UX friction; if no preference arrives, proceed with the approved app-wide scope and task order. If the image-versus-Flutter workflow question remains unanswered, use the current-session default without storing a preference.

## Decisions and non-goals

- Keep the current four-tab shell, profile overlay, in-tab Plan editors and focused live-workout model unless approved evidence requires a bounded change.
- Align the existing system to ink/bone, health coral, Hanken Grotesk and JetBrains Mono. The current display face is Space Grotesk; align it to Hanken. Preserve dark/light readability, exact workout values, unknown coverage, 48 dp live targets, text scaling, locales and reduced motion.
- The opening signup/login page and returning-session flow belong to the later Animus sync work. Keep local/offline use explicit; make no auth, transport or account attachment changes here.
- No new IA, features, dependencies, assets or release claims. The parallel owner-storage/recovery plan owns data-preservation operations; coordinate behavior and copy without editing that plan.
- Each surface task owns its localization strings in `app/lib/l10n/app_{en,de,es,it}.arb`; update all four together and regenerate localization output only through `make -C app gen-l10n`. Task owners add/update only keys for their surface. T8 owns the cross-locale parity check.
- Each surface task T1–T7 also owns updates to the exact focused test files listed in that task. When a focused test file covers multiple tasks, its edits are serialized: the earliest task needing a change owns and completes it, then hands it off; later tasks may update it only after that handoff. T8 owns its separately listed integrated acceptance and locale-parity tests.
- Shared main/profile/recovery files may overlap the parallel Android readiness work. Serialize edits to `app/lib/main.dart` (T2), `app/lib/ui/profile_screen.dart` (T6), and `app/lib/ui/alkion_recovery/{recovery_screen.dart,recovery_app.dart}` / `app/lib/ui/alkion_transfer/transfer_screen.dart` (T7) with that work; no simultaneous ownership. T7 owns presentation only, never storage, transfer, restore or domain behavior. Shared widgets have no blanket task ownership: the earliest task that needs a shared widget owns that file's change, and completes/hands it off before a later task edits it. Each widget is named in its surface task; no wildcard widget permission.
- Tests listed below are focused acceptance for the implementer; they have not been run as part of this docs-only planning task.

## Acceptance

See A1–A7 in the [design brief](../specs/2026-10-17-ui-ux-refactor.md). Implementation must preserve current functionality, accessibility and data truth, and must end with affected synthetic Android device checks on the selected candidate before owner qualification.

## Tasks

### T1 — Shared visual foundation

- **Behavior:** Align app-wide colors, type, surfaces, spacing, controls, icon treatment and motion with the shared visual system while maintaining dark/light theme behavior and existing user preferences. Keep health coral tied to workout content; do not apply it as a generic status color.
- **Owned files/callers:** `app/lib/theme/{tokens.dart,app_theme.dart,typography.dart,icons.dart,motion.dart}` only. No blanket widget-directory ownership; widget changes belong to the relevant surface task below. Localization changes are limited to shared theme/accessibility labels, if any.
- **Focused checks:** `make -C app test TEST=test/theme/tokens_test.dart`; `... TEST=test/theme/accent_text_test.dart`; `... TEST=test/theme/accent_usage_test.dart`; `... TEST=test/theme/theme_fonts_test.dart`; `... TEST=test/theme/font_family_source_test.dart`; `... TEST=test/widgets/tap_targets_test.dart`; `... TEST=test/theme/bottom_nav_inset_test.dart`.

### T2 — Onboarding, shell and Today

- **Behavior:** Clarify first-run empty/starter choice, account-free local path, tab/start affordances, active-workout return, Today's day rotation and empty/partial/error states. Do not add an auth entry screen in this implementation.
- **Owned files/callers:** `app/lib/main.dart`, `app/lib/ui/onboarding_screen.dart`, `app/lib/shell/{app_shell.dart,w_tab_bar.dart,session_indicator.dart,back_dispatch.dart,session_launcher.dart}`, `app/lib/ui/{today_screen.dart,today_labels.dart}`, and `app/lib/widgets/{card.dart,fit_label.dart,plan_form.dart,section_label.dart,split_card.dart,stat_tile.dart,volume_bars.dart,week_strip.dart}` only where needed by Today. Serialize `main.dart` with Android readiness work. Own onboarding/shell/Today strings in all four ARB files.
- **Focused checks:** `make -C app test TEST=test/alkion/workflows/account_free_screens_test.dart`; `... TEST=test/ui/onboarding_screen_test.dart`; `... TEST=test/layout/shell_layout_test.dart`; `... TEST=test/widgets/today_layout_test.dart`; `... TEST=test/ui/today_labels_test.dart`; `... TEST=test/shell/back_dispatch_test.dart`.

### T3 — Live workout and summary

- **Behavior:** Refine scan order and feedback around focused set entry, completed set rows, block actions, picker/reorder, rest, minimize/resume, finishing and summary. Preserve all existing controller semantics and timer/notification behavior; keep every live target at least 48 dp.
- **Owned files/callers:** `app/lib/session/{active_session_screen.dart,live_set_card.dart,set_line.dart,log_set_bar.dart,session_header.dart,exercise_block.dart,exercise_picker_sheet.dart,reorder_exercises_sheet.dart,session_summary_screen.dart}` and the named widgets `app/lib/widgets/{ruler_picker.dart,stepper.dart,number_entry_sheet.dart,w_action_sheet.dart}` only if live-workout interaction needs them. Own session/summary strings in all four ARB files.
- **Focused checks:** `make -C app test TEST=test/session/active_session_screen_test.dart`; `... TEST=test/session/live_set_card_test.dart`; `... TEST=test/session/log_set_bar_test.dart`; `... TEST=test/session/session_header_test.dart`; `... TEST=test/session/resume_test.dart`; `... TEST=test/session/finish_resume_test.dart`; `... TEST=test/widgets/tap_targets_test.dart`; `... TEST=test/layout/live_layout_test.dart`; `... TEST=test/layout/summary_layout_test.dart`.

### T4 — History, Progress and measurements

- **Behavior:** Clarify history grouping, session edit/resume and bodyweight/history entry; make chart units, exact values, partial coverage and unavailable evidence understandable without inventing zeros. Keep targets distinct from measured data.
- **Owned files/callers:** `app/lib/ui/{history_screen.dart,progress_screen.dart,bodyweight_view.dart,add_weight_sheet.dart,targets_tab.dart,progress_change.dart}` and only named chart/value callers `app/lib/widgets/{line_chart.dart,sparkline.dart,volume_bars.dart,stat_tile.dart,pr_badge.dart}` as needed. Own these surfaces' strings in all four ARB files.
- **Focused checks:** `make -C app test TEST=test/ui/history_layout_test.dart`; `... TEST=test/ui/history_session_card_test.dart`; `... TEST=test/ui/progress_layout_test.dart`; `... TEST=test/ui/progress_screen_target_test.dart`; `... TEST=test/ui/bodyweight_history_card_test.dart`; `... TEST=test/alkion/domains/measurement_null_evidence_test.dart`; `... TEST=test/alkion/domains/measurements_targets_test.dart`; `... TEST=test/widgets/line_chart_value_label_test.dart`; `... TEST=test/widgets/unit_swap_test.dart`.

### T5 — Plans and exercise catalog

- **Behavior:** Improve wayfinding and legibility across Split, Exercises and Targets; preserve day/slot ordering, prescription values, exercise identity, pending numeric input, save/delete and unsaved-change protection. Keep empty and populated catalog states distinct.
- **Owned files/callers:** `app/lib/ui/{plan_screen.dart,split_tab.dart,exercise_library_tab.dart,day_editor.dart,exercise_editor.dart,editor_guard.dart,exercise_sheet.dart,set_editor_sheet.dart}` and only `app/lib/widgets/{plan_form.dart,split_card.dart,pending_input.dart}` when required by those screens. Own plan/catalog strings in all four ARB files.
- **Focused checks:** `make -C app test TEST=test/ui/plan_layout_test.dart`; `... TEST=test/ui/plan_profile_layout_test.dart`; `... TEST=test/ui/split_tab_test.dart`; `... TEST=test/ui/day_editor_slot_row_test.dart`; `... TEST=test/ui/exercise_sheet_test.dart`; `... TEST=test/ui/editor_guard_test.dart`; `... TEST=test/ui/plan_editor_dirty_test.dart`; `... TEST=test/alkion/domains/exact_editor_ui_test.dart`.

### T6 — Profile and settings

- **Behavior:** Clarify existing profile, units, locale, theme/accent and preference controls. Preserve settings semantics and retry feedback. Do not add sign-in or sign-out affordances beyond existing enabled behavior.
- **Owned files/callers:** presentation in `app/lib/ui/profile_screen.dart`; settings UI callers `app/lib/settings/{app_languages.dart,bodyweight_goal.dart}` and `app/lib/widgets/{fit_label.dart,plan_form.dart,stepper.dart,w_action_sheet.dart,w_dialog.dart,pending_input.dart}` only if required for profile/settings presentation. Do not change settings persistence/service semantics. Serialize `profile_screen.dart` with Android readiness work. Own profile/settings strings in all four ARB files.
- **Focused checks:** `make -C app test TEST=test/ui/profile_layout_test.dart`; `... TEST=test/ui/profile_header_test.dart`; `... TEST=test/ui/profile_row_tap_test.dart`; `... TEST=test/ui/profile_pickers_test.dart`; `... TEST=test/settings/app_languages_test.dart`; `... TEST=test/settings/settings_test.dart`; `... TEST=test/alkion/domains/preferences_retry_test.dart`.

### T7 — Transfer, export and recovery presentation

- **Behavior:** Make the existing transfer/export/backup/interrupted-restore surfaces explain what was selected, whether a step completed, how to verify the receiving copy, and the safe next action after interruption. Keep originals/current work accessible and defer operation policy to the coordinated preservation plan.
- **Owned files/callers:** presentation only in `app/lib/ui/alkion_transfer/transfer_screen.dart` and `app/lib/ui/alkion_recovery/{recovery_screen.dart,recovery_app.dart}`, plus `app/lib/widgets/w_dialog.dart` only if recovery presentation requires it. Serialize these files with Android readiness work. Do not change `app/lib/recovery/`, `app/lib/transfer/`, `app/lib/store/`, repository code, schemas or domain behavior. Own transfer/recovery strings in all four ARB files and coordinate copy/contracts with the separate owner-readiness plan.
- **Focused checks:** `make -C app test TEST=test/alkion/recovery/recovery_ui_test.dart`; `... TEST=test/alkion/transfer/transfer_screen_test.dart`; `... TEST=test/alkion/acceptance/integrated_flows_test.dart`; `... TEST=test/alkion/workflows/prepared_workflow_retry_test.dart`.

### T8 — Integrated accessibility, locale and candidate qualification

- **Behavior:** Verify all changed surfaces together at narrow and standard phone widths, large text, supported locales, light/dark mode and reduced motion. Capture reviewed synthetic Android evidence on the final refactored candidate for the affected navigation, workout and recovery flows; do not treat widget/Linux results as device proof.
- **Owned files/callers:** Adjust only regressions discovered in T1–T7. Own localization regeneration and `app/test/l10n/arb_parity_test.dart`; add/update focused acceptance coverage in `app/test/alkion/acceptance/` and layout tests. No screenshot fixture is currently present, so any capture set must be generated and reviewed as part of implementation.
- **Focused checks:** `make -C app test TEST=test/alkion/acceptance/layout_locale_test.dart`; `... TEST=test/alkion/acceptance/integrated_flows_test.dart`; `... TEST=test/alkion/acceptance/runtime_boundary_test.dart`; `... TEST=test/l10n/arb_parity_test.dart`; `make -C app analyze`; then synthetic Android qualification on the final candidate. The Flutter Makefile provides `test`, `analyze`, and `gen-l10n`; there is no app `check` or `smoke` target.

## Open decisions and status

- **Priority:** owner ranking of UX friction is optional; if unanswered, use the approved app-wide scope and task order.
- **Build path:** owner preference remains unanswered; if unanswered, use Impeccable's current-session default without persisting it.
- **Future dependency:** opening signup/login and returning-authenticated-session behavior are specified in the later sync workstream; preserve offline/local use and do not implement them here.
- **Status:** design brief and plan drafted from source audit; implementation approval follows the full-lane workflow. No tests or builds run for this docs-only task.

Related: [design brief](../specs/2026-10-17-ui-ux-refactor.md).
