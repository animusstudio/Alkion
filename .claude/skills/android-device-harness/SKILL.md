---
name: android-device-harness
description: Change, test or run the Android synthetic device harness (app/tool/android_synthetic*, its fakes and synthetic test APKs) or diagnose an emulator campaign. Use before changing a harness route, a fake, or any adb/run-as interaction.
---

# Android device harness

The harness drives disposable emulators through Make routes
(`make -C app android-synthetic …`, plus the `-documents`, `-capabilities`,
`-restore` and `-publisher` targets). Host self-tests run against fakes;
only an emulator run proves device behavior.

## Device truth first

- Keep the bounded stdout, stderr and exit code of every device command as
  numbered evidence before checking it. A refusal must keep the first line of
  an exception, not only its tail.
- Fakes replay captured device output. When a check depends on output never
  captured on a device, cite the Android or adb source, or capture it with a
  read-only query, before a campaign depends on it.
- A program that mutates the device prints nothing on success; require empty
  stdout there and treat any `run-as: ` prefix as failure.

## Known API 36 behavior

| Fact | Consequence |
| --- | --- |
| App `cache/` is `02771`; new directories inherit setgid, files do not | a fresh `mkdir -m 700` reads back `2700` |
| Shell may change a component's enabled state only for a test-only package | the synthetic provider is `android:testOnly="true"` and installed with `install -t` |
| `pm enable` prints `Component {pkg/full.Class} new state: enabled` | `/.Cls` is expanded to the full class name |
| `adb exec-out` neither forwards stdin nor carries the remote exit status | owned reads and writes use binary `adb shell -T` |
| A successful `adb install` exits 0 with one stdout line `Success`; incremental installs add progress lines and may fall back to a streamed install after a `Failure` line | judge installs by exit code, the `Success` line and no `Failure` |
| adb scans emulator ports up to 5585 by default | higher ports work only by registering with a running adb server |
| API 36 synthetic captures (2026-10-20) show DocumentsUI can shift outer/card/toggle bounds off-display while child titles retain display coordinates; its observed List view control exposes all six fixture inputs | prefer list mode at the first usable OPEN root; re-observe unusable toggles boundedly, never guess a coordinate offset |
| API 36 synthetic rehearsal (2026-10-20): `am unfreeze --sticky PID` prints `Unfreezing process PACKAGE (PID) sticky=true` and preserves the provider PID | require the exact line and unchanged PID; namespace discovery and the full supported flow remain separate checks |
| API 36 synthetic hit/create rehearsal (2026-10-20), backed by the native DocumentsUI layout: the fixed SAVE footer receives its native centre even when directory-row accessibility bounds overlap it | only a SAVE-specific footer/list topology attestation may permit exact row overlap; unknown claimants and system bars still refuse |
| API 36 blank-AVD native rehearsal (2026-10-20): expand, repeated expand while open, collapse and expand again each return rc0 with empty streams; canonical shade focus is observed after expansion | retain each request result first; one caller-only reissue may establish readiness, while the unchanged observer must still prove SystemUI before any notification tap |
| API 36 native DocumentsUI captures (2026-10-20) persistently expose an invisible, nonclickable, unlabeled divider leaf with an empty inverted Rect below a hidden bottom row; Android Rect permits negative height for empty geometry | preserve raw nodes and bounds; admit only the attested bottom-divider geometry and ancestry, while visible, clickable, semantic and selected-target bounds remain strict |

Add a row, with its source, whenever a device run teaches a new fact.

## Campaigns

- Order: driver, updates, lifecycle, documents; a separate receiver emulator
  for the receiving restore. Each stage reads the previous stage's run receipt.
- Use exact emulator serials only; never address a physical device.
- Never write into an existing output directory or edit a receipt. A new
  attempt may reuse earlier stages only when their source and inputs are
  unchanged; the failed stage always reruns fresh.

## Public repository

Keep private paths, run ids, nonces, evidence hashes and local user names out
of committed files. Debug keys and campaign archives stay outside the repo.
