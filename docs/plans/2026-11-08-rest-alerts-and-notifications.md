# Rest-end alert, notification body, glyph and permission explainer

Date: 2026-11-08. Lane: **Standard**. Status: **Approved** by the owner on 2026-11-09.
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

None started.

## Next

Owner approval, then T1 to T3 after the live-workout plan merges.
