# Reps — Android release runbook

The app id is `io.github.psychonaut0.reps`. Release APKs are **signed** and published
to **GitHub Releases** by `.github/workflows/android-release.yml` on every `v*` tag.
`make -C app build-apk` stays a *debug* build for local iteration; signed builds use
`key.properties` (below).

## One-time setup

### 1. Generate the release keystore (keep it OUT of git, BACK IT UP)
```bash
mkdir -p ~/.android-keystores
keytool -genkeypair \
  -keystore ~/.android-keystores/reps-release.jks \
  -alias reps -keyalg RSA -keysize 2048 -validity 10000 -storetype JKS \
  -dname "CN=Reps, OU=psychonaut0, O=psychonaut0, C=IT" \
  -storepass "<PASSWORD>" -keypass "<PASSWORD>"
```
> ⚠️ **Back up the keystore + password** (password manager + offline copy). If you lose
> them you can never ship an in-place update again — only a fresh-id reinstall.

### 2. Local signing (`app/android/key.properties`, gitignored)
```properties
storeFile=/home/<you>/.android-keystores/reps-release.jks
storePassword=<PASSWORD>
keyAlias=reps
keyPassword=<PASSWORD>
```
Then `make -C app build-apk-release` builds a locally-signed release APK
(`app/build/app/outputs/flutter-apk/app-release.apk`). Verify the signer:
```bash
$ANDROID_HOME/build-tools/35.0.0/apksigner verify --print-certs \
  app/build/app/outputs/flutter-apk/app-release.apk | grep 'certificate DN'
# -> Signer #1 certificate DN: CN=Reps, OU=psychonaut0, ...
```

### 3. CI signing — GitHub Actions secrets (repo → Settings → Secrets → Actions)
The workflow decodes the keystore from `KEYSTORE_BASE64` and signs with it. Set the four
secrets once (via `gh`, needs a token with repo-secrets scope):
```bash
gh secret set KEYSTORE_BASE64 < <(base64 -w0 ~/.android-keystores/reps-release.jks)
gh secret set KEYSTORE_PASSWORD --body "<PASSWORD>"
gh secret set KEY_ALIAS        --body "reps"
gh secret set KEY_PASSWORD     --body "<PASSWORD>"
gh secret list   # confirm all four
```

## Cutting a release
```bash
git tag v1.2.3        # versionName = 1.2.3 (build number = the CI run number)
git push origin v1.2.3
```
CI builds + signs + publishes `reps-v1.2.3.apk` to the GitHub Release for that tag.
Download it to the phone and install (it's a new app id vs the old "Workout Tracker",
so it installs alongside until you uninstall the old one). On first run, set the server
URL to `http://workout.lan` (Tailscale must be on) and sign in — data syncs from the homelab.

## Preview builds (an unmerged branch on the phone)
`.github/workflows/android-preview.yml` builds a release-signed APK from any branch and
uploads it as a run artifact (no tag, no Release). Same key as releases, so it upgrades
in place and keeps the phone's data:
```bash
adb shell dumpsys package io.github.psychonaut0.reps | grep versionCode   # installed, e.g. 36
gh workflow run android-preview.yml --ref <branch> -f build_number=36     # >= installed, <= next release run number
gh run download <run-id> -n reps-preview-apk -D /tmp/preview
adb install -r /tmp/preview/app-release.apk
```
The next real release (a higher run number) replaces the preview through the normal OTA update.

## Capture-bridge builds (signing guard)
`make -C app build-capture-apk-release` builds a release APK meant to become a
capture bridge. It sets the Gradle property `captureDistribution=true`
(`ORG_GRADLE_PROJECT_captureDistribution=true`), which disables the
debug-signing fallback: without `key.properties` the build fails during Gradle
configuration, before any APK is produced. The guard only tests that the file
exists; it never reads or prints a signing value. Without the property every
other build (`build-apk`, `build-apk-release`, the release and preview
workflows) behaves exactly as before, and none of them is a capture bridge.

Building it bumps no version and tags, dispatches, installs or publishes
nothing; each of those needs its own explicit direction. Today the APK is
**not** capture-capable on Android: the capture plugin is excluded from Android
builds until it is compiled and qualified on an SDK host.

Record the bridge's public metadata (repo root, `<v>` = installed build-tools):
```bash
sha256sum app/build/app/outputs/flutter-apk/app-release.apk
"$ANDROID_HOME"/build-tools/<v>/apksigner verify --print-certs \
  app/build/app/outputs/flutter-apk/app-release.apk      # Signer #1 certificate SHA-256 digest
"$ANDROID_HOME"/build-tools/<v>/aapt dump badging \
  app/build/app/outputs/flutter-apk/app-release.apk | grep -E "^(package|sdkVersion|native-code)"
git rev-parse HEAD
```
A bridge is qualified per installation in `docs/reps-capture-installation.md`
with `scripts/check-capture-installation.py`; matching metadata alone never
qualifies it. A preview installation whose build number is above the bridge
cannot take it, even with the same signer.

## Notes
- `key.properties`, `*.jks`, `*.keystore` are gitignored — never commit them.
- Without `key.properties` (e.g. a contributor / PR CI), `flutter build apk --release`
  falls back to debug signing so it still builds; only the `v*`-tag release path on the
  main repo signs with the real key (it has the secrets).
  `make -C app build-capture-apk-release` is the exception: it fails instead.
- Distribution is GitHub Releases only; a LAN mirror (ct-mgmt) is deferred.
