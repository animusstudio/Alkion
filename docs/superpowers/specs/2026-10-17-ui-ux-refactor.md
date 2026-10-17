# Alkion UI/UX refactor

Date: 2026-10-17. Public full-lane design brief. Status: **approved scope and visual direction; owner answers incorporated; review required**.

## Outcome

Refactor the existing Alkion Android interface before final owner-device qualification. Make the account-free local workflow understandable from first launch through workout logging and recovery, and translate the approved Reps specimen and Animus branding into Flutter while preserving tested behavior, current information architecture and the exact meaning of stored data. The product is an offline-first workout logger; this work is an Operate surface, not a marketing or health-advice surface.

## Source audit (observed in repository)

- `app/lib/main.dart` composes a first-run onboarding choice (starter catalog or empty library) and then the local app. `shouldConnectSync` currently returns false. There is no opening signup/login screen or account attachment behavior in this composition.
- `app/lib/shell/app_shell.dart` keeps Today, Progress, History and Plan in an `IndexedStack`, with a center start-workout action and profile/settings opened as a root overlay. Active workout and summary are separate routes. Plan contains Split, Exercises and Targets sub-tabs and in-place editors.
- `app/lib/session/active_session_screen.dart`, `live_set_card.dart`, `set_line.dart` and `log_set_bar.dart` implement focused live-set entry. The prior prototype's per-set logging layout is superseded. Existing tests cover draft persistence, minimize/resume, finish, timers, history resume, editor retries, exact numeric evidence and broad local workflows.
- The public visual handoff documents Today, Progress, History, Plan, profile/settings and an older multi-set workout layout. It informs surface content; current navigation and focused live-workout behavior govern workflow and structure.
- Current source tokens use a dark near-black/light warm-neutral palette and configurable lime/mint/amber/sky/purple accents. `app/lib/theme/typography.dart` uses Space Grotesk for display, Hanken Grotesk for body/UI and JetBrains Mono for data; `app/lib/theme/motion.dart` checks reduced-motion preference. The approved Reps specimen applies the Animus shared system to a workout surface: ink/bone neutrals, health coral, Hanken Grotesk and JetBrains Mono. The owner selected direct Flutter implementation in this established style and branding.
- Public tests include `app/test/alkion/acceptance/layout_locale_test.dart` (320/412 dp, 1x/2x text, en/de/es/it around Today and active workout), `integrated_flows_test.dart`, `runtime_boundary_test.dart`, domain retry/recovery tests, and focused tests under `session/`, `ui/`, `shell/`, `widgets/`, `theme/`, and `l10n/`. No committed screenshot/golden fixtures were found in the public tree. These are source/test observations, not claims of Android device behavior.

## Approved direction and rationale

The owner prioritized the interface: follow the existing Reps specimen and Animus style and branding. Build directly in Flutter. Keep the current information architecture and workflows; this is a visual and usability translation across existing screens, not a navigation redesign or a new visual world.

Map shared semantic roles into `WorkoutTokens` and Flutter Material 3 theme roles: ink/bone canvases and surfaces, neutral primary actions, coral workout-domain identity, blue focus/info, and distinct caution/danger/success roles. Use Hanken Grotesk for display and interface text and JetBrains Mono for measured values. Reuse the current Flutter components and align their visual roles to the approved specimen: 10 dp controls, 16 dp plates, 4/8/12/16/24/32 dp spacing, flat tonal surfaces and restrained borders. Apply the same system through the existing navigation bar, cards, labels, inputs, steppers, dialogs, sheets, charts and forms; do not create a parallel component library or copy web interaction mechanics into native controls. Retain Android system Back, safe-area/IME inset handling and system text scaling.

The Reps HTML specimen is a visual reference and synthetic interaction demonstration. Its “Sync now” row stands in for a service acknowledgement and is not an Alkion capability. Retain Alkion's current focused-set live workout rather than replacing it with the specimen's older multi-set table. Keep both themes legible, exact values and visible unknown/partial coverage, text/shape distinctions beyond color, 48 dp minimum live-workout controls, system text scaling, localization and reduced motion.

## Surface scope

1. **Opening and onboarding:** current account-free first-use choice and the future opening signup/login entry page. The later Animus sync work must determine first-run and repeat-opening behavior, the returning-auth-session route, and a clear local/offline route. This refactor adds no auth, network sender, attachment, or transport.
2. **Navigation and Today:** tab shell, start action, workout-in-progress indicator, day rotation, empty/loading/error/partial-data states, and profile entry.
3. **Live workout:** focused set card, completed set lines, exercise blocks/picker/reordering, rest timer, pinned logging action, minimize/resume, finish/summary, and interruption/error feedback.
4. **History and progress:** grouped history, edit/resume actions, exercise/bodyweight trends, targets, charts, exact units and coverage explanations.
5. **Plans and catalog:** split/day editing, prescription fields, exercise library/editor, muscle targets, dirty-edit protection, and empty states.
6. **Measurements and settings:** bodyweight entry/history, units, language/theme/accent and remaining existing preferences.
7. **Import, export and recovery:** existing transfer, backup, interrupted-restore and recovery entry points. Clarify irreversible or incomplete steps, destination verification and preservation of current/newer work. Data-preservation policy and operations are outside this UI brief; it governs presentation and interaction only.

## Boundaries

- Preserve account-free offline use and all current local workflows. No auth/session implementation or transport changes here.
- Preserve workout draft/set values, ordering, dates, units, edit semantics, source/correction distinctions, and explicit unknown or incomplete coverage. Never display missing data as zero or imply causation/medical outcomes.
- Keep existing routes and navigation relationships unless a focused test or approved owner decision justifies a change.
- No new product features, catalog/health claims, dependencies, image assets, new identity, or public release claims. Follow the approved specimen and branding; a new visual direction is out of scope.
- Do not claim Android/device qualification from Linux or widget-test results.

## Acceptance

- **A1 — Shared system:** app surfaces map the Animus semantic roles, use Hanken Grotesk for display/interface and JetBrains Mono for data, use coral for workout-domain identity, neutral primary actions and distinct focus/status roles. Dark and light themes retain readable text and controls. No second visual identity is introduced.
- **A2 — First use and access:** the account-free local route remains available. The later opening signup/login treatment is documented as a future sync dependency, with offline launch and returning authenticated-session behavior left explicit for that workstream; this refactor does not authenticate or attach data.
- **A3 — Navigation and core loop:** Today, start/resume, live set entry, rest, minimize, finish/summary, History, Progress, Plan/catalog, Measurements, Settings and recovery remain reachable through existing navigation with clear state feedback.
- **A4 — Input and data truth:** logging/editing preserves exact numeric values, unit conversions, ordering and unknown/partial evidence. Failed or interrupted writes retain visible retry/recovery paths; no success is implied before persistence succeeds.
- **A5 — Accessibility and locale:** layouts remain usable on narrow phones and at large system text scales; live controls remain at least 48 dp; reduced motion is honored; strings remain localized in supported locales without clipped or split critical values.
- **A6 — Recovery and transfers:** app copy and actions communicate source, destination, incomplete status and next safe action in existing flows. Restore does not obscure newer work or the separate preservation contract.
- **A7 — Qualification handoff:** the final refactored candidate receives affected synthetic Android device checks before owner-storage qualification. UI tests or Linux results alone do not satisfy this gate.

## Deferred decisions

- The later sync workstream's exact opening auth page and returning-session behavior. Preserve an account-free local option; do not decide its detailed auth presentation here.
- A future change to the established information architecture or visual direction requires a separate scope decision; neither is part of this refactor.

Related: [UI/UX refactor plan](../plans/2026-10-17-ui-ux-refactor.md).
