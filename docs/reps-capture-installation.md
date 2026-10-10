# Reps capture installation matrix

This page says which installations can reach a capture bridge and on what
evidence. Each row is one exact installation profile. It has one of three
statuses:

- **qualified**: every piece of evidence its access path needs was observed
  and passed;
- **pending**: the path is valid but evidence is missing, unrun or
  incomplete;
- **unsupported**: no access path exists, or evidence failed.

Commands that were not executed are marked **UNRUN**. A missing row means
unsupported.

Design authority: the Hub branch `docs/migration-designs` at `1dd0cec`,
section "Installation, signing and release qualification" of
`2026-10-09-reps-capture-and-installation-design.md`. The capture producer's
own evidence is in [reps-capture-qualification.md](reps-capture-qualification.md).

Nothing here authorizes any of these steps:

- installing on, or reading from, a real device;
- building with the real signing key;
- a version bump, a tag or a workflow dispatch;
- distribution, a real capture or retirement of the original app.

Each needs its own explicit direction from the owner. **Real installed-device
acceptance in particular requires explicit owner direction**; until then
every Android row stays pending or unsupported. `cutover_ready` is false
everywhere.

## Matrix

Checked on 2026-10-10 with `scripts/check-capture-installation.py`.

| Candidate | Original (observed) | Bridge | Evidence | Status |
| --- | --- | --- | --- | --- |
| Linux development fixture | `io.github.psychonaut0.workout_tracker`, channel `development`, `0.18.1+37`, debug bundle x86_64, profile `reps-0.18.1+37/linux/powersync-2.2.0/core-0.4.13` | same build, source `583bddbf3c308e1b469bf8ee5fe26fe159823ebb`; no signer, no APK | `acceptance.json` sha256 `5aed6bb5…4ce8`: recovery (54 SIGKILLed boundaries), storage, capture `91a37629…eca70`, receiving `91a37629…eca70` | **qualified**, development loop only. This is not a public Linux distribution. |
| Existing release-signed Android Reps | not observed: installed versionCode, signer, API and ABI unknown | none: no capture-capable Android build exists (the plugin is excluded from Android builds) | none | **unsupported** |
| Existing preview installation | not observed | none | none | **unsupported**. Even with a bridge, a preview build number above the bridge stays unsupported, whatever the signer. |
| Debug/local Android build | not observed | none | none | **unsupported**. A debug signer never upgrades to a release-signed bridge. |
| Older/different package id | not observed; the runbook only mentions an earlier "Workout Tracker" id | none | no transfer path proven | **unsupported** |
| Additional versions or platforms | none | none | none | **unsupported** |

Linux row details:

- The evidence was produced at `583bddb` with
  `make -C app capture-recovery CAPTURE_DEVICE=linux
  CAPTURE_OUTPUT=/tmp/reps-capture-installation` (4/4 **PASS**, about 2 min).
- `python3 -I scripts/verify-capture-rehearsal.py /tmp/claude-1000/hub-b50c8e5
  /tmp/reps-capture-installation` then passed 95 checks.
- The checker was run with
  `python3 -I scripts/check-capture-installation.py --acceptance
  /tmp/reps-capture-installation/acceptance.json <row>.json` and printed
  `qualified`, `access_path: development_loop`.
- The installation commit changes no Dart or native source and no app
  test, so the same runtime applies at that commit.
- The schema field is the registered fingerprint
  (`physical=f6c62733…;public=077764b3…`). The checker cannot observe it.
  Capture opening refuses any other schema, so a certified capture implies
  it matched.

Without `--acceptance`, the same row is **pending**: capture, receiving,
recovery and storage are missing.

An Android row can become **pending** only after all of these:

- the Android capture plugin is enabled, compiled and qualified on an SDK
  host (it is excluded today);
- a bridge APK is built with `make -C app build-capture-apk-release` and its
  public metadata is recorded;
- the original installation's public metadata is observed, with owner
  direction.

It can become **qualified** only with the full evidence set below, from a
disposable signed in-place upgrade.

## Checker

`scripts/check-capture-installation.py` holds
`check_capture_installation(original, bridge, evidence) -> dict`. It uses
only the Python standard library. Its tests:

```bash
python3 -m unittest discover -s tests -p test_capture_installation.py
```

The command line is
`python3 -I scripts/check-capture-installation.py [--acceptance FILE] ROW.json`,
where `ROW.json` is `{"original": …, "bridge": …, "evidence": …}`. It prints
the result as JSON. The exit code is 0 for qualified, 3 for pending, 4 for
unsupported and 2 for unreadable input.

Inputs are public metadata only:

- **original**: `platform` (`android` or `linux`), `package`, `channel`
  (`release`, `preview`, `debug`, `local_release`; Linux `development`),
  `version_name`, `version_code` (the actual installed one; the pubspec
  `+37` is no proof, since CI overrides it), `signer_sha256` (lowercase
  SHA-256 of the public signing certificate), `android_api`, `abi` (Linux:
  `linux_build`, no signer), and `profile` `{sdk_version, core_version,
  schema}`.
- **bridge**: the same identity fields with channel `capture_bridge` (Linux
  `development`), plus `min_sdk`, `apk_sha256` and `source_revision` (git
  SHA).
- **evidence**: entries `upgrade`, `storage`, `capture`, `rollback`,
  `receiving` (and `release_ordering`, `transfer`, `recovery` where
  applicable). Each is `{"result": "pass" | "fail" | …, "reference": …}`
  plus fields per entry:
  - `storage.retained` must list `sql`, `upload_queue`, `pre_flush`,
    `malformed`, `recovery` and `preferences`;
  - `capture` needs `manifest_sha256` and, for an upgrade, `first_launch`
    and `before_destructive_loaders`. An optional `runtime` must name the
    bridge's version, SDK and core;
  - `receiving.manifest_sha256` must equal the capture's;
  - `transfer` needs `source_package` and `manifest_sha256`.

Any input that names a signing or credential field (password, keystore,
store file, key alias, private key, secret, token, credential) is refused as
`private_material_rejected`, and its values are not echoed.

Rules:

| Situation | Status |
| --- | --- |
| Matching metadata, no or partial evidence | pending: matching metadata alone never qualifies |
| Unknown platform/channel, malformed package/signer/digest/revision/version, missing profile | unsupported |
| Existing channel (`release`, `preview`, `debug`, `local_release`) offered as the bridge | unsupported: existing channels never become a bridge |
| Same package, different signer (for example debug original, release bridge) | unsupported: never replace with a mismatched signer, never clear data |
| Same package, bridge versionCode not strictly higher (for example preview 500, bridge 38, same signer) | unsupported |
| Preview original below the bridge without `release_ordering` evidence | pending |
| Original API below the bridge's `min_sdk`; profile not exactly equal | unsupported |
| Different package, no proven `transfer` (pass, referenced, same source package, digest) | unsupported: the bridge's id cannot reach another package's stores |
| Different package with a proven transfer plus storage, capture, rollback, receiving | qualified (`access_path: transfer`) |
| Any required entry `fail`; capture after destructive loaders or not on first launch; receiving or transfer digest different; capture runtime from another build | unsupported |
| Same package and signer, admissible build, full upgrade/storage/capture/rollback/receiving set | qualified (`access_path: in_place_upgrade`) |
| Linux development channel with capture, storage, recovery, receiving | qualified (`access_path: development_loop`) |

`evidence_from_acceptance(acceptance)` turns a Linux `acceptance.json` from
`make -C app capture-recovery` into entries:

- `recovery`: the kill test passed and every interruption died by SIGKILL;
- `storage`: the kill, fault and race tests passed;
- `capture`: the certified `synthetic-capture` fixture, with the run's
  runtime;
- `receiving`: the exported tree's manifest digest.

A test that did not pass turns its entries into `fail`. An acceptance file
with `cutover_ready` other than false, or of another format, is refused. It
never yields `upgrade` or `rollback`, and a non-Linux run yields nothing.

## Signing guard

`app/android/app/build.gradle.kts` reads the Gradle property
`captureDistribution`. `make -C app build-capture-apk-release` runs
`ORG_GRADLE_PROJECT_captureDistribution=true fvm flutter build apk --release`.

| Property | `android/key.properties` | Release signing |
| --- | --- | --- |
| absent or `false` | present | release configuration (unchanged) |
| absent or `false` | absent | debug fallback (unchanged; contributors, PR CI) |
| `true` | present | release configuration only |
| `true` | absent | build fails during configuration, before any APK exists |
| any other value | either | build fails |

The guard only tests whether the signing file exists, the same test the
build already used to choose the fallback. It reads and prints no signing
value. Debug builds and every existing workflow do not set the property, so
they behave exactly as before. No workflow was edited or dispatched.

| Check | Result |
| --- | --- |
| Capture distribution without signing prerequisites fails before producing an APK; debug builds still usable | **UNRUN**. `make -C app build-capture-apk-release` exited 2 with `[!] No Android SDK found. Try setting the ANDROID_HOME environment variable.` Flutter stops before Gradle runs (`ANDROID_HOME` points at a directory that does not exist), and no `app/build/app/outputs` was created. `make -C app build-apk` failed the same way. The Gradle script has never been compiled. |
| `apksigner verify --print-certs APK`, `aapt dump badging APK`, APK SHA-256 | **UNRUN**: no APK, `apksigner`/`aapt` not installed |
| Installed original metadata, disposable signed in-place upgrade, first launch capture, storage retention, rollback, receiving | **UNRUN**: needs explicit owner direction and an SDK/device host |

## Runbook

Run everything from the repository root; never `cd`. Steps 1 and 2 are
synthetic or local. Steps 3 to 5 need explicit owner direction first.

1. **Synthetic Linux evidence.** Use a fresh output directory each time.

   ```bash
   make -C app capture-recovery CAPTURE_DEVICE=linux CAPTURE_OUTPUT=/tmp/reps-capture-<name>
   python3 -I scripts/verify-capture-rehearsal.py <Hub snapshot> /tmp/reps-capture-<name>
   python3 -I scripts/check-capture-installation.py --acceptance /tmp/reps-capture-<name>/acceptance.json <row>.json
   ```

   Keep `<row>.json` outside the repository.

2. **Guard check on an SDK host without `key.properties`.** Use a host or
   worktree that never had the file. Never move or rename a real one.

   ```bash
   make -C app clean
   make -C app build-capture-apk-release   # must fail: "Capture distribution requires the release signing configuration"
   test ! -e app/build/app/outputs/flutter-apk/app-release.apk
   make -C app build-apk                   # must still succeed (debug)
   ```

3. **Bridge build and public metadata** (signing key host; owner direction).
   Run `make -C app build-capture-apk-release`, then record the APK SHA-256,
   `apksigner verify --print-certs`, `aapt dump badging` and
   `git rev-parse HEAD` as in `app/android/RELEASE.md`. These go into the
   row's `bridge`.

4. **Original installation public metadata** (device; owner direction).
   Read only public package metadata:

   ```bash
   adb shell dumpsys package io.github.psychonaut0.reps | grep -E "versionCode|versionName"
   adb shell getprop ro.build.version.sdk
   adb shell getprop ro.product.cpu.abi
   adb shell pm path io.github.psychonaut0.reps
   adb pull <base.apk path> /tmp/reps-installed-base.apk
   "$ANDROID_HOME"/build-tools/<v>/apksigner verify --print-certs /tmp/reps-installed-base.apk
   ```

   No app data, backup, `run-as` or secure storage is touched.

5. **Disposable signed in-place upgrade** (disposable device or emulator,
   synthetic data; owner direction).
   - Install the original build and seed synthetic stores: SQL, upload
     queue, a pre-flush draft, a malformed file, a recovery journal and
     preferences.
   - Then `adb install -r <bridge.apk>`.
   - Launch once. The capture must run on first launch before any
     destructive loader. Record storage retention, the manifest digest and
     receiving verification of the exported capture.
   - Record rollback: a refused or failed bridge leaves the original
     installed and operational.
   - Repeat for the preview, debug and older-id variants as applicable.

If an install is refused (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`,
`INSTALL_FAILED_VERSION_DOWNGRADE`) or storage access fails, the row is
unsupported. Keep the original app installed and use only a separately
proven old-producer/transfer path. Never uninstall, clear data, log out,
`adb install -d` or downgrade as a workaround. Fresh install plus server sync
cannot recover unsynced queue entries or drafts.
