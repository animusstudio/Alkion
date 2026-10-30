# Catalog workout controls

Date: 2026-10-30. Lane: **Standard — interface integration**.
Status: **Done — locally implemented, qualified and independently reviewed.**
Parent: [development](../alkion/development.md). Related:
[durable catalog contract](../specs/2026-10-30-catalog-in-alkion-dev.md),
[live-set visual contract](../superpowers/specs/2026-09-24-live-set-focus-design.md).

## Outcome and baseline correction

Actual integrated source is `8e4e7ce`: schema5, typed catalog persistence,
draft/recovery and normal Dev integration already exist. Earlier T4–T6 status
is historical. The remaining concrete regression is the catalog workout branch:
inline numeric fields and a separate card bypass the existing rulers, focused
set hierarchy and RIR correction. Restore the incumbent interaction while using
the approved exact typed evidence and prepared actions.

## Decisions and acceptance

- **C1:** Live catalog load/repetitions use existing rulers and modal number
  entry. Duration/distance use the same interaction in seconds/metres. No inline
  live numeric fields; pending-input barriers stop flings before Log/next/setup.
- **C2:** Required/optional quantities remain distinct. Unset/unknown stays unset
  until an explicit edit; optional values can be cleared. Untouched exact raw
  values and units survive all renders, unit changes and modal cancellation.
  Ruler conversion is display-only; explicit editing authors a new exact value.
- **C3:** All sets share the established workout card: one focused editor,
  indexed compact pending/done rows, log/update, RIR prompt/correction/clear,
  mark-not-done, reorder/remove/add and setup/context actions. Timer, rest,
  compatible last-value evidence and prepared persistence retain their meaning.
- **C4:** Catalog History corrections use the same ruler/modal metric editor;
  prepared save/refusal/retry semantics and exact untouched evidence remain.
- **C5:** Meaningful focused tests cover actual-app entry/finish/History,
  duration/distance, optional/unknown, exact kg/lb/off-step values, mid-fling
  barriers, focused/done/RIR behavior, and 320/412dp × 1×/2× across themes/locales.

No schema, action, evidence-codec, backup, export, bundle-content or trial redesign;
no publication, owner-profile inspection, installation or release.

## Tasks and checks

1. **Shared metric controls — standard Flutter.** Own a reusable session metric
   ruler editor and minimal modal helper extension. Consume exact evidence without
   changing its codec; cover explicit edits and no-touch preservation.
2. **Workout and History integration — standard Flutter.** Own affected session
   widgets/controller UI callbacks and History editor. Extend incumbent components
   rather than maintaining a second workout; retain context actions and persistence.
3. **Focused qualification and independent review.** Own touched UI tests and
   localized copy. Run named formatting, analyzer and affected session/catalog/UI
   tests through `make -C app`; record exact scope/results. Independent review
   checks the task diff and C1–C5 before local delivery.

## Task state and next

Owner approval recorded from the current direction to finish remaining
integrations after identifying the numeric-input regression. Plan commit
`1ea906b`; implementation is based on `8e4e7ce`. Tasks 1–3 complete. Independent
task review PASS after two minor display fixes: empty compact rows name required
evidence, and exact nonzero values whose display underflows remain modal-only.

Checks on the final reviewed source:

```sh
make -C app test TEST='test/catalog_ui/catalog_normal_app_journey_test.dart test/session/active_session_screen_test.dart test/session/live_set_card_test.dart test/session/set_line_test.dart test/session/exercise_block_accordion_test.dart test/session/exercise_block_edit_test.dart test/session/log_set_bar_test.dart test/catalog_ui/catalog_metric_controls_test.dart --concurrency=2'
make -C app analyze
make -C app format
```

Focused tests **172 PASS**, including 48 shared metric cases; analyzer **0 issues**;
named formatting and check-only formatting PASS; `git diff --check` PASS.
Normal real-app synthetic journeys retain exact duration through Finish and
History correction, including refused/uncertain-save retry. Screen tests cover
mixed contexts/repeated blocks, load modal entry, RIR correction/clear/unlog,
mid-fling Log/next barriers and 320/412dp × 1×/2× × four locales × both themes.

One bounded host visual batch covered editor/modal states and a full workout at
320dp/light/2×; readable ruler labels were confirmed after concise display-only
formatting. The additional full-workout 412dp capture is UNRUN: its disposable
capture harness stalled and was stopped/removed. Separate 412dp editor/modal
captures and layout tests pass. These are host Flutter renders, not Android
device/gesture/TalkBack qualification. No APK, installation or publication ran.

Next: coordinator local delivery; native qualification stays separately scoped.
