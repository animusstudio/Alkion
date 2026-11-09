# Background notification actions: +30s and Skip rest

Date: 2026-11-08, revised 2026-11-09 after design review. Status: **Proposed**.
Lane: **Full — background intent, timer evidence, native boundary.**
Parent: [development](../alkion/development.md).
Implementation: [plan](../plans/2026-11-08-background-notification-actions.md).
Baseline: `458aac6`. Audit item 6.4. App paths are relative to `app/`.

## Outcome

During a rest, the workout notification offers **+30s** and **Skip rest**.
Tapping either one in the shade or on the lock screen changes the rest
**without opening the app**. This holds in three cases:

- the app is in the foreground;
- the app is in the background with its process alive;
- the process has died while the notification remains.

The notification re-renders to show the change. After +30s it shows the new
countdown and moves the rest-end alert. After Skip it shows the elapsed clock
and cancels the alert. When the workout is next shown, it holds the same rest.
A notification for a workout that no longer exists is removed at the next
launch.

Owner decisions:

- **2026-11-08:** true background actions that respect the single-owner store
  and the immutable outbox, with the app running or closed.
- **2026-11-09:**
  - Keep design (a): journal plus provisional render.
  - **Count each visible tap.** Taps made before the notification visibly
    updates count once. A tap after the update counts again. There is no
    debounce.
  - **Ghosts.** When a launch finds no active workout, it cancels Alkion's
    workout notification and any scheduled rest-end alert.
  - The label is "Skip rest".

## Current behaviour

- **The tap opens the app.** The action uses `showsUserInterface: true`
  (`lib/session/workout_notification.dart:106-116`). Every response, +30s
  included, sets `_notificationOpenRequested` (`lib/session/session_manager.dart:71-102`).
  No Skip action exists.
- **No headless writer.** The notification code states "No callback opens a
  profile or writes SQL" (`workout_notification.dart:121`). The manifest
  declares no action receiver and says "no headless writer"
  (`android/app/src/main/AndroidManifest.xml:44-46`).
- **The token is stale after any save.** `issueNotificationAction` reuses a
  token only while the timer *revision* is unchanged
  (`lib/session/notification_action.dart:109-114`). Every draft save rewrites
  the timer row (`lib/data/session_writer.dart:566-576`), so any autosave makes
  the visible token stale. Consumption also checks the revision (`:189-196`)
  and judges "rest still running" by the current time.
- **`CommittedRestChange.restStart` is non-nullable** (`notification_action.dart:135-139`).
  `_adoptNotificationRest` takes `endedAt` from the pre-action state, not from
  the commit (`lib/session/active_session_controller.dart:1040-1061`).
- **On resume, a rest can be stopped too early.** The resumed lifecycle
  callback runs `_reconcileCommittedRest`, which stops an elapsed rest before
  anything else (`session_manager.dart:182-222`). With an unapplied +30s, it
  would end the rest early.
- **Open order.** `AlkionRuntime.open` resumes the draft, then loads the
  catalog-dependent mappings, then initialises notifications
  (`lib/main.dart:150-178`). `refreshNotifications` returns early without an
  active controller (`session_manager.dart:104-113`), so open never cancels a
  leftover mirror.
- **Single owner.** The main engine is process-scoped
  (`android/app/src/main/kotlin/dev/animusstudio/alkion/AlkionRuntime.kt:11-15,89`).
  An open runtime holds `_ownedPaths` and an exclusive `flock` on the owner
  lock (`lib/store/local_store.dart:135-147`, `lib/identity/directory_durability.dart:113-127`).
- **Shared imports.** `notification_action.dart` imports `store/local_store.dart`,
  and `workout_notification.dart` imports `notification_action.dart`.

## Plugin constraints (flutter_local_notifications 21.0.0 source)

1. **Receiver.** An action with `showsUserInterface: false` becomes
   `PendingIntent.getBroadcast` to the plugin's `ActionBroadcastReceiver`, using
   `FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE` and request code `id*16 + index`
   (`FlutterLocalNotificationsPlugin.java:301-340`). Re-posting the same ID
   **updates the extras of those PendingIntents**. A tap therefore delivers the
   **latest posted** payload for that action index. Action order must stay
   fixed. The manifest must declare the receiver.
2. **One secondary engine per process.** `onReceive` queues the event, then
   starts one static secondary `FlutterEngine` running `callbackDispatcher`.
   That calls the handle registered as
   `onDidReceiveBackgroundNotificationResponse` (`ActionBroadcastReceiver.java:45-104`,
   `lib/src/callback_dispatcher.dart`). This happens even while the main engine
   runs, and the main isolate's foreground callback is not called. The
   dispatcher calls the handler **once per event, without awaiting it**, so two
   taps can interleave.
3. **Lookup failure is permanent for the process.** The engine field is set
   *before* the dispatcher handle lookup (`ActionBroadcastReceiver.java:83-95`).
   If the lookup fails, for example on a stale handle after an update, later
   taps only log "Engine is already initialised". Their events stay cached
   until the process dies.
4. **Plugins in the secondary engine.** It auto-registers the pub plugins'
   Android side, but not the app's own channels (identity, documents). The
   dispatcher calls only `WidgetsFlutterBinding.ensureInitialized()`, never
   `DartPluginRegistrant.ensureInitialized()`.
5. **No lifetime guarantee.** There is no `goAsync()` and no foreground
   service. After `onReceive` returns, a process started for the broadcast may
   be frozen or killed.
6. **No shared statics.** Isolates share no Dart statics, so `_ownedPaths`
   gives no protection across isolates. Separate `flock` descriptors still
   conflict, even within one process.

## Options

| | (a) Journal-only background, owner-only SQL | (b) Background opens store when unowned | (c) Native receiver writes timer |
| --- | --- | --- | --- |
| Single writer | Kept | Second opener: preflight copies the DB, migrations possible, a held lock fails launch with `profile_in_use` | Kotlin writer bypasses admission and receipts |
| Running app | Owner applies; live UI updates | Still needs a hand-off | Dart must learn of external writes |
| Killed app | Durable entry, provisional mirror, owner applies at next open | Applies if preflight finishes | Applies |
| Risk | Lifetime of the secondary engine | High | High |

Fallback (c′): native posting to an app-owned receiver that uses `goAsync()`.
It writes the journal natively, then wakes or starts the main engine. It is
specified only if the OG3 device bar fails.

## Decision: (a)

The secondary isolate is a **messenger with a durable intent journal**. It
never opens the profile and never touches SQLite, and an import-closure guard
proves it. The main isolate remains the only SQL owner.

### D1. Pure modules (no store imports)

- **`lib/session/notification_envelope.dart`** holds the
  `NotificationAction` value type, its `encode`/`decode`, the payload envelope
  and the intent record. It imports only `dart:convert` and
  `identity/alkion_identity.dart`. `owns(LocalDatabase, …)` moves to
  `notification_action.dart` as a function.
- **`lib/session/workout_notification_render.dart`** holds:
  - the Android details builders (P8's channels and alert variant);
  - `_notifStrings`;
  - a `renderRestMirror(plugin, state)` function that posts the mirror,
    reschedules or cancels the rest-end alert, and posts nothing else.

  It imports the plugin, timezone, `alkion_identity.dart` and the envelope
  module only. `workout_notification.dart` (the owner) delegates to it.
- The guard test walks the **transitive** `package:alkion/` import closure of
  `notification_background.dart`. It fails on any `store/`, `data/`,
  `recovery/`, `domain/local_action.dart`, `identity/alkion_profile.dart`,
  sqlite or `sqlite_async` import.

### D2. Payload and actions

- The payload is `{format: 'alkion-notification-payload/1', action, step, view}`,
  at most 4096 bytes. The fields:
  - `action` is the unchanged `alkion-notification-action/1` object.
  - `step` (≥ 1) is the ordinal of the next action on that token.
  - `view` is presentation state: the title, the rest and elapsed bodies
    (P8's next-set line), `started_at`, `rest_start`, `rest_total`, the locale
    and the labels. It is never authority.
- If the payload is too long, the title is shortened. If it still doesn't fit,
  `view` is omitted: the tap then journals but doesn't render.
- Legacy payloads, meaning the bare `/1` token from notifications posted by an
  older build, decode as step 1 with no `view`. Body taps accept both forms.
- Action order is fixed in every render: **+30s at index 0** (the existing
  `<prefix>add_30s`) and **Skip rest at index 1** (new `<prefix>skip_rest`).
  Both use `showsUserInterface: false` and `cancelNotification: false`.
- Labels come from `_notifStrings` in en, it, de and es: "Skip rest",
  "Salta recupero", "Pause überspringen", "Saltar descanso".
- A body tap still opens the workout through the foreground path. **F2 stops
  the route push for actions.** P8 leaves the action wiring as it is, and F2
  replaces it.
- `initialize` registers the background handler. The manifest declares the
  plugin `ActionBroadcastReceiver` with `exported="false"`. Its comment becomes
  "headless messenger; no headless SQL writer".

### D3. Background handler

`lib/session/notification_background.dart` holds a top-level
`@pragma('vm:entry-point')` handler.

- It calls `DartPluginRegistrant.ensureInitialized()` first. It **never calls
  `initialize`** and never requests permission.
- All work runs on **one module-level future tail**, so concurrent deliveries
  are serialised in arrival order.

For each event:

1. If the action ID is not one of the two, or the payload doesn't decode
   within bounds, it does nothing.
2. It appends a journal entry (D4). If that fails, it stops without rendering.
3. It looks up the port `<applicationId>.notification-intents`. If the port
   exists, it sends a wake-up and stops. The owner renders.
4. If there is no port, it builds the provisional state by **folding** the
   journal entries for this token:
   - the base is the `view` of the lowest-step entry;
   - it takes the first arrival per step, in step order, and stops at a gap;
   - +30s adds 30 to `rest_total`;
   - Skip, or a tap time at or past the folded rest end, gives elapsed mode;
   - the tapped payload's own `view` is never used.
5. It renders with `renderRestMirror`. The render always uses P8's alert
   variant, because no screen is open. The new payload carries the folded
   `view` and `step = last applied step + 1`.
6. It **looks up the port again after rendering**. If an owner appeared
   meanwhile, it sends a wake-up, and the owner corrects the mirror with a
   forced re-render.

The handler writes trace markers through `print`, without names:
`alkion-notif received|journaled|rendered|woke <intent-id-prefix> <step> <kind>`.
They are compiled in only with `ALKION_NOTIFICATION_TRACE`, which the private
Dev APK used for OG3 enables.

### D4. Intent journal

- **Location.** A sibling of the support root:
  `<parent of support root>/.<applicationId>-notification-intents/`. This
  follows the `EntryJournal` precedent (`lib/identity/entry_journal.dart:47-50`).
  The root inventories in `AlkionProfile` (`lib/identity/alkion_profile.dart:107-116,182-191,276-290`)
  and `RestoreService` (`lib/recovery/restore.dart:359-394,438-460`) never see
  it. Fresh start, first-start restore and "bytes without identity" detection
  are therefore unchanged. A test asserts this with a populated journal.
- **Paths.** The background derives the directory from path_provider's files
  directory, whose path starts `/data/user/0`. The owner derives it from its
  checked, canonical root, which may differ in spelling. Both must name the
  same directory. The owner compares with `FileSystemEntity.identical` when
  both paths exist. A host test uses a symlinked alias, and OG4 checks it on
  the device.
- **Entry.** `<tapped_at µs>-<intent_id>.json`, written as `.partial`, flushed,
  renamed, then the directory is flushed with `flushDirectory`
  (`identity/directory_durability.dart:7`, no store imports). Content:
  `{format: 'alkion-notification-intent/1', intent_id, action_id, kind, tapped_at, payload}`.
- **`tapped_at` is the time the background handler ran**, not the physical
  tap. It is used for the "rest still running" check and as the tie-breaker
  between arrivals within one step.
- **Bounds.** At most 64 committed entries, 8 KiB each. Beyond that, the
  background refuses and doesn't render.
- **Undecodable entries.** The owner copies the exact bytes into `reviews`
  (category `notification_intent_unreadable`, an `rv-`-style deterministic
  ID), then deletes the file. If that write fails, the file stays and counts
  toward the cap. No permanent `retained/` directory exists.
- `.partial` files older than 60 s are removed.
- The journal is excluded from backups, like OS notifications
  ([backup](../alkion/backup.md)).

### D5. Owner consumption

Tokens are keyed by **rest fields, not timer revision** (m3).
`issueNotificationAction` reuses the issued token while `draftId`,
`restStart` and `restTotal` are unchanged. At issue, the receipt records the
rest basis `{rest_start, rest_total}`.

Each intent gets one write transaction with `expected: token`. It checks, as
today, the application, profile, generation, draft ID, that the token equals
the issued receipt, and that the draft and timer are both active with agreeing
rests. Then:

- **Basis.** The current SQL rest must equal the basis of the step: the
  issued basis for step 1, or the receipt's post-step rest for later steps.
  Unrelated saves don't refuse a tap. An in-app rest change does.
- **Step.**
  - `step == consumed_step + 1` → apply.
  - `step ≤ consumed_step` with `intent_id == last_intent_id` → `duplicate`
    (the same entry delivered again).
  - `step ≤ consumed_step` with another intent → `refused(conflict)`. This is
    a second tap before the notification visibly updated, which counts once.
  - `step > consumed_step + 1` → `refused(gap)`.
  - A legacy `consumed` receipt counts as step 1.
- **Time.** `tapped_at` must be ≥ `rest_start` and ≤ now + 2 min. The rest
  must still be running at `tapped_at`.
- **+30s.** `restTotal += 30` in both the draft and the timer.
- **Skip.** `restStart = null`, `restTotal = 0` and
  `restEndedAt = min(tapped_at, due)` in both. This is `stopRest`
  (`active_session_controller.dart:1494`) at the tap time.
  `CommittedRestChange` gains a nullable `restStart` and a nullable
  `restEndedAt`, and `_adoptNotificationRest` takes `endedAt` from the commit.
- **Receipt.** It becomes `consumed` with
  `{action, basis, consumed_step, last_intent_id, kind, rest_start, rest_total, rest_ended_at, draft_revision}`.
- **Outcomes.** `applied`, `duplicate` or `refused(reason)`. The reasons are
  `stale_generation`, `foreign`, `draft_not_active` (including an F1-retired
  draft), `token_superseded`, `basis_changed`, `conflict`, `gap`, `late` and
  `clock`. Only `applied` writes.
- **No outbox.** No domain row, operation or outbox entry is written. The
  receipt stays one `local_state` row, so no schema change is needed.

**Drain order** is by token, then step, then (`tapped_at`, `intent_id`). An
entry is deleted only after its outcome is durable. A delete that fails with
ENOENT counts as success.

### D6. Owner drains, open order, ghosts and close

- **Serialised.** One drain tail in `SessionManager` runs the wake-up,
  resume, flush and open drains in sequence.
- **Open sequence:**
  1. Open the store, settings and catalog.
  2. Run F1's quarantine.
  3. Construct `SessionManager`.
  4. **Register the port** after removing any stale mapping. A wake-up now
     only marks a drain as owed.
  5. Drain #1, SQL only.
  6. Run `resumeFromDraft` and `loadLastFinished`, then `init`. The init-time
     `_reconcileRest` is skipped while the journal is non-empty.
  7. Build the history mappings, then run `initializeNotifications`.
  8. Drain #2, through the controller if one exists.
  9. If **no workout is active**, cancel mirror ID 4101 and its scheduled
     rest-end alert: P8's alert reuses that ID, and the plugin's `cancel(id)`
     also cancels the alarm. Otherwise, refresh with `force` (`_lastShown`
     cleared).
- **Drain before issue.** `refreshNotifications` drains before it issues.
  While the journal still holds entries for the current token after a drain,
  for example while a Finish is pending, it issues no replacement token.
- **With a live controller.**
  1. Settle owed saves; these no longer refuse an intent, because consumption
     judges by rest fields.
  2. Consume.
  3. Adopt the committed rest with the queued edits.
  4. Keep an uncertain COMMIT in `DraftStore.pendingNotificationAction` until
     the receipt answers it.

  While `callbacksFrozen` is set, entries wait. Every decided intent ends with
  a forced refresh.
- **Resume.** On `resumed`, drain first. `_reconcileCommittedRest` runs only
  after the drain, and skips the stop while the journal is non-empty (M1).
- **Robustness.** Drain errors never fail launch or crash the app:
  - I/O errors and a missing directory;
  - non-file or symlink entries, which are ignored and not followed;
  - a failed copy of an undecodable entry;
  - a store error, such as a malformed draft before F1.

  In each case the entry stays, and the error goes to P2's persistence banner.
- **Close and restore.** `close()` marks the port handler `closing`, so
  wake-ups are ignored. The port stays registered **until
  `closeNotifications` has cancelled the mirror** and the store has closed.
  While the port exists, the background never renders. After the port is
  unregistered, the background may render provisionally. The next open's
  drain refuses old-generation entries, and the ghost rule then cancels or
  refreshes the mirror.

### D7. "Count each visible tap" in practice

Constraint 1 means a tap always carries the latest posted payload.

- Taps made before the notification visibly updates share one step: the
  first applies, and the others are `conflict` or `duplicate`.
- A tap after the update carries the next step, or a fresh token, and applies
  again.

## Boundaries

- **Single owner.** Only the main isolate's `LocalStore` reads or writes the
  profile. The background touches only the sibling journal and the plugin.
- **Outbox and data separation** ([AGENTS.md](../../AGENTS.md)): no domain
  action is written. Uncertain intent is kept until SQL decides it.
  Undecodable intent is copied into `reviews` before it is removed.
- **Offline.** No connection I/O, no new permission, no foreground service.
- **Tests and claims** ([app/AGENTS.md](../../app/AGENTS.md)): consumption is
  tested on real SQLite, and host results never claim device qualification.

## Non-goals

Other actions, a Profile notification switch, native notification posting
(fallback only), changing the in-app +30s/Skip chips, and recording refusals
as reviews.

## Acceptance

- **A1 (foreground).** +30s and Skip from the shade change the live rest at
  once. No route is pushed.
- **A2 (backgrounded).** The owner applies and re-renders without the app
  coming forward. The screen shows the same rest on return.
- **A3 (killed).** The provisional mirror shows the change, and the rest-end
  alert moves or is cancelled. The next launch applies the taps before resume,
  empties the journal and issues a fresh token.
- **A4 (killed chain, end to end).** +30s, +30s, Skip through the real
  handler with captured payloads, then a real-runtime launch. SQL equals the
  three applied in order.
- **A5 (Skip semantics).** `restEndedAt` is the tap time, capped at the due
  time. Elapsed mode shows no actions, and no alert fires.
- **A6 (visible taps).** Taps before the notification visibly updates count
  once, whatever the app state. A tap after the update counts again, with no
  time-based debounce.
- **A7 (concurrent and mixed).** Two deliveries are serialised. Mixed +30s and
  Skip at one step apply only the first arrival, and the second is
  `refused(conflict)`. The provisional mirror equals the fold. A redelivered
  entry is a `duplicate`.
- **A8 (stale token).** A tap issued before an in-app rest change, a finish, a
  discard or a restore is refused, and the mirror re-renders from SQL. An
  unrelated autosave does not make the visible token stale.
- **A9 (late or odd clock).** +30s after the rest end is refused, and Skip is
  a no-op. A tap time before rest start, or more than 2 min in the future, is
  refused.
- **A10 (crash: background).** A kill after the rename and before the render
  is applied once by the next drain. A kill before the rename leaves no entry
  and no render.
- **A11 (crash: owner).** A kill inside the consume transaction applies
  nothing, keeps the entry, and the next drain applies it. A kill after COMMIT
  and before the delete is seen as a duplicate and deleted. ENOENT on delete
  counts as success.
- **A12 (uncertain COMMIT).** An injected COMMIT failure keeps the entry and
  the pending action. Reconciling by receipt never applies twice.
- **A13 (tap during open).** A real-runtime test journals a tap between each
  open phase:
  - after quarantine;
  - between drain #1 and resume;
  - during `initializeNotifications`.

  Each tap is applied once, and the final mirror carries the applied rest.
- **A14 (ghosts).** A pending provisional mirror is cancelled, alert included,
  at the next open in each of these cases:
  - F1 quarantines the draft;
  - a restore selects a generation without a workout;
  - an old-generation intent is refused.
- **A15 (close).** During `close()` the port stays registered and ignores wake-ups (`closing`), so the background
  doesn't render, and the mirror stays cancelled.
- **A16 (resume ordering).** On `resumed` with a journaled +30s, the rest is
  extended and not stopped.
- **A17 (negative input).**
  - An unknown action ID, an oversize payload or an undecodable payload gets
    no write and no render.
  - An undecodable entry is copied byte-identical into `reviews`, then
    removed.
  - With the journal full, the background refuses.
  - Directory, symlink and I/O faults never fail launch.
- **A18 (isolation).**
  - The import closure of the background handler holds no store code.
  - The handler works while a real store holds the owner lock, and never calls
    `initialize` or requests permission.
  - Intents for another application, profile or generation are refused.
  - A populated journal doesn't change fresh-start or restore inventory
    checks.
- **A19 (envelope).**
  - Legacy bare `/1` body-tap payloads still open the workout.
  - The 4096-byte boundary holds with long names in all four locales.
  - Action order is +30s first and Skip second in every render.
- **A20 (port).** A stale port with no listener leaves the entry for the next
  drain. The handler then shows no render, which is the honest feedback.
- **A21 (backup and restore).** A flush drains before backup, so the backup
  holds the applied rest and no journal. After a restore, old-generation
  entries are refused and removed.
- **A22 (docs).** The docs record the design:
  - the notification doc comments and the manifest comment;
  - `docs/alkion/recovery.md` (the "background +30s handler" wording);
  - `development.md`, `acceptance.md` and `android-smoke.md`.
- **A23 (checks).** `make -C app analyze` and the full suite pass, apart
  from the three named inherited failures.
- **Device.** OG3 and OG4 in the plan, with a decidable bar.
