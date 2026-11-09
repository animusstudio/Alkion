# Rest-end alert, notification body, glyph and permission explainer

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09;
implemented 2026-11-09, awaiting review.
Parent: [development](../alkion/development.md).
Baseline: `458aac6`; branch `feat/rest-alerts-and-notifications-20261108`.
Audit items 6.3, 6.5, 6.6, the next-set notification body, and the dead English
`notificationPayloadFor` bodies.
Order: after [error messages and toasts](2026-11-08-error-messages-and-toasts.md)
(its toast edits the `main.dart` limitation block, which this plan leaves alone)
and after [live workout flow](2026-11-08-live-workout-flow.md). It runs
**before** the background-notification-actions full-lane plan, which replaces
the +30s action wiring; this plan does not touch that wiring.

## Outcome and evidence

- **Silent rest end (6.3).** Rest haptics come only from the open workout screen
  (`session/active_session_screen.dart:77-153`, `_handleRestHaptics`). The
  channel is `Importance.low`, `playSound: false`
  (`session/workout_notification.dart:95,163`). The scheduled rest-end
  notification (`zonedSchedule`, `:227`) replaces the mirror silently:
  `buildWorkoutAndroidDetails` sets `onlyAlertOnce` and low priority (`:95-100`). With the phone locked
  the rest ends with no vibration or heads-up.
- **Nothing says what is next.** The body is a fixed "Rest" or
  "Workout in progress" (`_notifStrings`, `:18-38`), though
  `ActiveSessionController.nextPendingSet` knows the next set
  (`session/active_session_controller.dart:1592`).
- **Wrong small icon (6.5).** `AndroidInitializationSettings('@mipmap/ic_launcher')`
  (`workout_notification.dart:151`) shows a solid blob in the status bar. No
  `ic_stat_*` exists in `android/app/src/main/res`; only per-density
  `ic_launcher_monochrome.png` (adaptive-icon padding).
- **Permission prompt mid-workout (6.6).** The first `showFor` calls
  `requestNotificationsPermission()` once per runtime (`:199-209`), right after
  the first set or start, with no explanation. Denial only sets the `denied`
  limitation, shown as a toast with OK (`main.dart:697-712`).
- **Dead English bodies.** `notificationPayloadFor` (`:53-73`) returns 'Rest' and
  'Workout in progress'; `_show` ignores them (it uses `notifString`), and only
  `test/session/workout_notification_test.dart` reads them.

## Decisions

- **6.3 (owner decision).** A heads-up with **vibration and no sound**, on a
  dedicated channel `<prefix>rest_end` created at init with `Importance.high`,
  `playSound: false`, vibration on, named in all four languages. The user tunes
  it in Android settings; there is **no in-app switch**. The scheduled rest-end
  notification uses it with title "Rest finished" and the next set as body, and
  without `onlyAlertOnce`. It stays `ongoing` because it replaces the workout
  mirror (same id), so the elapsed chronometer continues.
- **No double buzz.** While the workout screen is open its haptics already fire
  (`SessionManager.screenOpen`). The alert variant is scheduled only when the
  screen is closed; a `screenOpen` change refreshes the schedule, and the
  refresh key includes that flag. The existing quiet details are used otherwise.
- **Exact-alarm fallback is unchanged.** Without exact-alarm permission the
  notification falls back to inexact scheduling and may be late. The
  inexact-alarm notice stays removed (owner decision, 2026-11-08).
- **Body.** "Next · <name>" where name is the catalog `displayLabel` or the
  exercise name; with no pending set, the workout name. No weights or reps, so no
  unit formatting is needed without a `BuildContext`. All new strings join
  `_notifStrings` for en, it, de, es.
- **6.5 (owner decision).** A monochrome 24 dp vector `drawable/ic_stat_alkion.xml`
  (white on transparent) drawn from the approved icon source in `assets/icon/`,
  referenced from the init settings. The owner reviews the glyph on the device.
- **6.6 (owner decision).** `showFor` never requests permission. At the first
  workout start (`shell/session_launcher.dart` `startSession`, after admission,
  before the workout screen is pushed) a one-line explainer dialog appears when
  notifications are off; accepting it triggers the system prompt. The "already
  explained" flag is one new optional preference key in the existing settings
  payload (absent means not yet explained). Declining shows the existing
  denied toast later; no nagging. "Open settings" is deferred.
- **Dead bodies.** Drop `body` from the `notificationPayloadFor` record and its
  tests.
- **Stored data.** The only stored change is that one optional preference key,
  written through the existing settings path. No schema, store or backup format
  change; no notification callback opens a profile or writes SQL.

## Non-goals

+30s and Skip without opening the app (full-lane background-actions plan);
an "Open settings" row or method channel; a Profile switch for the alert; sound;
weights in the body.

## Acceptance

- **A1.** With the app backgrounded or the phone locked, the end of a rest posts a
  heads-up with vibration and no sound. It can be silenced per channel in
  Android settings. With the workout screen open there is exactly one buzz.
- **A2.** The notification during rest and the one at rest end name the next
  exercise, localized in four languages; a finished plan shows the workout name.
- **A3.** The status bar shows a monochrome glyph, in the release build too.
- **A4.** The Android permission dialog never appears mid-workout: the explainer
  comes first, once, at the first workout start. Accepting prompts; declining
  starts the workout normally. A user who already granted permission sees nothing.
- **A5.** No English-only body strings remain in the payload mapping.
- **A6.** The +30s action behaves exactly as before. Arb parity and unused-key
  tests pass.

## Tasks

Implementers: Claude Opus `high`; reviewers: Sonnet `high`. **Serial**
(T1 to T3): they share `workout_notification.dart` and the ARB files.

| Task | Owns | Acceptance |
| --- | --- | --- |
| T1 Channel and alert | `session/workout_notification.dart` (channel, details builders, `showFor`, payload record, `_notifStrings`), `session/session_manager.dart` (`refreshNotifications`, `screenOpen` setter), its tests | A1, A2, A5, A6 |
| T2 Glyph | `android/app/src/main/res/drawable/ic_stat_alkion.xml`, the init settings string, a resource keep rule if release shrinking needs one | A3 |
| T3 Explainer | `shell/session_launcher.dart` (explainer call in `startSession` only), `settings/settings_service.dart` (one getter, setter and snapshot line), `showFor` permission removal, ARB | A4 |

Regions: `settings_service.dart` is also edited by the failed-saves plan (retry
and rest limits); T3 touches only the new key, and the later merge rebases.
`session_launcher.dart` is also touched by the live-workout plan (opening
motion); the hunks are disjoint.

## Checks

- Focused: `make -C app test TEST='--concurrency=2 test/session
  test/shell test/settings test/l10n test/main_routing_test.dart'`;
  `make -C app analyze`.
- Pure builder test for the rest-end details (importance, vibration, no sound,
  not `onlyAlertOnce`) beside `buildWorkoutAndroidDetails`. Fake plugin channel
  (`test/session/workout_notification_test.dart` pattern): the channel is
  created; the schedule uses it only when `screenOpen` is false; `showFor` makes
  no `requestNotificationsPermission` call. Unit test for the body choice. Widget
  test for the explainer (accept, decline, already granted). Real SQLite test
  that the new key round-trips and an absent key reads as unexplained.
- Integrated: full suite (three inherited `catalog_metric_controls_test.dart`
  failures named). Device check with a private Dev APK: lock the phone through
  a rest (heads-up, vibration, silent), toggle the channel in Android settings,
  glyph in the status bar, first-start explainer on a fresh install, merged
  manifest still has vibrate and notification permissions.

## Task state

Implemented 2026-11-09 on `63bda90` (main `458aac6` plus approved plans, P1
and P7), awaiting independent review. Code at `87ddb9a`; commits `1557cee`
(T1, plus the `showFor` permission removal and init icon string), `e90dd4e`
(T2), `816b9b3` (T3), `87ddb9a` (string test).

Stable identifiers, documented in `workout_notification.dart` for the
background-actions plan: notification id 4101 (mirror, countdown and rest-end
post), quiet channel `AlkionIdentity.notificationChannel`
(`<prefix>workout_session`, unchanged), alert channel
`AlkionIdentity.restEndChannel` (`<prefix>rest_end`, new), action
`AlkionIdentity.addRestAction` (`<prefix>add_30s`, unchanged).

- T1 — done. `init` creates the `rest_end` channel (`Importance.high`,
  `playSound: false`, `enableVibration: true`, localized name and description).
  `buildRestEndAndroidDetails` (high importance and priority, vibration, no
  sound, not `onlyAlertOnce`, ongoing, elapsed chronometer, no actions).
  `showFor(nextName:, alertAtRestEnd:)` schedules title "Rest finished" and
  body "Next · name" (workout name when nothing is pending) on that channel
  only when `alertAtRestEnd`; otherwise the previous quiet revert. The
  countdown body is "Next · name" (or "Rest"). The refresh key includes the
  alert flag and the next name. `SessionManager.restEndAlertWanted` is
  `!(screenOpen && appForeground)`; the `screenOpen` setter and lifecycle
  changes refresh. `notificationNextName` uses the set's catalog display
  label, then the block's, then the exercise name. `notificationPayloadFor`
  drops `body`. The +30s action chip, payload and response handling are
  untouched.
- T2 — done. `drawable/ic_stat_alkion.xml`: 24 dp white-on-transparent
  vector, the outer silhouette of `assets/icon/alkion-icon-1024.png` (glyphs
  merged, contour traced and simplified, 1 dp margin).
  `AndroidInitializationSettings('@drawable/ic_stat_alkion')`. `raw/keep.xml`
  keeps it, because the name is only referenced from Dart.
- T3 — done. `showFor` never requests permission; `notificationsEnabled()`
  and `requestPermission()` are on-demand. `shell/notification_explainer.dart`
  `explainNotificationsOnce` is called in `startSession` after admission and
  build, before `register` and the push (the P7 route animation is unchanged).
  `SettingsService.notificationsExplained` / `setNotificationsExplained()`
  with optional key `notifications_explained`, written only once true.
  4 ARB keys in en, it, de, es.

Deviations:

- "Screen open" means open **and** the app in the foreground. A phone locked
  on the workout screen keeps `screenOpen` true, so the screen check alone
  would never alert in the most common case. For the same reason the
  screen's 1 s ticker (`active_session_screen.dart`, outside the owned files)
  skips haptics and `stopRest` while the app is not resumed: a background
  buzz would double the alert, and a background `stopRest` refresh would
  replace (or pre-empt) it. The resume reconciliation stops the rest.
- During a rest with nothing pending the countdown body is "Rest", not the
  workout name, which is already the title; the rest-end post uses the
  workout name as planned.
- A failed write of the explained flag is ignored (the explainer may show
  once more); it never blocks the start.

Checks at `87ddb9a`:

- `make -C app analyze` → No issues found.
- `make -C app format` → 530 files, 0 changed.
- `make -C app test TEST='--concurrency=2 test/session test/shell
  test/settings test/l10n test/main_routing_test.dart'` → +550, all passed
  (includes `arb_parity_test` and `unused_keys_test`).
- New or changed tests: `workout_notification_test.dart` (pure rest-end
  builder; channel creation and glyph; alert channel scheduled only with
  `alertAtRestEnd`, quiet otherwise; next-name bodies; no
  `requestNotificationsPermission` from `showFor`; on-demand permission),
  `session_manager_test.dart` (alert flag follows `screenOpen` and lifecycle,
  next name, finished plan), `active_session_screen_test.dart` (backgrounded
  screen neither buzzes nor stops the rest; foreground still buzzes),
  `notification_explainer_test.dart` (continue, decline, already granted,
  unsupported), `session_launcher_explainer_test.dart` (explainer before
  register and push, decline starts normally, persisted, not asked again),
  `settings_test.dart` (real SQLite: absent key reads unexplained, round-trip,
  kept across later writes), `notif_strings_test.dart`, identity tests.
- `make -C app test TEST=--concurrency=2` → +3007 ~3 -3; the three failures
  are the known inherited `catalog_metric_controls_test.dart` cases
  (`duration_distance_optional`, `reps_distance_optional`,
  `reps_duration_optional_load` "mounts all required and optional controls
  unset").
- `aapt2 compile` and `aapt2 link` (build-tools 36.0.0, android-36) of the
  new drawable and keep rule in a scratch project → link OK.
- Not provable on the host: heads-up and vibration on the device, channel
  settings, the glyph's look, release shrinking. Device check open (lock
  through a rest, toggle the channel, status-bar glyph, first-start explainer
  on a fresh install, merged manifest permissions).

Review 2026-11-09: PASS-WITH-FINDINGS. Fixes in `be7bdc2`:

- Late buzz on resume: `_handleRestHaptics` consumes the guard without
  buzzing or announcing when the rest ended more than 2 s before the tick
  (`_lateRestEndSeconds`), so timers frozen while locked cannot buzz on
  unlock. Test: no tick while paused, resume 10 s past the end → no haptic,
  no announcement, rest stopped; verified to fail without the guard.
- The background branch of the ticker still calls `setState`, so a screen
  visible but not resumed (shade, split screen) keeps its timers moving; it
  only skips haptics and `stopRest`. Reasoned, not tested: host widget tests
  cannot advance the wall clock the timers read.
- `assets/icon/README.md` records `@drawable/ic_stat_alkion` and its
  derivation.
- Ghost cleanup (owner decision 2026-11-09): `initializeNotifications` cancels
  id 4101 (and with it the scheduled rest-end alarm) when, after the draft
  load and any launch response, no workout is active and no launch is
  running. Tests: none active → one cancel; active or resuming → none; real
  runtime with and without a stored draft.

Checks at `be7bdc2`: `make -C app analyze` → No issues found;
`make -C app format` → 530 files, 0 changed;
`make -C app test TEST='--concurrency=2 test/session test/shell test/settings
test/l10n test/main_routing_test.dart'` → +555, all passed. The full suite
was not rerun; no test outside `test/session` and `test/shell` injects a
notifier.

## Next

Independent review, then the device check. The background-actions plan
builds on the identifiers above.
