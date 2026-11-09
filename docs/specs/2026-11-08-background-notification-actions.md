# Background notification actions: +30s and Skip rest

Date: 2026-11-08. Status: **Proposed**. Lane: **Full — background intent, timer evidence, native boundary.**
Parent: [development](../alkion/development.md).
Implementation: [plan](../plans/2026-11-08-background-notification-actions.md).
Baseline: `458aac6`. Audit item 6.4. App paths are relative to `app/`.

## Outcome

The workout notification offers **+30s** and a new **Skip rest** during a
rest. Tapping either one, in the shade or on the lock screen, changes the rest
**without opening the app**. This works when the app is in the foreground,
when it is in the background with its process alive, and after the process has
died while the notification remains. The notification re-renders to show the
change: the new countdown and a moved rest-end alert, or the elapsed clock with
the alert cancelled. The next time the workout is shown, it holds the same rest.

Owner decision (2026-11-08): true background actions. They must respect the
profile's single-owner store and the immutable outbox, with the app either
running or closed.

## Current behaviour

- The action uses `showsUserInterface: true` (`lib/session/workout_notification.dart:106-116`),
  so a tap launches the activity. `SessionManager.handleNotificationResponse`
  sets `_notificationOpenRequested` for every response, including +30s
  (`lib/session/session_manager.dart:71-102`). The app comes forward on the
  workout screen. No Skip action exists.
- Design rule today: "No callback opens a profile or writes SQL"
  (`workout_notification.dart:121`). The manifest says "no headless writer" and
  declares no action receiver (`android/app/src/main/AndroidManifest.xml:44-46`).
- +30s is a one-shot capability token. `issueNotificationAction` issues it in
  SQL (`lib/session/notification_action.dart:90-133`). The main isolate consumes
  it in one transaction over the token receipt, the draft and the timer
  (`:143-224`), which refuses after the rest has ended (`:189-196`). The
  controller serialises it with autosave and keeps an uncertain COMMIT until
  the receipt answers (`lib/session/active_session_controller.dart:986,1181-1230`).
- The main Flutter engine is process-scoped (`android/app/src/main/kotlin/dev/animusstudio/alkion/AlkionRuntime.kt:11-15,89`).
  In a live process, an open runtime is the owner. It holds `_ownedPaths` and
  an exclusive non-blocking `flock` on the owner lock
  (`lib/store/local_store.dart:135-147`, `lib/identity/directory_durability.dart:113-127`).

## Plugin constraints (flutter_local_notifications 21.0.0, read from source)

1. An action with `showsUserInterface: false` becomes an immutable
   `PendingIntent.getBroadcast` to the plugin's `ActionBroadcastReceiver`
   (`FlutterLocalNotificationsPlugin.java:310-340`). The app manifest must
   declare that receiver.
2. `onReceive` queues the action. It then starts **one static secondary
   `FlutterEngine` per process**, which runs the plugin's `callbackDispatcher`.
   That dispatcher calls the top-level handler registered through
   `onDidReceiveBackgroundNotificationResponse` (`ActionBroadcastReceiver.java:45-104`,
   `lib/src/callback_dispatcher.dart`). This happens even while the main engine
   runs. The main isolate's `onDidReceiveNotificationResponse` is **not**
   called for these actions. Later taps reuse the running secondary isolate,
   which is never destroyed.
3. The secondary engine auto-registers the pub plugins (path_provider,
   notifications). It does not register the app's own channels, such as
   identity and documents, which `AlkionRuntime.kt` installs only on the main
   engine.
4. There is no `goAsync()` and no foreground service. Once `onReceive` returns,
   Android gives the Dart work no lifetime guarantee. A process started only
   for the broadcast may be frozen or killed.
5. Isolates share no Dart statics, so `_ownedPaths` can't protect across them.
   Two separate `flock` descriptors still conflict inside one process.
6. A tap carries the payload of the notification **as it was posted**. A tap
   racing a re-render can deliver an older payload.

## Options

| | (a) Journal-only background, owner-only SQL | (b) Background opens the store when unowned | (c) Native receiver writes timer evidence |
| --- | --- | --- | --- |
| Single writer | Kept: SQL only in the owner isolate | Two Dart openers. The secondary engine would run preflight, which copies the whole DB, and could run migrations. Holding the lock makes a concurrent launch fail `profile_in_use` | A Kotlin SQLite writer bypasses admission, generation and receipt logic |
| Outbox | Untouched (rest state is local workflow state) | Untouched, but a second code path could reach domain writes | Untouched, but duplicates store invariants natively |
| Running app | Owner applies via the existing serialised path; live UI updates | Still needs a hand-off to the owner (flock refuses) | Needs to notify Dart, which then sees external writes |
| Killed app | Durable journal entry, provisional re-render, owner applies at next open | Applies immediately, if preflight finishes in time | Applies immediately |
| Crash / duplicate | Journal entry kept until SQL decides; step receipts make replay a no-op | Same SQL safety; lock left by a killed engine | Must re-implement receipts in Kotlin |
| Effort / risk | Moderate Dart; manifest line; device-sensitive lifetime | High; identity channel missing in secondary engine | High; new native storage owner |

A fourth route was considered, (c′). Native code would post the action-bearing
notification itself to an app-owned receiver that uses `goAsync()`. That
receiver would write the journal natively, then wake the main engine, or
start it headless. It is more robust to process freezing, but it replaces the
plugin's notification building and starts the full runtime from a broadcast.
It is the **fallback** if the device checks for (a) fail (OG3).

## Decision: (a)

The secondary isolate is a **messenger with a durable intent journal**. It
never opens the profile, never touches SQLite, and never writes domain data.
The main isolate stays the only SQL owner. In a live process, an
`IsolateNameServer` port wakes the owner. With no owner, the background
re-renders a *provisional* mirror, but only after its journal entry is durable.
The next owner open applies the intent and corrects the mirror. This keeps the
existing token, receipt and controller machinery and adds no second writer.

### D1. Payload and actions

- The payload becomes an envelope, at most 4096 bytes:
  `{format: 'alkion-notification-payload/1', action: <unchanged alkion-notification-action/1 object>, step, view}`.
  - `step` (≥ 1) is the ordinal of the next action on this token.
  - `view` holds presentation fields the owner froze at issue: title, rest
    body (P8's next-set line), elapsed body, `started_at`, `rest_start`,
    `rest_total`, locale, and the two action labels.
  - `view` is never authority. If the name makes the envelope too long, the
    title is shortened. If it still doesn't fit, `view` is omitted: the
    background can then journal but not render.
- Actions: `<prefix>add_30s` (the existing ID) and a new `<prefix>skip_rest`.
  Both use `showsUserInterface: false` and `cancelNotification: false`. Labels
  come from the notification string table in en, it, de and es (Skip: "Skip
  rest", "Salta recupero", "Pause überspringen", "Saltar descanso"). A body tap
  still opens the workout through the foreground response. Action taps never
  set the open request, which replaces P8's interim wiring.
- `initialize` registers the background handler. The manifest declares the
  plugin `ActionBroadcastReceiver` with `exported="false"`, and its comment
  changes to "headless messenger; no headless SQL writer".

### D2. Background handler

A top-level `@pragma('vm:entry-point')` function lives in a new
`lib/session/notification_background.dart`. It imports no store, profile,
recovery or SQL code, which a source-guard test enforces. For each response:

1. If the action ID is not one of the two, or the envelope doesn't decode
   within its bounds, return with no write and no render.
2. Append a journal entry (D3). If that fails, stop. The notification then
   stays unchanged, which is honest.
3. Look up the owner port `<applicationId>.notification-intents`. If it is
   present, send a wake-up and stop: the owner re-renders.
4. If it is absent, render provisionally through the **same** renderer the
   owner uses:
   - +30s: a countdown to `rest_start + rest_total + 30`, with both actions at
     `step + 1`, and the rest-end alert moved.
   - Skip: the elapsed clock, no actions, and the rest-end alert cancelled.
   - If the tap time is already at or past the rest end in `view`: the elapsed
     clock, with no change claimed.

   The background never requests permission.

### D3. Intent journal

- **Location:** `<support root>/notification-intents/`. The background derives
  the root from path_provider with the same basename rule as
  `checkedAlkionSupportRoot`, because the identity channel is absent. The owner
  uses the checked root. Both must name the same directory, which is a device
  check.
- **Entry:** `<tapped_at µs>-<intent_id>.json`. It is written as `.partial`,
  flushed, renamed, and then the directory is fsynced. Content:
  `{format: 'alkion-notification-intent/1', intent_id (UUID v4), action_id, kind, tapped_at (UTC), payload (exact string)}`.
- **Bounds:** at most 64 committed entries of 8 KiB each. Beyond that, the
  background refuses (no render).
- **Owner handling:**
  - entries are drained in (`tapped_at`, `intent_id`) order;
  - an entry is deleted **only after** its SQL decision is durable;
  - an undecodable entry is moved untouched to `notification-intents/retained/`
    and never deleted by this feature;
  - `.partial` files older than 60 s are removed, because they were never
    committed intents.
- **Backups:** the journal is excluded, like OS notifications
  ([backup](../alkion/backup.md)). The flush barrier drains it first (D6).

### D4. Owner consumption

`consumeNotificationAction` generalises to one write transaction per intent
(`expected: token`). It checks the following, as today: application, profile,
generation, draft ID, the token equals the issued receipt, active draft and
timer, and draft and timer rests agree. In addition:

- **Step:** the receipt's `consumed_step` is 0 when `issued`. A legacy
  `consumed` receipt counts as 1. The intent's step must equal
  `consumed_step + 1`.
- **Timer revision:** it must equal the receipt's recorded post-step revision,
  or the token's issue revision for step 1. This means nothing else has
  changed the rest since.
- **Tap time:** `tapped_at` ≥ `rest_start`, and `tapped_at` ≤ now + 2 min. The
  rest must still run at `tapped_at` under the current SQL rest. This replaces
  "now", so a deferred apply judges the tap by the time the tap happened.
- **+30s:** `restTotal += 30` in the draft and the timer.
- **Skip:** `restStart = null`, `restTotal = 0`, and
  `restEndedAt = min(tapped_at, due)` in both. This is the in-app `stopRest`
  (`active_session_controller.dart:1494`) evaluated at the tap time.
- **Receipt:** becomes `consumed` with
  `{action, consumed_step, timer_revision, draft_revision, last_intent_id, kind, rest_total}`.
- **Result:** `applied`, or `duplicate` (step ≤ `consumed_step` on the same
  token), or `refused(reason)`. A duplicate or a refusal writes nothing.
- No domain row, operation or outbox entry is written. Rest state is
  `local_state` workflow state, as in `commitWorkflowState`.

The receipt is still one `local_state` row (`timer/notification-action`), and
the payload format changes inside its bytes, so no schema change is needed.

### D5. With a live controller

A drained intent goes through the controller's existing serialised path:

1. settle owed saves;
2. consume;
3. adopt the committed rest with queued edits;
4. keep an uncertain COMMIT in `DraftStore.pendingNotificationAction` until the
   receipt answers.

While a Finish is pending (`callbacksFrozen`), the entry stays in the journal
and is decided at the next drain. After an applied, duplicate or refused
intent, `refreshNotifications` re-renders with `_lastShown` cleared. A
superseded provisional mirror is corrected this way, and a fresh token is
issued.

### D6. When the owner drains

1. In `AlkionRuntime.open`, after F1's quarantine and before
   `resumeFromDraft`. SQL only, since no controller exists yet.
2. On a port wake-up.
3. On lifecycle `resumed`.
4. Inside `flushPersistence`, so backup, restore and close see applied rests.

The port is registered after `open` completes (stale mapping removed first).
It is removed at the start of `close()` and before restore. Wake-ups are only
hints, so correctness never depends on one being delivered.

### D7. Generations and restore

An intent naming an old generation, or a token the selected generation never
issued, is refused at the next drain and deleted. Provisional mirrors from
before a restore are corrected by the new runtime's first refresh.

## Boundaries

- **Single owner:** only the main isolate's `LocalStore` reads or writes the
  profile. The background never opens a profile or SQL, so it can't contend
  for the owner lock or block a launch.
- **Outbox and data separation** ([AGENTS.md](../../AGENTS.md)): no domain
  action. Originals, corrections and derived results are untouched.
- **Uncertain intent kept:** a journal entry stays until SQL decides it.
  Undecodable entries are retained. Uncertain COMMITs reconcile by receipt.
- **Account-free and offline:** no connection I/O. No new permission and no
  foreground service. `POST_NOTIFICATIONS`, the exact-alarm declaration and
  the plugin's `VIBRATE` already exist.
- **Testing** ([app/AGENTS.md](../../app/AGENTS.md)): real SQLite for
  consumption. Host results never claim device qualification.

## Non-goals

Other notification actions; a Profile notification switch; native
notification posting, which belongs to fallback (c′) only; changing the
foreground +30s/Skip chips; recording refused taps as reviews.

## Acceptance

- **A1 (foreground).** With the workout screen open, +30s and Skip from the
  shade change the live rest at once. No route is pushed.
- **A2 (backgrounded, process alive).** +30s and Skip re-render the
  notification through the owner without bringing the app forward. On return,
  the screen shows the same rest.
- **A3 (killed).** +30s and Skip re-render provisionally, and the rest-end
  alert is moved or cancelled. The next launch applies the intents before
  resume, the journal is empty, and the notification carries a fresh token.
- **A4 (chained, killed).** +30s, +30s, Skip on successive provisional mirrors
  equals applying the three in order at the next launch.
- **A5 (Skip semantics).** `restEndedAt` equals the tap time, capped at the
  due time. Elapsed mode has no actions, and no rest-end alert fires.
- **A6 (duplicate tap).** Two taps on one rendered notification (same token
  and step) apply once, in every app state.
- **A7 (duplicate delivery).** The same entry drained twice, or repeated
  wake-ups, apply once.
- **A8 (stale token).** A tap issued before an in-app rest change, set log,
  finish, discard or restore is refused. SQL is unchanged, and the mirror is
  re-rendered from SQL.
- **A9 (late or odd clock).** +30s tapped after the rest end is refused, and
  Skip is a no-op. A tap time before rest start, or more than 2 min in the
  future, is refused.
- **A10 (crash: background).** A kill after the journal rename and before the
  render is applied once by the next drain, and a repeat tap is a duplicate.
  A kill before the rename leaves no entry and no render.
- **A11 (crash: owner).** A kill inside the consume transaction applies
  nothing and keeps the entry; the next drain applies it. A kill after COMMIT
  and before the delete makes the next drain see a duplicate and delete it.
- **A12 (uncertain COMMIT).** An injected COMMIT failure keeps the entry and
  the pending action, and reconciliation by receipt never applies a second
  time.
- **A13 (negative input).** For an unknown action ID or an oversize or
  undecodable payload, the background writes and renders nothing. An
  undecodable journal entry is moved to `retained/` byte-identical, and the
  other entries still apply. With the journal full, the background refuses
  and doesn't render.
- **A14 (isolation).** The background entry point imports no store, profile
  or SQL code (source guard). It works while a real store holds the owner
  lock, and never requests permission. Intents for another application,
  profile or generation are refused.
- **A15 (Finish pending).** Entries wait while a Finish is pending. After
  Finish commits, they are refused and deleted.
- **A16 (body tap).** A body tap still opens the workout. Action taps never
  set the open request.
- **A17 (backup/restore).** Backup flushes and drains first, so the backup
  holds the applied rest and no journal. After restore, old-generation
  entries are refused and removed.
- **A18 (port lifecycle).** After close or restore, no wake-up reaches the
  closed runtime. A stale port leaves the entry for the next drain.
- **A19.** Labels exist in all four locales, and P8's rest-end channel is
  unchanged.
- **A20.** The docs record the design: the notification doc comment, the
  manifest comment, `docs/alkion/recovery.md` (the "background +30s handler"
  wording), `development.md`, `acceptance.md` and `android-smoke.md`.
- **A21.** `make -C app analyze` and the full suite pass, apart from the three
  named inherited failures.
- **Device (owner gates OG2–OG4 in the plan).** Covers the three app states,
  the lock screen, latency and lost taps, journal path equality, alert
  reschedule and cancel, and opening the app during a background tap.
