# Android checks after campaign retirement

The owner-approved source-cleanup amendment retired the bespoke Android campaign
framework on 2026-10-20. Its exact final pre-removal source is
[`5f90857687b3996f863a15f4a8dc86b703c818fc`](https://github.com/animusstudio/Alkion/tree/5f90857687b3996f863a15f4a8dc86b703c818fc).
Git history retains the orchestration, fakes, synthetic providers/neighbors,
observer instrumentation, five integration entrypoints and four importing protocol
or fixture tests. Dated [acceptance records](acceptance.md) remain history;
failed and unrun cases keep their original limits. No replacement framework is added.

Caller review found no campaign imports, defines or routes in the app runtime,
Android product source or app CI. Those entrypoints called product APIs; the
runtime did not call them. Product Documents/channel/directory/notification code
remains unchanged. Ordinary unit/widget/real SQLite tests and focused boundary
coverage remain, including `test/alkion/files/`, `test/alkion/identity/`,
`test/session/notification_action_test.dart` and `workout_notification_test.dart`.
The `tool/alkion_{driver_qualification,store_recovery,transfer_recovery,backup_recovery,verify_backup}.dart`
local proof tools and capture evidence checkers also remain. Only the retired
entrypoints needed the `integration_test` development dependency.

## Small manual APK smoke checklist

Use a named disposable emulator/profile or an explicitly authorized test device,
with synthetic workouts and files. Never use owner data or inherited signing keys.
Build the normal debug APK as described in the [app README](../../app/README.md).
Installation and interaction require an explicitly selected device; builds do
neither. Record the source revision, APK, Android version and observed results.

- Open the app; check the expected flavor/name and account-free startup.
- Start a synthetic workout, log a set, minimize and resume, then finish; reopen
  and confirm the saved history remains.
- Check rest notifications and their actions with permission granted; deny
  permission and confirm the app remains usable with an honest capability state.
- Save a synthetic backup through the system picker; cancel once without a change.
  Open/restore that backup into a disposable profile and check the visible result.
- Relaunch and confirm the selected profile and saved workout remain available.

Record failures and unrun steps as such. This smoke check does not qualify
power-loss durability, every provider, owner-device behavior, release signing,
live legacy migration or an Animus connection. Ordinary analysis, tests, format
and normal Linux/APK builds remain the automated development gates.
