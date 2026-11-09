# Background notification actions: +30s and Skip rest

Date: 2026-11-08, revised 2026-11-09 after design review. Status: **Proposed**.
Lane: **Full — background intent, timer evidence, native boundary.**
Parent: [development](../alkion/development.md).
Implementation: [plan](../plans/2026-11-08-background-notification-actions.md).
Baseline: `458aac6`. Audit item 6.4. App paths are relative to `app/`.

Sibling plans, all dated 2026-11-08, are named by topic here:

- the rest alerts plan, [rest alerts and notifications](../plans/2026-11-08-rest-alerts-and-notifications.md);
- the storage banner plan, [storage banner and launch screens](../plans/2026-11-08-storage-banner-and-launch-screens.md);
- the unreadable-workout-state quarantine, in [unreadable workout state](2026-11-08-unreadable-workout-state.md).

OG3 and OG4 are the device gates in this spec's
[plan](../plans/2026-11-08-background-notification-actions.md#owner-gates).

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
proves both. The main isolate remains the only SQL owner.

### D1. Pure modules (no store imports)

- **`lib/session/notification_envelope.dart`**:
  - the `NotificationAction` value type, its `encode`/`decode`, the payload
    envelope and the intent record;
  - the **only** journal-path function,
    `notificationJournalDirectory(Directory filesDirectory)`, used by both
    engines (D4);
  - the port name constant `notificationPortName`
    (`'<applicationId>.notification-intents'`) and the wake-up message
    constant.

  It imports only `dart:convert`, `dart:io`, `package:path` and
  `identity/alkion_identity.dart`. `owns(LocalDatabase, …)` moves to
  `notification_action.dart` as a function.
- **`lib/session/workout_notification_render.dart`**:
  - the Android details builders, with the rest-end channel and alert variant
    from the rest alerts plan;
  - `_notifStrings`;
  - a `renderRestMirror(plugin, state)` function that posts the mirror and
    reschedules or cancels the rest-end alert, and does nothing else.

  It imports only the plugin, timezone, `alkion_identity.dart` and the
  envelope module. The owner's `workout_notification.dart` delegates to it.
- **`lib/session/notification_journal.dart`**: the journal reader and
  writer. It imports the envelope module and `identity/directory_durability.dart`,
  which has no store imports.
- **Guard test.** It walks the **transitive** `package:alkion/` import closure
  of `notification_background.dart`, and fails on any import of `store/`,
  `data/`, `recovery/`, `domain/local_action.dart`,
  `identity/alkion_profile.dart`, sqlite or `sqlite_async`.

### D2. Payload and actions

- **Payload.** The payload is
  `{format: 'alkion-notification-payload/1', action, step, view}`. Its size is
  measured in **UTF-8 bytes**: `utf8.encode(payload).length ≤ 4096`. Today's
  check counts UTF-16 code units (`payload.length > 4096`,
  `notification_action.dart:39`), and the envelope decoder switches to bytes.
  The fields:
  - `action`: the unchanged `alkion-notification-action/1` object.
  - `step` (≥ 1): the ordinal of the next action on that token.
  - `view`: presentation state, never authority. It holds the title, the rest
    and elapsed bodies (with the next-set line from the rest alerts plan),
    `started_at`, `rest_start`, `rest_total` and the locale. There are no
    labels, because the renderer derives them from the locale through
    `_notifStrings`.
- **Size limit.** If the payload is too long, the title is shortened on a
  character boundary. If it still doesn't fit, `view` is omitted, and the tap
  then journals but doesn't render.
- **Legacy payloads.** The bare `/1` token from notifications posted by an
  older build decodes as step 1 with no `view`.
  - **Body taps** accept both forms.
  - **Legacy +30s taps.** An older build's +30s used `showsUserInterface: true`.
    If that action is tapped after an update and before the first refresh, it
    reaches the main isolate's foreground callback (or the launch details) with
    `actionId == <prefix>add_30s` and a bare payload.
  - The owner **applies a legacy tap directly, without journaling it**,
    because the owner is already running. It becomes an in-memory intent, with
    step 1, `tapped_at = now`, a fresh `intent_id` and kind `add`. It goes
    through the same serialised consumption as a drained intent.
  - A legacy tap never sets the open request. A foreground response carrying
    an unknown action ID is ignored.
- **Action order** is fixed in every render:
  - index 0: **+30s**, the existing `<prefix>add_30s`;
  - index 1: **Skip rest**, the new `<prefix>skip_rest`.

  Both use `showsUserInterface: false` and `cancelNotification: false`. Skip's
  labels are "Skip rest", "Salta recupero", "Pause überspringen" and
  "Saltar descanso".
- **Body tap and route push.** A body tap still opens the workout through the
  foreground path. **This plan stops the route push for actions.** The rest
  alerts plan leaves the action wiring as it is, and this plan replaces it.
- **Registration.** `initialize` registers the background handler. The
  manifest declares the plugin's `ActionBroadcastReceiver` with
  `exported="false"`. Its comment becomes "headless messenger; no headless SQL
  writer".

### D3. Background handler

`lib/session/notification_background.dart` holds a top-level
`@pragma('vm:entry-point')` handler.

- It calls `DartPluginRegistrant.ensureInitialized()` first. It **never
  calls `initialize`**, and never requests permission.
- All work runs on **one module-level future tail**, so concurrent deliveries
  are serialised in the order they arrive.

For each event, the handler:

1. Does nothing if the action ID is not one of the two, or the payload doesn't
   decode within its bounds.
2. Appends a journal entry (D4). If the append fails, it stops without
   rendering.
3. Looks up the port `notificationPortName`. If the port exists, it sends a
   wake-up and stops; the owner then renders.
4. If there is no port, builds the provisional state by **folding** the journal
   entries for this token:
   - the base is the `view` and step of the lowest-step entry;
   - it takes the first arrival per step, in step order, and stops at a gap;
   - +30s adds 30 to `rest_total`;
   - Skip, or a tap time at or past the folded rest end, gives elapsed mode;
   - the tapped payload's own `view` is never used.

   This matches the owner's token rule (D5): same token, `step` = last folded
   step + 1.
5. Renders with `renderRestMirror`, always with the rest-end alert variant,
   because no screen is open. The new payload carries the folded `view`.
6. **Looks up the port again after rendering.** If an owner has appeared in
   the meantime, it sends a wake-up, and the owner corrects the mirror with a
   forced re-render.

### D4. Intent journal

- **Location.** `notificationJournalDirectory(filesDirectory)` returns a
  sibling of the support root:
  `<parent of filesDirectory>/.<applicationId>-notification-intents/`.
  - This follows the `EntryJournal` precedent
    (`lib/identity/entry_journal.dart:47-50`).
  - The root inventories in `AlkionProfile`
    (`lib/identity/alkion_profile.dart:107-116,182-191,276-290`) and in
    `RestoreService` (`lib/recovery/restore.dart:359-394,438-460`) never see
    this directory. Fresh start, first-start restore and "bytes without
    identity" detection are therefore unchanged, and a test proves this with a
    populated journal.
- **Paths.** The background passes path_provider's files directory, which
  starts `/data/user/0`. The owner passes its checked, canonical root. The two
  strings can differ but name the same directory, so the owner compares with
  `FileSystemEntity.identical`. A host test covers a symlinked alias, and OG4
  checks it on the device.
- **Entry.** Named `<tapped_at µs>-<intent_id>.json`. It is written as
  `.partial`, flushed, renamed, and then the directory is flushed with
  `flushDirectory`. Content:
  `{format: 'alkion-notification-intent/1', intent_id, action_id, kind, tapped_at, payload}`.
- **`tapped_at`** is the time the background handler ran, not the physical
  tap. It is used for the "rest still running" check, and to break ties
  between arrivals in one step.
- **Bounds.** At most 64 committed entries of 8 KiB each. Beyond that, the
  background refuses and doesn't render.
- **Undecodable entries.** The owner copies their exact bytes into `reviews`
  (category `notification_intent_unreadable`, with an `rv-`-style
  deterministic ID), then deletes the file. If that write fails, the file stays
  and counts toward the cap.
- `.partial` files older than 60 s are removed.
- The journal is excluded from backups, like OS notifications
  ([backup](../alkion/backup.md)).

### D5. Owner consumption and the token rule

**One token rule.** A refresh reads the receipt and the current SQL rest
(`draftId`, `restStart`, `restTotal`):

- If the receipt is `issued` and the current rest equals its issued basis,
  reuse the token with `step = 1`.
- If the receipt is `consumed` and the current rest equals its post-step rest,
  reuse the token with `step = consumed_step + 1`.
- Otherwise, issue a fresh token: receipt `issued`, basis = the current rest,
  `step = 1`.

Timer revisions play no part. Every draft save rewrites the timer row
(`session_writer.dart:566-576`), so unrelated autosaves would otherwise stale
the visible token. **The plan's storage task removes the existing revision
checks** in `notification_action.dart`:

- the reuse test at `:113`;
- the consumed-branch `timer['revision'] == action.timerRevision + 1` at `:182`;
- the issued-branch `timer['revision'] != action.timerRevision` at `:190`;
- `expectedRevision: action.timerRevision` at `:209`, which now reads the
  current timer revision inside the transaction.

The token's `timer_revision` field stays as issue-time evidence. It is still
decoded, but never compared.

Each intent gets one write transaction with `expected: token`. It checks, as
today, the application, profile and generation, the draft ID, that the token
equals the receipt's token, and that the draft and timer are both active with
agreeing rests. Then:

- **Basis.** The current SQL rest must equal the step's basis: the issued
  basis for step 1, or the receipt's post-step rest for a later step. Any
  in-app rest change wins, and the tap is refused `basis_changed`.

  With the workout screen open, the screen's ticker stops the rest at zero
  (`session/active_session_screen.dart:106-107`). So a +30s still in the
  journal about 1 s before expiry is refused `basis_changed`.
- **Step.**
  - `step == consumed_step + 1`: apply.
  - `step ≤ consumed_step` and `intent_id == last_intent_id`: `duplicate`.
  - `step ≤ consumed_step` with another intent: `refused(conflict)`. This is
    a second tap before the visible update.
  - `step > consumed_step + 1`: `refused(gap)`.
  - A legacy `consumed` receipt counts as step 1.
- **Time.** `tapped_at` must be at or after `rest_start`, and no later than
  now + 2 min. The rest must still be running at `tapped_at`.
- **+30s.** `restTotal += 30` in both the draft and the timer.
- **Skip.** `restStart = null`, `restTotal = 0` and
  `restEndedAt = min(tapped_at, due)` in both. That is `stopRest`
  (`active_session_controller.dart:1494`) evaluated at the tap time.
  `CommittedRestChange` gains a nullable `restStart` and `restEndedAt`, and
  `_adoptNotificationRest` takes `endedAt` from the commit.
- **Receipt.** It becomes `consumed` with
  `{action, basis, consumed_step, last_intent_id, kind, rest_start, rest_total, rest_ended_at, draft_revision}`.
- **Outcomes.** `applied`, `duplicate`, or `refused(reason)`, where the reason
  is one of `stale_generation`, `foreign`, `draft_not_active` (including a
  draft just retired by the unreadable-workout-state quarantine),
  `token_superseded`, `basis_changed`, `conflict`, `gap`, `late` or `clock`.
  Only `applied` writes.
- **No outbox.** No domain row, operation or outbox entry is written. The
  receipt stays one `local_state` row, and the schema doesn't change.

**Drain order** is by token, then step, then (`tapped_at`, `intent_id`). An
entry is deleted only after its outcome is durable. A delete that fails with
ENOENT counts as success.

### D6. Owner drains, open order, ghosts and close

- **Serialised.** One drain tail in `SessionManager` runs every drain in
  turn: wake-up, resume, flush and open.
- **Open sequence:**
  1. Open the store, settings and catalog.
  2. Run the unreadable-workout-state quarantine.
  3. Construct `SessionManager`.
  4. **Register the port**, after removing any stale mapping. The port is in
     *opening* mode: a wake-up only sets `drainOwed = true`.
  5. Drain #1, SQL only.
  6. Run `resumeFromDraft`, `loadLastFinished` and `init`.
  7. Build the history mappings, then run `initializeNotifications`.
  8. Drain #2, through the controller if one exists.
  9. If **no workout is active**, cancel mirror ID 4101 and its scheduled
     rest-end alert. The rest alerts plan's alert reuses ID 4101, and the
     plugin's `cancel(id)` also cancels the alarm. Otherwise, refresh with
     `force`, which clears `_lastShown`.
  10. **Release the owed drain.** While `drainOwed` is set, clear it, run one
      more drain and repeat step 9. Then switch the port to *immediate* mode,
      where every later wake-up queues a drain on the tail directly.
- **Failed open.** If `AlkionRuntime.open` throws after step 4, its catch
  **unregisters the port** before `store.close()` (`lib/main.dart:181-184`).
  This leaves no owner port behind a launch-failure screen, so the background
  keeps rendering provisionally.
- **Refresh drains first.** A refresh then applies the token rule (D5). A
  fresh token is issued only when the SQL rest differs from the receipt's
  basis or post-step rest. Any entries still journaled for the old token
  could then no longer apply (`basis_changed`).
- **With a live controller:**
  1. Settle owed saves. They don't refuse an intent, because consumption
     judges by rest fields.
  2. Consume.
  3. Adopt the committed rest with the queued edits.
  4. Keep an uncertain COMMIT in `DraftStore.pendingNotificationAction` until
     the receipt answers it.

  While `callbacksFrozen` is set, entries wait. Every decided intent ends
  with a forced refresh.
- **Rest reconciliation is bounded.** On `resumed`, and in `init`, a drain
  runs first. `_reconcileCommittedRest` and `_reconcileRest` skip stopping an
  elapsed rest **only while that drain is in flight**. Once the drain has
  finished, whether it succeeded or failed and whatever entries remain,
  reconciliation runs normally. A permanently stuck entry therefore can't
  keep an elapsed rest running.
- **Robustness.** Drain errors never fail launch or crash the app. This
  covers:
  - I/O errors and a missing directory;
  - non-file or symlink entries, which are ignored and never followed;
  - a failed copy of an undecodable entry;
  - store errors.

  The entry stays, and the error goes to the storage banner from the storage
  banner plan.
- **Close and restore.** `close()` first puts the port into *closing* mode,
  in which wake-ups are ignored. The port stays registered until
  `closeNotifications` has cancelled the mirror and the store has closed.
  While the port exists, the background never renders. After the port is
  unregistered, the background may render provisionally. The next open's
  drain then refuses old-generation entries, and step 9 cancels or refreshes
  the mirror.

**Markers.** With `ALKION_NOTIFICATION_TRACE` compiled in (private Dev APK
only), `print` writes markers without names:

- background: `alkion-notif received|journaled|rendered|woke <intent-id-prefix> <step> <kind>`;
- owner: `alkion-notif applied|refused <reason>|duplicate <intent-id-prefix> <step>`,
  `alkion-notif re-rendered <token-prefix> <step>` after every owner render,
  and `alkion-notif ghost-cancelled`.

### D7. "Count each visible tap" in practice

Constraint 1 means a tap always carries the latest posted payload. Under the
token rule, the notification carries the same token and the next step once a
step is applied, whether the owner or the background re-renders it.

- Taps made before the notification visibly updates share one step. The
  first applies, and the others are `conflict` (or a `duplicate` on
  redelivery).
- A tap after the update carries the next step, so it counts again. A fresh
  token appears only after an in-app rest change.

## Boundaries

- **Single owner.** Only the main isolate's `LocalStore` reads or writes the
  profile. The background touches only the sibling journal and the plugin.
- **Outbox and data separation** ([AGENTS.md](../../AGENTS.md)). No domain
  action is written. Uncertain intent is kept until SQL decides it.
  Undecodable intent is copied into `reviews` before it is removed.
- **Offline.** No connection I/O, no new permission and no foreground service.
- **Tests and claims** ([app/AGENTS.md](../../app/AGENTS.md)). Consumption is
  tested on real SQLite. Host results never claim device qualification.

## Non-goals

Other actions, a Profile notification switch, native notification posting
(fallback only), changing the in-app +30s/Skip chips, and recording refusals
as reviews.

## Acceptance

- **A1 (foreground).** With the shade pulled down, +30s and Skip change the
  live rest at once, and no route is pushed.
- **A2 (backgrounded).** The owner applies the tap and re-renders without the
  app coming forward. On return, the screen shows the same rest.
- **A3 (killed).** The provisional mirror shows the change, and the rest-end
  alert moves or is cancelled. The next launch applies the tap before resume,
  empties the journal and re-renders with the same token and the next step.
- **A4 (killed chain, end to end).** +30s, +30s, Skip go through the real
  handler with captured payloads, followed by a real-runtime launch. The SQL
  state equals all three applied in order.
- **A5 (Skip semantics).** `restEndedAt` is the tap time, capped at the due
  time. Elapsed mode shows no actions, and no alert fires.
- **A6 (visible taps).** Taps before the notification visibly updates count
  once, in every app state. A tap after the update counts again. There is no
  time debounce.
- **A7 (concurrent and mixed).** Two deliveries are serialised. With mixed
  +30s and Skip at one step, only the first arrival applies, and the second is
  `refused(conflict)`. The provisional mirror equals the fold. A redelivered
  entry is a `duplicate`.
- **A8 (token rule).**
  - An unrelated autosave keeps the visible token valid.
  - An in-app rest change, a finish, a discard or a restore makes a pending
    tap `refused`, and the mirror re-renders from SQL.
  - With the screen open, a +30s pending as the ticker stops the rest at zero
    is refused `basis_changed`.
  - The removed revision checks are covered by tests that would fail if those
    checks returned.
- **A9 (late or odd clock).**
  - A +30s after the rest end is refused, and a Skip after it is a no-op.
  - A tap time before rest start, or more than 2 min in the future, is
    refused.
- **A10 (crash, background).** A kill after the rename and before the render
  is applied once by the next drain. A kill before the rename leaves no entry
  and no render.
- **A11 (crash, owner).** A kill inside the consume transaction applies
  nothing and keeps the entry, and the next drain applies it. A kill after
  COMMIT and before the delete is seen as a duplicate and deleted. ENOENT on
  delete counts as success.
- **A12 (uncertain COMMIT).** An injected COMMIT failure keeps both the entry
  and the pending action. Reconciling by receipt never applies a tap twice.
- **A13 (tap during open).** A real-runtime test journals a tap at each of
  these points:
  - after quarantine;
  - between drain #1 and resume;
  - during `initializeNotifications`;
  - during drain #2;
  - during the step-9 refresh.

  Each tap is applied exactly once, the port reaches *immediate* mode, and the
  final mirror carries the applied rest.
- **A14 (failed open).** An injected failure after port registration leaves
  no port registered and the store closed. A later background tap renders
  provisionally.
- **A15 (ghosts).** A pending provisional mirror is cancelled at the next
  open, alert included, in each of these cases:
  - the unreadable-workout-state quarantine retires the draft;
  - a restore selects a generation with no workout;
  - an old-generation intent is refused.
- **A16 (close).** During `close()` the port stays registered in *closing*
  mode, the background doesn't render, and the mirror stays cancelled.
- **A17 (rest reconciliation).** On `resumed` with a journaled +30s, the rest
  is extended, not stopped. With an entry that can't be decided, an elapsed
  rest is still stopped once the drain finishes.
- **A18 (legacy action).** A bare-payload foreground response with
  `<prefix>add_30s` applies once and pushes no route. A foreground response
  with an unknown action ID is ignored.
- **A19 (negative input).**
  - An unknown action ID, or an oversize or undecodable payload, causes no
    write and no render.
  - An undecodable entry is copied byte-identical into `reviews`, then
    removed.
  - When the journal is full, the background refuses the tap.
  - Directory, symlink and I/O faults never fail launch.
- **A20 (isolation).**
  - The import closure of the background handler contains no store code.
  - The handler works while a real store holds the owner lock. It never calls
    `initialize` and never requests permission.
  - Intents for another application, profile or generation are refused.
  - A populated journal doesn't change the fresh-start or restore inventory
    checks.
- **A21 (envelope).**
  - Legacy `/1` body-tap payloads still open the workout.
  - The 4096-byte UTF-8 boundary holds for long multibyte names in de, es and
    it, and also for emoji. The test sits exactly at the boundary.
  - Action order is +30s first and Skip second in every render.
  - Both engines resolve the journal directory through the one shared
    function.
- **A22 (port).** A stale port with no listener leaves the entry for the next
  drain, with no render, which is the honest feedback.
- **A23 (backup and restore).** A flush drains before backup, so the backup
  holds the applied rest and no journal. After a restore, old-generation
  entries are refused and removed.
- **A24 (docs).** The docs record the design:
  - the notification doc comments and the manifest comment;
  - `docs/alkion/recovery.md`, replacing the "background +30s handler" wording;
  - `development.md`, `acceptance.md` and `android-smoke.md`.
- **A25 (checks).** `make -C app analyze` and the full suite pass, apart from
  the three named inherited failures.
- **Device (the plan's owner gates OG3 and OG4).**
  - Latency is measured from the **physical tap**, with "show taps" enabled and
    `adb shell screenrecord`, to the frame where the notification visibly
    changes. The `received` marker is the earliest point inside the app, and is
    reported alongside.
  - The bar is decided from the markers listed in D6.
