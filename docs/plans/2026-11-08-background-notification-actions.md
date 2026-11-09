# Background notification actions: +30s and Skip rest

Date: 2026-11-08. Lane: **Full**. Status: **Proposed** (needs design review
before implementation).
Parent: [development](../alkion/development.md).
Specification: [background notification actions](../specs/2026-11-08-background-notification-actions.md).
Baseline: `458aac6`. Branch: `feat/background-notification-actions-20261108`.

## Outcome

Today, notification +30s brings the app forward, and there is no Skip
(`app/lib/session/workout_notification.dart:106-116`,
`app/lib/session/session_manager.dart:83-90`). After this plan, both act in the
background whether the app is open, backgrounded or killed:

- The plugin's background isolate only writes a durable intent journal.
- The main isolate stays the only SQL owner and applies each intent through a
  step-numbered token receipt.
- With no owner in the process, the background re-renders a provisional mirror
  after its journal entry is durable.

The spec holds the decisions D1–D7 and the acceptance A1–A21.

## Dependencies and order

- **After P8** (`2026-11-08-rest-alerts-and-notifications.md`). F2 replaces
  P8's action wiring, which keeps `showsUserInterface: true` and stops the
  route push. F2 reuses P8's rest-end channel and alert scheduling, its
  next-set body and its `ic_stat` icon. The renderer F2 shares between
  isolates is P8's `showFor` logic, extracted.
- **After F1** where both touch `AlkionRuntime.open`. The journal drain goes
  right after F1's quarantine step. If F1 has not merged, the drain goes before
  `resumeFromDraft` and F1 rebases.
- Shares `main.dart` (the `open` and `close` regions only) with P2, P3 and F1.
  It merges after them.

## Owner gates

- **OG1 (design review):** approve design (a). The journal-only background
  and owner-only SQL include the provisional mirror in the killed case. That
  mirror shows the change before SQL holds it, but only after the tap is
  durably journaled. Fallback (c′) is native posting with `goAsync`.
- **OG2 (behaviour):** a quick double tap on one rendered notification counts
  once, not +60 s (A6). The Skip label is "Skip rest".
- **OG3 (device, decides the fallback):** on the owner's phone with a private
  Dev APK, run ten taps each of +30s and Skip in each state:
  - foreground with the shade down;
  - backgrounded;
  - swiped from recents;
  - after `am kill` while backgrounded;
  - on the lock screen without unlocking.

  Record the time to the re-render and any lost tap. If a tap is lost, or the
  killed-state re-render routinely takes longer than about 3 s, the owner
  decides whether to switch to (c′) in a revised spec.
- **OG4 (device):**
  - the journal path is the same in both engines (a killed-state tap is
    applied at the next launch);
  - the rest-end alert fires at the new end after +30s, and never after Skip;
  - opening the app during a background tap gives no `profile_in_use` and no
    double apply;
  - after force-stop, no stale action remains;
  - a normal launch with the secondary engine resident is fine.

## Tasks

Routing: Claude. Implementers run on Opus `high`, reviewers on Sonnet `high`.
T1 and T2 own disjoint files and run **in parallel**. T3 needs both. T4 is
last. All are **serial** with respect to `main.dart`.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Step receipts and consumption (storage) | `app/lib/session/notification_action.dart`: envelope encode/decode, `step`, the generalised `consumeNotificationIntent` for add and skip with tap-time checks, and the legacy `consumed` receipt read as step 1. `app/lib/data/active_session_draft.dart`: `consumeAction`/`reconcileNotificationAction` take an intent. Tests in `test/session/notification_action_test.dart` and `test/alkion/workflows/timer_callback_test.dart` (real SQLite) | A4–A9, A12, A14 (generation/profile), A15 |
| T2 Journal and background handler (no SQL) | New `app/lib/session/notification_journal.dart` (writer, reader, `retained/`, bounds, `.partial` cleanup, a checkpoint seam). New `app/lib/session/notification_background.dart` (entry point, port lookup, provisional render through an injected renderer). New `test/session/notification_journal_test.dart`, `test/session/notification_background_test.dart`, a source guard (pattern: `test/theme/font_family_source_test.dart`), and a crash child `test/support/notification_journal_crash.dart` (pattern: `test/support/remote_recovery_crash.dart`) | A10, A13, A14 (imports, held lock), A6 (journal side) |
| T3 Owner wiring and renderer | `workout_notification.dart`: shared renderer, the two background actions, `initialize` with the handler, forced re-render, labels in `_notifStrings`. `session_manager.dart`: drain on wake-up, resume and flush, body-tap-only open request. `active_session_controller.dart`: notification apply region only. `main.dart`: drain in `open`, port register and unregister in `open`/`close`, restore path. `AndroidManifest.xml`: receiver and comment. Tests: `session_manager_test.dart`, `workout_notification_test.dart`, a real-runtime launch drain test, `test/alkion/recovery/backup_restore_test.dart` additions | A1–A3, A5, A8 (re-render), A11, A16–A19 |
| T4 Docs and integration | `docs/alkion/recovery.md`, `development.md`, `acceptance.md` (dated entry), `android-smoke.md` (OG3/OG4 checklist rows). Integrated checks | A20, A21 |

### Task notes

- **T1** keeps the exact-frozen-bytes reconciliation contract. The receipt
  answers "did step k commit?" from `consumed_step`, `last_intent_id` and
  `timer_revision`. A duplicate returns the committed rest; a refusal writes
  nothing.
- **T2** must not import `store/`, `identity/alkion_profile.dart`,
  `recovery/` or `data/`. The handler takes injected seams (journal directory,
  port lookup, renderer, clock), so host tests drive every branch. Crash cuts:
  `journal-partial-written`, `journal-renamed` (before render).
- **T3** drains in `open` with SQL only, and through the controller once one
  is registered. Every decided intent ends with
  `refreshNotifications(force: true)`. The port name is
  `<applicationId>.notification-intents`. Crash cuts: `intent-consume-open`
  (inside the transaction) and `intent-committed` (before the delete).

## Checks

- Focused (T1):
  `make -C app test TEST='--concurrency=2 test/session/notification_action_test.dart test/alkion/workflows/timer_callback_test.dart test/session/controller_rest_row_test.dart'`.
- Focused (T2):
  `make -C app test TEST='--concurrency=2 test/session/notification_journal_test.dart test/session/notification_background_test.dart'`
  plus the source guard.
- Focused (T3):
  `make -C app test TEST='--concurrency=2 test/session test/alkion/workflows test/alkion/recovery/backup_restore_test.dart test/main_routing_test.dart test/l10n'`.
- `make -C app analyze` and `make -C app format` for every task.
- Real SQLite for consumption, drain and crash cases. Fixtures are synthetic
  and storage is disposable.
- Build: `make -C app build-apk` (debug, disposable `ANDROID_USER_HOME`). The
  merged manifest must contain the receiver.
- Integrated: `make -C app test TEST=--concurrency=2` passes, apart from the
  three known inherited failures in
  `test/catalog_ui/catalog_metric_controls_test.dart`:
  `duration_distance_optional`, `reps_distance_optional` and
  `reps_duration_optional_load` ("mounts all required and optional controls
  unset").
- Device: OG3 and OG4 on the owner's phone with a private Dev APK, following
  [the manual APK checklist](../alkion/android-smoke.md). Host PASS never
  stands in for them.

## Risks

- **Background lifetime.** The plugin receiver has no `goAsync`, so in a cold
  or frozen process a tap can be lost before the journal write. The failure is
  visible and benign: no re-render, so the user taps again. OG3 measures it,
  and (c′) is the fallback.
- **Two renderers race.** A provisional mirror posted just after the owner's
  can carry a superseded token. A tap on it is refused, and the forced
  re-render corrects the mirror (A8). The window is narrow, because the port
  is registered before the first refresh.
- **Cross-engine `IsolateNameServer`.** It is expected to be process-wide, but
  this is only proven by OG3/OG4. A missing wake-up only delays the apply to
  the next resume.
- **Payload budget.** Long names in four locales must fit in 4096 bytes. The
  title shortens; without `view`, the tap journals but doesn't render.
- **P8 coupling.** F2 depends on P8's alert IDs and channel. Its renderer
  extraction must stay byte-compatible with P8's tests.
- **A resident secondary engine** costs memory for the rest of the process
  lifetime once a background action has run.

## Task state

- T1 — not started.
- T2 — not started.
- T3 — not started.
- T4 — not started.

## Next

Design review of the spec and this plan, then the OG1/OG2 answers. Start after
P8 (and F1) merge. OG3 decides whether (a) stands or the fallback is specified.
