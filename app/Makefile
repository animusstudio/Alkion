# Run from the repository root: make -C app <target>.
# Every Flutter/Dart execution resolves the preserved FVM 3.44.0 pin.
FLUTTER := fvm flutter
DART := fvm dart
ALKION_FLAVOR ?= dev
# Tool subprocesses must not refresh the reviewed Git index opportunistically.
export GIT_OPTIONAL_LOCKS := 0
override export ALKION_BACKUP := $(value ALKION_BACKUP)
override export ALKION_OUTPUT := $(value ALKION_OUTPUT)

.PHONY: help get get-online analyze test fmt format build build-apk build-apk-dev build-apk-supported alkion-driver-qualification alkion-store-recovery alkion-transfer-recovery alkion-backup-recovery run run-android build-apk-release build-capture-apk-release capture-integration capture-recovery capture-go-compat install doctor devices scaffold-linux scaffold-android clean
.PHONY: alkion-verify-backup build-apk-local-test-release
help:
	@echo "Alkion: get, analyze, test TEST=<path>, format, fmt FORMAT_FILES=<owned paths>, alkion-driver-qualification ALKION_OUTPUT=<fresh /tmp path>, alkion-transfer-recovery ALKION_OUTPUT=<fresh transfer-proof* path>, alkion-backup-recovery ALKION_OUTPUT=<fresh backup-proof* path>"
get:
	$(FLUTTER) pub get --offline --enforce-lockfile
# Explicit connected bootstrap for a fresh dependency cache; never upgrades.
get-online:
	$(FLUTTER) pub get --enforce-lockfile
analyze:
	$(FLUTTER) analyze --no-pub
test:
	$(FLUTTER) test --no-pub $(TEST)
format:
	$(DART) format --output=none --set-exit-if-changed .
fmt:
	@test -n "$(FORMAT_FILES)" || (echo 'Specify owned FORMAT_FILES; broad formatting is not authorized.' >&2; exit 2)
	$(DART) format $(FORMAT_FILES)
alkion-driver-qualification:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh owned /tmp directory.' >&2; exit 2)
	$(DART) run tool/alkion_driver_qualification.dart --output "$(ALKION_OUTPUT)"
alkion-store-recovery:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh owned /tmp directory.' >&2; exit 2)
	$(DART) run tool/alkion_store_recovery.dart --output "$(ALKION_OUTPUT)" $(ALKION_CASE_ARGS)
alkion-transfer-recovery:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh disposable transfer-proof* directory.' >&2; exit 2)
	$(DART) run tool/alkion_transfer_recovery.dart --output "$(ALKION_OUTPUT)"
alkion-backup-recovery:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set ALKION_OUTPUT to a fresh disposable backup-proof* directory.' >&2; exit 2)
	$(DART) run tool/alkion_backup_recovery.dart --output "$(ALKION_OUTPUT)"
alkion-verify-backup:
	@test -n "$${ALKION_BACKUP}" || (echo 'Set ALKION_BACKUP to the explicitly received backup file.' >&2; exit 2)
	@test -n "$${ALKION_OUTPUT}" || (echo 'Set ALKION_OUTPUT to a fresh inspection directory.' >&2; exit 2)
	$(DART) run tool/alkion_verify_backup.dart --backup "$${ALKION_BACKUP}" --output "$${ALKION_OUTPUT}"
alkion-driver-diagnose:
	@test -n "$(ALKION_OUTPUT)" || (echo 'Set fresh ALKION_OUTPUT.' >&2; exit 2)
	$(DART) run tool/alkion_driver_qualification.dart --diagnose "$(ALKION_OUTPUT)"
alkion-toolchain:
	$(FLUTTER) --version --machine
	$(DART) --version
# Local builds do not install or launch a device.
build:
	$(FLUTTER) build linux --no-pub
build-apk:
	@case "$(ALKION_FLAVOR)" in dev|supported) ;; *) echo 'ALKION_FLAVOR must be dev or supported.' >&2; exit 2 ;; esac
	$(FLUTTER) build apk --debug --no-pub --flavor "$(ALKION_FLAVOR)"
build-apk-dev:
	$(MAKE) build-apk ALKION_FLAVOR=dev
build-apk-supported:
	$(MAKE) build-apk ALKION_FLAVOR=supported
build-apk-local-test-release:
	@test "$${ALKION_LOCAL_RELEASE_TEST}" = 1 || (echo 'Set ALKION_LOCAL_RELEASE_TEST=1 for a private release-mode test APK.' >&2; exit 2)
	@test -n "$${ANDROID_USER_HOME}" || (echo 'Set ANDROID_USER_HOME to the existing disposable debug-key directory.' >&2; exit 2)
	$(FLUTTER) build apk --release --no-pub --flavor dev --target-platform android-arm64
# Implicit app/device/scaffold actions and retired capture/release routes
# remain unavailable; use explicit build and qualification routes above.
run run-android build-apk-release build-capture-apk-release capture-integration capture-recovery capture-go-compat install doctor devices scaffold-linux scaffold-android clean:
	@echo 'Unavailable in the current Alkion development phase.' >&2
	@exit 2

# Scoped localization generation through the same pinned FVM route.
gen-l10n:
	$(FLUTTER) gen-l10n

# Scoped dependency removal refresh; no upgrade or network resolution.
get-offline-update:
	$(FLUTTER) pub get --offline

# Explicit dependency changes only; normal bootstrap continues to enforce lock.
.PHONY: get-online-update analyze-animus
get-online-update:
	$(FLUTTER) pub get
ANIMUS_ANALYZE_FILES ?= lib/animus test/animus
analyze-animus:
	$(DART) analyze $(ANIMUS_ANALYZE_FILES)

# Real synthetic provider/API opt-in. Input contains only the public client
# configuration and a private test bridge; it never contains bearer credentials.
.PHONY: test-animus-live
test-animus-live:
	@test -n "$${ANIMUS_LIVE_FIXTURE}" && test -f "$${ANIMUS_LIVE_FIXTURE}" || (echo 'Set private ANIMUS_LIVE_FIXTURE to a disposable live fixture contract.' >&2; exit 2)
	$(FLUTTER) test --no-pub test/animus/live_connection_integration_test.dart --reporter expanded

# Standalone plugin checkpoint; never launches the normal app or opens a store.
.PHONY: build-animus-native-checkpoint-linux build-animus-native-checkpoint-android
build-animus-native-checkpoint-linux:
	@test -n "$(ANIMUS_NATIVE_CONFIG)" && test -f "$(ANIMUS_NATIVE_CONFIG)" || (echo 'Set ANIMUS_NATIVE_CONFIG to explicit disposable checkpoint JSON.' >&2; exit 2)
	$(FLUTTER) build linux --debug --no-pub --target tool/animus_native_checkpoint.dart --dart-define-from-file="$(ANIMUS_NATIVE_CONFIG)"
build-animus-native-checkpoint-android:
	@test -n "$(ANIMUS_NATIVE_CONFIG)" && test -f "$(ANIMUS_NATIVE_CONFIG)" || (echo 'Set ANIMUS_NATIVE_CONFIG to explicit disposable checkpoint JSON.' >&2; exit 2)
	@test -n "$${ANDROID_USER_HOME}" && test -f "$${ANDROID_USER_HOME}/debug.keystore" || (echo 'Set the existing disposable Android debug signer directory.' >&2; exit 2)
	ALKION_ANIMUS_NATIVE=1 ALKION_ANIMUS_LOOPBACK_HTTP=1 $(FLUTTER) build apk --debug --no-pub --flavor dev --target-platform android-x64 --target tool/animus_native_checkpoint.dart --dart-define-from-file="$(ANIMUS_NATIVE_CONFIG)"

# Public setup values only; never put credentials/tokens in a Dart define file.
.PHONY: build-animus build-apk-animus
ANIMUS_TARGET_PLATFORM ?= android-arm64
build-animus:
	@test -n "$(ANIMUS_CONFIG)" && test -f "$(ANIMUS_CONFIG)" || (echo 'Set ANIMUS_CONFIG to an explicit setup JSON file.' >&2; exit 2)
	$(FLUTTER) build linux --no-pub --dart-define-from-file="$(ANIMUS_CONFIG)"
build-apk-animus:
	@test -n "$(ANIMUS_CONFIG)" && test -f "$(ANIMUS_CONFIG)" || (echo 'Set ANIMUS_CONFIG to an explicit setup JSON file.' >&2; exit 2)
	@test -n "$${ANDROID_USER_HOME}" && test -f "$${ANDROID_USER_HOME}/debug.keystore" || (echo 'Set the existing disposable Android debug signer directory.' >&2; exit 2)
	@case "$(ANIMUS_LOOPBACK_HTTP)" in ''|0|1) ;; *) echo 'ANIMUS_LOOPBACK_HTTP must be 0 or 1.' >&2; exit 2 ;; esac
	@case "$(ANIMUS_TARGET_PLATFORM)" in android-arm64|android-x64) ;; *) echo 'ANIMUS_TARGET_PLATFORM must be android-arm64 or android-x64.' >&2; exit 2 ;; esac
	ALKION_ANIMUS_NATIVE=1 ALKION_ANIMUS_LOOPBACK_HTTP="$(ANIMUS_LOOPBACK_HTTP)" $(FLUTTER) build apk --debug --no-pub --flavor dev --target-platform "$(ANIMUS_TARGET_PLATFORM)" --dart-define-from-file="$(ANIMUS_CONFIG)"

# Isolated synthetic artwork checkpoint; does not open an Alkion store.
.PHONY: build-character-body-preview stage-character-body verify-character-body
build-character-body-preview:
	ALKION_BODY_PREVIEW_OFFLINE=1 $(FLUTTER) build apk --debug --no-pub --flavor dev --target lib/character_body_preview.dart
stage-character-body:
	@test -n "$(BODY_MALE_ASSETS)" -a -n "$(BODY_FEMALE_ASSETS)" || (echo 'Supply explicit private BODY_MALE_ASSETS and BODY_FEMALE_ASSETS.' >&2; exit 2)
	python3 tool/stage_character_body.py --male-assets "$(BODY_MALE_ASSETS)" --female-assets "$(BODY_FEMALE_ASSETS)"
verify-character-body:
	python3 tool/stage_character_body.py --verify

# Separate offline, synthetic ARM64 artifact. Build only; never install a device.
.PHONY: build-character-body-preview-isolated
build-character-body-preview-isolated:
	@test -n "$${ANDROID_USER_HOME}" && test -f "$${ANDROID_USER_HOME}/debug.keystore" || (echo 'Set ANDROID_USER_HOME to the existing disposable debug signer directory.' >&2; exit 2)
	@if test "$${ALKION_PRIVATE_BODY_ASSETS}" = 1; then $(MAKE) verify-character-body; fi
	ALKION_ISOLATED_BODY_PREVIEW=1 ALKION_BODY_PREVIEW_OFFLINE=1 $(FLUTTER) build apk --debug --no-pub --flavor dev --target-platform android-arm64 --target lib/character_body_preview.dart
	cp -- build/app/outputs/flutter-apk/app-dev-debug.apk build/app/outputs/flutter-apk/alkion-body-preview-isolated-debug.apk

# Rebuild approved brand PNGs, then the existing Android resource set.
.PHONY: brand-icons
brand-icons:
	node tool/generate_brand_assets.mjs
	$(DART) run flutter_launcher_icons -f flutter_launcher_icons.yaml

# Decorative first-use frames only; preserves launcher and master assets.
.PHONY: brand-entry-frames
brand-entry-frames:
	node tool/generate_entry_frames.mjs

# Private candidate input never becomes an ordinary Flutter asset or app build.
.PHONY: stage-catalog-trial verify-catalog-trial test-catalog-trial-staging build-catalog-trial
CATALOG_TRIAL_TARGET_PLATFORM ?= android-arm64
stage-catalog-trial:
	@test -n "$${CATALOG_TRIAL_INPUT}" && test -n "$${CATALOG_TRIAL_SHA256}" || (echo 'Set explicit CATALOG_TRIAL_INPUT and reviewed CATALOG_TRIAL_SHA256.' >&2; exit 2)
	python3 tool/stage_catalog_trial.py --input "$${CATALOG_TRIAL_INPUT}" --expected-sha256 "$${CATALOG_TRIAL_SHA256}"
verify-catalog-trial:
	python3 tool/stage_catalog_trial.py --verify
test-catalog-trial-staging:
	python3 -m unittest discover -s tool -p test_stage_catalog_trial.py
build-catalog-trial:
	@test -n "$${ANDROID_USER_HOME}" && test -f "$${ANDROID_USER_HOME}/debug.keystore" || (echo 'Set the existing explicit disposable Android debug signer directory.' >&2; exit 2)
	@case "$(CATALOG_TRIAL_TARGET_PLATFORM)" in android-arm64|android-x64) ;; *) echo 'CATALOG_TRIAL_TARGET_PLATFORM must be android-arm64 or android-x64.' >&2; exit 2 ;; esac
	$(MAKE) verify-catalog-trial
	ALKION_ISOLATED_CATALOG_TRIAL=1 $(FLUTTER) build apk --debug --no-pub --flavor dev --target-platform "$(CATALOG_TRIAL_TARGET_PLATFORM)" --target lib/catalog_trial.dart --dart-define=ALKION_CATALOG_TRIAL=true
	cp -- build/app/outputs/flutter-apk/app-dev-debug.apk build/app/outputs/flutter-apk/alkion-catalog-trial-$(CATALOG_TRIAL_TARGET_PLATFORM)-debug.apk
