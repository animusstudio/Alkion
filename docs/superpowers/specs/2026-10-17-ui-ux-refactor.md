# Alkion UI/UX refactor

Date: 2026-10-17. Public full-lane design brief. Status: **PROPOSED; implementation not approved by this document.**

## Outcome

Refactor the existing Alkion mobile interface before final owner-device qualification. Make the account-free local workflow understandable from first launch through workout logging and recovery, and align the app with the shared Animus visual system while preserving the tested behavior and exact meaning of stored data. The product is an offline-first workout logger; this work is an Operate surface, not a marketing or health-advice surface.

## Source audit (observed in repository)

- `app/lib/main.dart` composes a first-run onboarding choice (starter catalog or empty library) and then the local app. `shouldConnectSync` currently returns false. There is no opening signup/login screen or account attachment behavior in this composition.
- `app/lib/shell/app_shell.dart` keeps Today, Progress, History and Plan in an `IndexedStack`, with a center start-workout action and profile/settings opened as a root overlay. Active workout and summary are separate routes. Plan contains Split, Exercises and Targets sub-tabs and in-place editors.
- `app/lib/session/active_session_screen.dart`, `live_set_card.dart`, `set_line.dart` and `log_set_bar.dart` implement focused live-set entry. The prior prototype's per-set logging layout is superseded. Existing tests cover draft persistence, minimize/resume, finish, timers, history resume, editor retries, exact numeric evidence and broad local workflows.
- The historical public visual handoff documents Today, Progress, History, Plan, profile/settings and the older workout layout. It is an interaction/content reference; where it conflicts with current source and focused live-workout design, current behavior and tests govern.
- Current source tokens use a dark near-black/light warm-neutral palette and configurable lime/mint/amber/sky/purple accents. `app/lib/theme/typography.dart` uses Space Grotesk for display, Hanken Grotesk for body/UI and JetBrains Mono for data; `app/lib/theme/motion.dart` checks reduced-motion preference. The approved shared system uses ink/bone, health coral, Hanken Grotesk and JetBrains Mono. The refactor should align the display face and shared color meaning without inventing a new identity or adopting unrelated domain colors.
- Public tests include `app/test/alkion/acceptance/layout_locale_test.dart` (320/412 dp, 1x/2x text, en/de/es/it around Today and active workout), `integrated_flows_test.dart`, `runtime_boundary_test.dart`, domain retry/recovery tests, and focused tests under `session/`, `ui/`, `shell/`, `widgets/`, `theme/`, and `l10n/`. No committed screenshot/golden fixtures were found in the public tree. These are source/test observations, not claims of Android device behavior.

## Direction and rationale

Keep the current mobile-first information architecture and workout interactions. Refactor through shared Flutter components and screen-specific hierarchy changes where evidence identifies friction; do not invent a replacement navigation model or add product capabilities. Use the existing shared ink/bone system, health coral for workout-domain emphasis, Hanken Grotesk for interface text, and JetBrains Mono for measured values. Keep both dark and light themes legible. Keep exact values and visible unknown/partial coverage; color cannot be the only carrier of meaning. Match established 48 dp minimum live-workout controls, allow system text scaling, preserve localization, and respect reduced motion.

The specific highest-priority UX friction remains **unranked**. The coordinator invited an optional owner preference; if none is supplied, use the approved app-wide scope and task order in this brief and plan. This document does not assert a known user complaint, require a separate product approval, or prescribe a new visual concept.

## Surface scope

1. **Opening and onboarding:** current account-free first-use choice and the future opening signup/login entry page. The later Animus sync work must determine first-run and repeat-opening behavior, the returning-auth-session route, and a clear local/offline route. This refactor adds no auth, network sender, attachment, or transport.
2. **Navigation and Today:** tab shell, start action, workout-in-progress indicator, day rotation, empty/loading/error/partial-data states, and profile entry.
3. **Live workout:** focused set card, completed set lines, exercise blocks/picker/reordering, rest timer, pinned logging action, minimize/resume, finish/summary, and interruption/error feedback.
4. **History and progress:** grouped history, edit/resume actions, exercise/bodyweight trends, targets, charts, exact units and coverage explanations.
5. **Plans and catalog:** split/day editing, prescription fields, exercise library/editor, muscle targets, dirty-edit protection, and empty states.
6. **Measurements and settings:** bodyweight entry/history, units, language/theme/accent and remaining existing preferences.
7. **Import, export and recovery:** existing transfer, backup, interrupted-restore and recovery entry points. Clarify irreversible or incomplete steps, destination verification and preservation of current/newer work. Detailed data-preservation policy and operations belong to the parallel Android owner-readiness plan; this UI brief governs presentation and interaction only.

## Boundaries

- Preserve account-free offline use and all current local workflows. No auth/session implementation or transport changes here.
- Preserve workout draft/set values, ordering, dates, units, edit semantics, source/correction distinctions, and explicit unknown or incomplete coverage. Never display missing data as zero or imply causation/medical outcomes.
- Keep existing routes and navigation relationships unless a focused test or approved owner decision justifies a change.
- No new product features, catalog/health claims, dependencies, image assets, new identity, or public release claims.
- Do not copy private planning guidance, backend internals, owner data or credentials into Alkion.
- Do not claim Android/device qualification from Linux or widget-test results.

## Acceptance

- **A1 — Shared system:** visible app surfaces use a coherent ink/bone palette, existing typography and shared health-domain accent semantics; dark and light themes retain readable text, focus and status cues. No second visual identity is introduced.
- **A2 — First use and access:** the account-free local route remains available. The later opening signup/login treatment is documented as a future sync dependency, with offline launch and returning authenticated-session behavior left explicit for that workstream; this refactor does not authenticate or attach data.
- **A3 — Navigation and core loop:** Today, start/resume, live set entry, rest, minimize, finish/summary, History, Progress, Plan/catalog, Measurements, Settings and recovery remain reachable through existing navigation with clear state feedback.
- **A4 — Input and data truth:** logging/editing preserves exact numeric values, unit conversions, ordering and unknown/partial evidence. Failed or interrupted writes retain visible retry/recovery paths; no success is implied before persistence succeeds.
- **A5 — Accessibility and locale:** layouts remain usable on narrow phones and at large system text scales; live controls remain at least 48 dp; reduced motion is honored; strings remain localized in supported locales without clipped or split critical values.
- **A6 — Recovery and transfers:** app copy and actions communicate source, destination, incomplete status and next safe action in existing flows. Restore does not obscure newer work or the separate preservation contract.
- **A7 — Qualification handoff:** the final refactored candidate receives affected synthetic Android device checks before owner-storage qualification. UI tests or Linux results alone do not satisfy this gate.

## Open decisions before implementation

- Optional owner ranking of UX friction (unanswered at drafting time; if absent, follow the approved scope and sequence).
- Whether comp-first image mockups or direct Flutter implementation should lead this work (requested by coordinator; unanswered at drafting time). If unanswered, use Impeccable's current-session default and do not persist a preference. This is a workflow choice only, not permission to choose another identity.
- The later sync workstream's exact opening auth page and return-session behavior. Preserve an account-free local option; do not decide its detailed auth presentation here.

Related: [UI/UX refactor plan](../plans/2026-10-17-ui-ux-refactor.md).
