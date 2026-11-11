# Background notification actions: +30s and Skip rest

Date: 2026-11-08, revised 2026-11-09 after design review. Lane: **Full**.
Status: **Approved** by the owner on 2026-11-09, after a design review,
fixes and a re-check.
Parent: [development](../alkion/development.md).
Specification: [background notification actions](../specs/2026-11-08-background-notification-actions.md).
Baseline: `458aac6`. Branch: `feat/background-notification-actions-20261108`.

## Outcome

Today, the notification's +30s brings the app forward, and there is no Skip
(`app/lib/session/workout_notification.dart:106-116`,
`app/lib/session/session_manager.dart:83-90`). After this plan, both act in the
background whether the app is open, backgrounded or killed:

- The plugin's background isolate, which imports no store code, writes only a
  durable intent journal.
- The main isolate is still the only SQL owner. It applies taps through
  step-numbered receipts keyed by rest fields.
- When no owner is present, a provisional mirror is folded from the journal.
- Each launch cancels ghost mirrors.

The spec holds decisions D1–D7 and acceptance A1–A25.

Short names: **P2** is the storage banner plan, **P3** the backup and restore
flow plan, and **P8** the rest alerts and notifications plan. **F1** is the
unreadable workout state plan, and **F2** is this plan. All are in this
directory and dated 2026-11-08.

## Dependencies and order

- **After P8** (`2026-11-08-rest-alerts-and-notifications.md`). P8 leaves the
  +30s wiring as it is. F2 replaces that wiring and stops the route push for
  actions. F2 reuses P8's rest-end channel, its alert variant (same ID 4101),
  its next-set body and its `ic_stat` icon. T0 extracts them into the pure
  renderer.
- **After F1** in `AlkionRuntime.open`: F2's drain #1 runs right after F1's
  quarantine. If F1 hasn't merged, drain #1 goes before `resumeFromDraft`,
  and F1 rebases.
- **`main.dart`** (the `open` and `close` regions only) is shared with P2, P3
  and F1. F2 merges after all three.

## Owner gates

- **OG1, OG2:** resolved 2026-11-09.
  - Design (a) stays, with the provisional render.
  - Each visible tap counts: taps before the visible update count once, with
    no debounce.
  - Ghosts are cancelled on open when there is no active workout.
  - The label is "Skip rest".
- **OG3 (device bar, decides on the fallback):** run a private Dev APK built
  with `ALKION_NOTIFICATION_TRACE` on the owner's phone. Record the Android
  version and patch level in the `acceptance.md` entry. A release-mode APK
  isn't `run-as` debuggable, so the evidence is only logcat markers and the
  app's visible state.
  - **Markers** (listed in spec D6):
    - from the background: `received`, `journaled`, `rendered` and `woke`;
    - from the owner: `applied`, `refused <reason>`, `duplicate`,
      `re-rendered` and `ghost-cancelled`.
  - **States:**
    - foreground, with the shade down;
    - backgrounded;
    - swiped from recents;
    - `am kill` while backgrounded;
    - the lock screen, without unlocking;
    - Doze (`dumpsys deviceidle force-idle`);
    - a frozen cached process (app cached for 10 minutes or more with the
      screen off);
    - battery saver on together with `am set-standby-bucket <pkg> restricted`;
    - a tap during a cold launch;
    - a tap during a restore;
    - double +30s taps;
    - mixed +30s and Skip taps.
  - **Latency** is measured from the **physical tap** to the first
    screen-recording frame where the notification visibly changes. Use "Show
    taps" in developer options and `adb shell screenrecord`. The
    `received` → `rendered` / `re-rendered` marker interval is reported
    beside it. It is the earliest point inside the app, and doesn't count the
    receiver and engine start time.
  - **Bar:**
    - in every state, 10 of 10 taps reach `journaled`, and then `applied` (or
      the expected `refused`) at the next owner drain;
    - the p90 from the physical tap to the visible change is 3 s or less;
    - any lost tap, or a missed p90, means the owner decides on a revised spec
      for fallback (c′).
- **OG4 (device):**
  - The journal path is the same in both engines: a killed-state tap is
    applied at the next launch.
  - `DartPluginRegistrant` lets path_provider resolve in the handler.
  - The alert fires at the new end after +30s, and never after Skip.
  - A ghost is cancelled after a launch with no workout.
  - Opening the app during a background tap gives no `profile_in_use`.
  - **After an app update, tap an action before opening the app.** A stale
    dispatcher handle leaves that process's taps queued until it dies; record
    what happens.
  - After a force-stop, nothing is left pending.

## Tasks

Routing: Claude. Implementers run on Opus `high`, reviewers on Sonnet `high`.
T0 comes first. T1 and T2 then run **in parallel**, because their files are
disjoint and both depend only on T0. T3 needs both. T4 is last. T0, T3 and T4
are **serial** with respect to `main.dart` and `workout_notification.dart`.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T0 Pure modules (no behaviour change) | New `app/lib/session/notification_envelope.dart` (value type, envelope with the UTF-8 byte limit, intent record, legacy decode, the one `notificationJournalDirectory` function, the port-name and wake-message constants); new `app/lib/session/workout_notification_render.dart` (P8's builders, `_notifStrings`, `renderRestMirror`, fixed action order); `notification_action.dart` (class moved out, `owns` becomes a function); `workout_notification.dart` delegates to the renderer; a new transitive import-closure guard in `test/session/notification_import_guard_test.dart`; envelope and renderer unit tests | A20 (guard), A21 |
| T1 Receipts and consumption (storage) | `notification_action.dart`: the one token rule (spec D5), receipt basis and post-step rest, and **removal of the timer-revision checks at `:113`, `:182`, `:190` and `:209`**, `consumeNotificationIntent` for add and skip, the step, duplicate, conflict and gap rules, tap-time checks); `data/active_session_draft.dart` (`consumeAction` and `reconcileNotificationAction` take an intent); `CommittedRestChange` with nullable `restStart` and `restEndedAt`; `active_session_controller.dart`, notification-apply region only (`applyNotificationAction`, `_adoptNotificationRest` taking `endedAt` from the commit). Tests: `test/session/notification_action_test.dart`, `test/alkion/workflows/timer_callback_test.dart` (real SQLite), `test/session/controller_rest_row_test.dart` | A5–A9, A12, A20 (refusals) |
| T2 Journal and background handler (no SQL) | New `app/lib/session/notification_journal.dart` (the directory comes from T0's shared function; atomic write with `flushDirectory`, bounds, ordered read, `.partial` cleanup, checkpoint seam); new `app/lib/session/notification_background.dart` (entry point, module tail, `DartPluginRegistrant`, fold, port check before and after render, trace markers). Tests: `test/session/notification_journal_test.dart`, `test/session/notification_background_test.dart` (injected port, renderer, clock and directory; concurrent delivery; mixed taps; 4096-byte boundary); the crash child `test/support/notification_journal_crash.dart` (pattern: `test/support/remote_recovery_crash.dart`); the guard extended to the handler | A7 (fold), A10, A19 (background side), A20, A21 (boundary), A22 |
| T3 Owner wiring | `session_manager.dart` (drain tail, `drainOwed` and the switch to immediate mode, bounded reconcile skip on resume and init, refresh drains first, forced refresh, ghost cancel, body-tap-only open request, legacy foreground +30s applied directly); `workout_notification.dart` (the two actions, `initialize` with the handler, `force`); `main.dart` (the open sequence with the port registered before drain #1, drain #2, ghost rule, owed-drain release, port unregistered in the failed-open catch, port `closing` and unregistered after `closeNotifications`, the restore path); `AndroidManifest.xml` (receiver and comment). Copying an undecodable entry into `reviews`. Tests: `session_manager_test.dart`, `workout_notification_test.dart`, a new `test/alkion/workflows/notification_intent_launch_test.dart` (real runtime: taps at all five open points, failed open, ghosts, close, bounded reconcile, legacy foreground action, the end-to-end killed chain), `test/alkion/recovery/backup_restore_test.dart` additions, and a fresh-start and restore inventory test with a populated journal | A1–A4, A11, A13–A19, A23 |
| T4 Docs and integration | `docs/alkion/recovery.md`, `development.md`, `acceptance.md` (dated entry, including OG3 results), `android-smoke.md` (the OG3/OG4 rows); integrated checks | A24, A25 |

### Task notes

- **T0** moves code without changing behaviour. The existing
  `workout_notification_test.dart` and `notification_action_test.dart` must
  pass unchanged, apart from import paths.
- **T1** keeps the exact-frozen-bytes reconciliation contract. A receipt
  answers "did step k commit, and with which `intent_id`?". A refusal writes
  nothing.
- **T2** crash cuts:
  - `journal-partial-written`;
  - `journal-renamed` (before the render).

  Tests drive the handler through two un-awaited calls, which reproduces how
  the plugin dispatcher delivers.
- **T3** crash cuts:
  - `intent-consume-open`, inside the transaction;
  - `intent-committed`, before the delete.

  Tests use the fault wrapper for COMMIT uncertainty. The tap-during-open
  test calls the real handler, with a fake renderer, from hooks between the
  open phases.

## Checks

- **Focused, T0:**
  `make -C app test TEST='--concurrency=2 test/session/notification_import_guard_test.dart test/session/workout_notification_test.dart test/session/notification_action_test.dart test/session/notif_strings_test.dart'`.
- **Focused, T1:**
  `make -C app test TEST='--concurrency=2 test/session/notification_action_test.dart test/alkion/workflows/timer_callback_test.dart test/session/controller_rest_row_test.dart'`.
- **Focused, T2:**
  `make -C app test TEST='--concurrency=2 test/session/notification_journal_test.dart test/session/notification_background_test.dart test/session/notification_import_guard_test.dart'`.
- **Focused, T3:**
  `make -C app test TEST='--concurrency=2 test/session test/alkion/workflows test/alkion/recovery test/main_routing_test.dart test/l10n'`.
- **Every task:** `make -C app analyze` and `make -C app format`. Use real
  SQLite for consumption, drain and crash, with synthetic fixtures and
  disposable storage only.
- **Build:** `make -C app build-apk` (debug, with a disposable
  `ANDROID_USER_HOME`). The merged manifest must contain the receiver.
- **Integrated:** `make -C app test TEST=--concurrency=2` passes, apart from
  the three known inherited failures in
  `test/catalog_ui/catalog_metric_controls_test.dart`:
  `duration_distance_optional`, `reps_distance_optional` and
  `reps_duration_optional_load` ("mounts all required and optional controls
  unset").
- **Device:** OG3 and OG4, following the
  [manual APK checklist](../alkion/android-smoke.md). A host PASS never stands
  in for them.

## Risks

- **Background lifetime.** The plugin's receiver has no `goAsync`, so a
  frozen or cold process can lose a tap before it is journaled. The failure is
  visible: no re-render. OG3 measures it, and fallback (c′) covers it.
- **A stale dispatcher handle after an update.** A process can queue taps
  forever (constraint 3). It is checked in OG4. The next app launch
  re-registers the handle.
- **Renderer races.** These are narrowed by registering the port before the
  first drain, re-checking the port after a render, and forcing a refresh on
  every wake-up and every decided intent.
- **Cross-engine `IsolateNameServer`.** This is proven only on the device. A
  missed wake-up delays the apply until the next resume or flush.
- **Payload budget.** Long names in four locales must fit. The title is
  shortened; if the payload still doesn't fit, the tap journals but doesn't
  render.
- **Coupling to P8.** T0's extraction must keep P8's tests byte-compatible.
- **The secondary engine stays resident** for the life of the process once a
  background action has run.

## Coordinator decisions

- **2026-11-11, D1 amendment (T0 review).** The pure renderer
  `workout_notification_render.dart` also imports `dart:ui`, for
  `PlatformDispatcher`'s locale fallback when no locale is stored (a legacy or
  view-less payload). The guard pins the allowed `dart:` imports of every
  module in the background-safe closure, so any other `dart:` library (for
  example `dart:ffi` or `dart:isolate`) fails until it is reviewed and listed.

## Task state

- T0 — done, reviewed (PASS with findings; fixes `2d36824` re-checked PASS). `d6b7bf5d` adds the pure `notification_envelope.dart`
  (action, view, envelope with the UTF-8 budget, intent record, journal
  directory, port and wake constants) and `workout_notification_render.dart`
  (builders, `_notifStrings`, `renderRestMirror`, fixed +30s index 0), which
  `workout_notification.dart` delegates to and re-exports; `owns` is now
  `ownsNotificationAction`. Guard, envelope and renderer tests added; the
  existing notification tests pass unchanged. Review fixes: the owner view
  stores a resolved locale, `notificationSupportRoot` mirrors the owner's
  root derivation, a title is never shortened to nothing, and the guard pins
  `dart:` imports and the pending background modules.
- T1 — not started.
- T2 — done, awaiting review. `2f9e9762` adds `notification_journal.dart`
  (atomic `.partial` write, flush, rename and directory flush; 64-entry and
  8 KiB caps; bounds, kind/action and name checks before decoding, with exact
  bytes kept for unreadable entries; drain-ordered read; ENOENT-tolerant
  delete; 60 s `.partial` cleanup; `journal-partial-written` and
  `journal-renamed` checkpoints) and `notification_background.dart` (entry
  point calling `DartPluginRegistrant` first, module tail, fold, port check
  before and after the render, `exact` queried by the handler, trace markers).
  Tests: journal, handler (fold, concurrency, mixed taps, 4096-byte boundary,
  stale port, real store lock, plugin channel) and the crash child. Outside
  the T2 row: `AlkionIdentity.skipRestAction` (`<prefix>skip_rest`) is added
  for the handler; the guard lists `dart:ui` for the handler and `dart:ffi`
  for `directory_durability.dart`, which spec D1 lets the journal import.
- T3 — not started.
- T4 — not started.

## Next

Start after P8 and F1 merge. OG3
decides whether design (a) stands or the fallback gets specified.
